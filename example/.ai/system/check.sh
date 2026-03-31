#!/usr/bin/env bash
# Read-only validation for AgentSync outputs.
# Exit code:
#   0 - repository is already in sync
#   1 - repository is out of sync or check failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent_sync_check.XXXXXX")"
SYNC_LOG="$(mktemp "${TMPDIR:-/tmp}/agent_sync_check_sync.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"; rm -f "$SYNC_LOG"' EXIT

echo "Checking AgentSync configuration synchronization..."

# Copy project to a temporary workspace without .git metadata.
if ! (cd "$REPO_ROOT" && tar --exclude='.git' -cf - .) | (cd "$TEMP_ROOT" && tar -xf -); then
    echo "❌ Failed to prepare temporary workspace for check"
    exit 1
fi

# Run sync in temporary workspace. This keeps the caller repository read-only.
if ! AGENTSYNC_REPO_ROOT="$TEMP_ROOT" AGENTSYNC_SKIP_POST_SYNC=true "$SCRIPT_DIR/sync.sh" >"$SYNC_LOG" 2>&1; then
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
echo "Please run: .ai/system/sync.sh"
exit 1
