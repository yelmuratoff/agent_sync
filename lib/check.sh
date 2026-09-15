#!/usr/bin/env bash
# Read-only validation for AgentSync outputs.
# Exit code:
#   0 - repository is already in sync
#   1 - repository is out of sync or check failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
MANIFEST_REL=".ai/.sync-manifest"

# shellcheck source=helpers/tmp.sh
source "$SCRIPT_DIR/helpers/tmp.sh"
# shellcheck source=helpers/yaml.sh
source "$SCRIPT_DIR/helpers/yaml.sh"
# shellcheck source=helpers/version.sh
source "$SCRIPT_DIR/helpers/version.sh"
# shellcheck source=helpers/project_config.sh
source "$SCRIPT_DIR/helpers/project_config.sh"

if ! project_config_path_r "$REPO_ROOT"; then
    echo "❌ AGENTSYNC_CONFIG_PATH is set but file not found: $REPLY" >&2
    exit 1
fi
CHECK_CONFIG_PATH="$REPLY"

# Same gate as sync, checked up front so CI reports the pin rather than a
# "sync failed inside check" wrapper. Only committed outputs make it fatal:
# there, every machine must generate byte-identical files.
_check_version_pin() {
    local config="$CHECK_CONFIG_PATH"
    [[ -n "$config" ]] || return 0

    local version_mode
    if ! version_mode=$(version_pin_mode "$config"); then
        echo "❌ Unknown version_pin.mode '$version_mode' in ${config#"$REPO_ROOT/"} — expected 'warn' or 'strict'" >&2
        exit 1
    fi

    local outputs
    outputs=$(parse_yaml_value "$config" "outputs")
    outputs="${outputs//\"/}"
    if [[ -z "$outputs" && "$(parse_yaml_value "$config" "gitignore.update")" == "false" ]]; then
        outputs="committed"
    fi
    [[ "$outputs" == "committed" || "$version_mode" == "strict" ]] || return 0

    local pinned engine
    pinned=$(pinned_version "$config")
    [[ -n "$pinned" ]] || return 0
    engine=$(engine_version "$SCRIPT_DIR")
    [[ "$pinned" != "$engine" ]] || return 0

    echo "❌ $(version_pin_mismatch_error "$pinned" "$engine" "$outputs")" >&2
    version_pin_mismatch_hint "$pinned" "$engine" >&2
    exit 1
}
_check_version_pin

# shellcheck disable=SC2329  # invoked through the EXIT trap below
_check_on_exit() {
    local status=$?
    trap - EXIT INT TERM HUP
    tmp_cleanup || true
    exit "$status"
}

# $? carries the last completed command's status, not the signal, so the status
# is passed in explicitly here.
# shellcheck disable=SC2329  # invoked through the signal traps below
_check_on_signal() {
    trap - EXIT INT TERM HUP
    tmp_cleanup || true
    kill -"$1" "$$"
    exit "$((128 + $2))"
}

tmp_prime_run_dir
trap _check_on_exit EXIT
trap '_check_on_signal INT 2' INT
trap '_check_on_signal TERM 15' TERM
trap '_check_on_signal HUP 1' HUP

TEMP_ROOT="$(tmp_dir workspace)"
SYNC_LOG="$(tmp_file synclog)"
TAR_ERR="$(tmp_file tarerr)"
COPY_LIST="$(tmp_file copylist)"
COMPARE_LIST="$(tmp_file comparelist)"

echo "Checking AgentSync configuration synchronization..."

# Echo the manifest's relative paths, one per line.
manifest_paths() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0
    local rel
    while IFS=$'\t' read -r rel _; do
        [[ -n "$rel" ]] && printf '%s\n' "$rel"
    done < "$manifest"
}

