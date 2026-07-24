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
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent_sync_check.XXXXXX")"
SYNC_LOG="$(mktemp "${TMPDIR:-/tmp}/agent_sync_check_sync.XXXXXX")"
TAR_ERR="$(mktemp "${TMPDIR:-/tmp}/agent_sync_check_tar.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"; rm -f "$SYNC_LOG" "$TAR_ERR"' EXIT

echo "Checking AgentSync configuration synchronization..."

# Copy project to a temporary workspace without .git metadata.
# stderr is captured so benign xattr warnings (BSD tar on macOS) stay quiet on success.
if ! (cd "$REPO_ROOT" && tar --exclude='.git' -cf - . 2>"$TAR_ERR") | (cd "$TEMP_ROOT" && tar -xf -); then
    echo "❌ Failed to prepare temporary workspace for check"
    [[ -s "$TAR_ERR" ]] && cat "$TAR_ERR" >&2
    exit 1
fi

# Run sync in temporary workspace. This keeps the caller repository read-only.
# --force bypasses the manifest drift check inside the temp copy: any divergence
# between source and dest is caught by the post-sync `diff -qr` below, which
# gives the user a richer "out of sync" report than the abort message would.
if ! AGENTSYNC_REPO_ROOT="$TEMP_ROOT" \
     AGENTSYNC_SKIP_POST_SYNC=true \
     AGENTSYNC_INTERNAL_SKIP_BACKUP=true \
     "$SCRIPT_DIR/sync.sh" --force >"$SYNC_LOG" 2>&1; then
    echo "❌ Sync script failed during check"
    echo "Sync output (last 40 lines):"
    tail -n 40 "$SYNC_LOG"
    exit 1
fi

set +e
DIFF_OUTPUT=$(diff -qr -x '.git' "$REPO_ROOT" "$TEMP_ROOT")
DIFF_EXIT=$?
set -e

if [[ $DIFF_EXIT -eq 0 ]]; then
    echo "✅ AgentSync configurations are safe and synced."
    exit 0
fi

echo ""
echo "⚠️  AgentSync configurations are out of sync with source."
echo "Differences detected (showing up to 20):"
echo "$DIFF_OUTPUT" | head -n 20
echo ""
echo "Please run: lib/sync.sh"
exit 1
