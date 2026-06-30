#!/usr/bin/env bash
# Installs git hooks that keep generated tool outputs in sync with .ai/src/.
#
# post-merge / post-checkout run a full sync after `git pull` / `git checkout`
# (mtimes are reset on checkout, so a staleness probe is unreliable there).
# pre-commit (opt-in via --pre-commit) runs `sync --if-stale` so a commit picks
# up source edits without a full re-sync when nothing changed.
#
# Every hook is non-fatal: a failed sync warns but never blocks the git
# operation. Existing hook logic is preserved; the AgentSync block is appended
# once between markers and replaced in place on re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

INSTALL_PRE_COMMIT="false"
for arg in "$@"; do
    case "$arg" in
        --pre-commit) INSTALL_PRE_COMMIT="true" ;;
        --help|-h)
            echo "Usage: agentsync setup-hooks [--pre-commit]"
            echo ""
            echo "  Installs post-merge and post-checkout hooks that run 'agentsync sync'"
            echo "  after pull/checkout."
            echo ""
            echo "  --pre-commit   Also install a pre-commit hook that runs"
            echo "                 'agentsync sync --if-stale' before each commit."
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $arg" >&2
            echo "Usage: agentsync setup-hooks [--pre-commit]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "Error: .git/hooks directory not found. Are you in a git repository?"
    exit 1
fi

readonly BLOCK_START="# >>> AGENTSYNC AUTO SYNC START >>>"
readonly BLOCK_END="# <<< AGENTSYNC AUTO SYNC END <<<"

# Emit the POSIX-sh body run by a hook. $1 is the sync invocation (e.g.
# "sync" or "sync --if-stale"). Prefers the installed agentsync binary, then
# the in-repo engine (dogfooding / non-global installs). Always exits 0 so the
# git operation it hangs off of is never blocked by a sync failure.
emit_sync_body() {
    local sync_args="$1"
    cat <<EOF
if command -v agentsync >/dev/null 2>&1; then
    echo "AgentSync: syncing AI config..."
    agentsync $sync_args || echo "AgentSync: sync skipped — run 'agentsync sync' to see why." >&2
elif [ -f "lib/sync.sh" ]; then
    bash lib/sync.sh || true
elif [ -f "agent/lib/sync.sh" ]; then
    bash agent/lib/sync.sh || true
fi
EOF
}

append_agentsync_block() {
    local hook_file="$1"
    local sync_args="$2"

    if grep -qF "$BLOCK_START" "$hook_file"; then
        echo "AgentSync hook already present in $(basename "$hook_file")."
        return 0
    fi

    {
        echo ""
        echo "$BLOCK_START"
        emit_sync_body "$sync_args"
        echo "$BLOCK_END"
    } >> "$hook_file"
}

install_hook() {
    local hook_name="$1"
    local sync_args="$2"
    local hook_file="$HOOKS_DIR/$hook_name"

    if [[ ! -f "$hook_file" ]]; then
        {
            echo "#!/bin/sh"
            echo ""
        } > "$hook_file"
    fi

    append_agentsync_block "$hook_file" "$sync_args"
    chmod +x "$hook_file"
    echo "Configured $hook_name hook."
}

install_hook "post-merge" "sync"
install_hook "post-checkout" "sync"
if [[ "$INSTALL_PRE_COMMIT" == "true" ]]; then
    install_hook "pre-commit" "sync --if-stale"
fi

echo "Git hooks configured successfully."