# A global install makes the project root $HOME, whose siblings are none of
# AgentSync's business: OS-protected directories (~/Library, ~/Pictures) that
# deny traversal outright, and multi-GB tool caches. Copy only what sync reads
# and writes — the .ai/ source tree plus the outputs the manifest records.
{
    printf '%s\n' ".ai"
    [[ -f "$REPO_ROOT/agent_sync.yaml" ]] && printf '%s\n' "agent_sync.yaml"
    manifest_paths "$REPO_ROOT/$MANIFEST_REL" | while IFS= read -r rel; do
        case "$rel" in
            .ai/*) continue ;;                      # already covered by .ai
        esac
        [[ -e "$REPO_ROOT/$rel" ]] && printf '%s\n' "$rel"
    done
} | LC_ALL=C sort -u > "$COPY_LIST"

# Backups hold previous snapshots of these same outputs — large, and irrelevant
# to whether the current tree matches its source.
# stderr is captured so benign xattr warnings (BSD tar on macOS) stay quiet on success.
if ! tar -C "$REPO_ROOT" --exclude='.git' --exclude='.ai/backups' \
        -cf - -T "$COPY_LIST" 2>"$TAR_ERR" | (cd "$TEMP_ROOT" && tar -xf -); then
    echo "❌ Failed to prepare temporary workspace for check"
    [[ -s "$TAR_ERR" ]] && cat "$TAR_ERR" >&2
    exit 1
fi

# tar can report success after a partial read, which would turn a truncated
# workspace into a false "in sync" verdict. Confirm every requested path landed.
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ ! -e "$TEMP_ROOT/$rel" ]]; then
        echo "❌ Failed to prepare temporary workspace for check"
        echo "Incomplete copy — missing: $rel" >&2
        [[ -s "$TAR_ERR" ]] && cat "$TAR_ERR" >&2
        exit 1
    fi
done < "$COPY_LIST"

# Run sync in temporary workspace. This keeps the caller repository read-only.
# --force bypasses the manifest drift check inside the temp copy: any divergence
# between source and dest is caught by the comparison below, which gives the
# user a richer "out of sync" report than the abort message would.
# Sources resolve from the project itself: source.* values relative to it, or
# outside it, have no copy in the workspace.
if ! AGENTSYNC_REPO_ROOT="$TEMP_ROOT" \
     AGENTSYNC_SKIP_POST_SYNC=true \
     AGENTSYNC_INTERNAL_SKIP_BACKUP=true \
     AGENTSYNC_CONFIG_PATH="$CHECK_CONFIG_PATH" \
     AGENTSYNC_INTERNAL_SOURCE_BASE_ROOT="$REPO_ROOT" \
     "$SCRIPT_DIR/sync.sh" --force >"$SYNC_LOG" 2>&1; then
    echo "❌ Sync script failed during check"
    echo "Sync output (last 40 lines):"
    tail -n 40 "$SYNC_LOG"
    exit 1
fi

# Compare only managed outputs. Taking both manifests catches a file the current
# sync would stop writing as well as one it would start writing.
{
    manifest_paths "$REPO_ROOT/$MANIFEST_REL"
    manifest_paths "$TEMP_ROOT/$MANIFEST_REL"
} | LC_ALL=C sort -u > "$COMPARE_LIST"

DIFF_OUTPUT=""
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    expected="$TEMP_ROOT/$rel"
    actual="$REPO_ROOT/$rel"

    if [[ -f "$expected" && -f "$actual" ]]; then
        cmp -s "$expected" "$actual" || DIFF_OUTPUT+="Files $rel differ"$'\n'
    elif [[ -f "$expected" ]]; then
        DIFF_OUTPUT+="Missing: $rel"$'\n'
    elif [[ -f "$actual" ]]; then
        DIFF_OUTPUT+="No longer generated: $rel"$'\n'
    fi
done < "$COMPARE_LIST"

if [[ -z "$DIFF_OUTPUT" ]]; then
    echo "✅ AgentSync configurations are safe and synced."
    exit 0
fi

echo ""
echo "⚠️  AgentSync configurations are out of sync with source."
echo "Differences detected (showing up to 20):"
printf '%s' "$DIFF_OUTPUT" | head -n 20
echo ""
echo "Please run: lib/sync.sh"
exit 1
