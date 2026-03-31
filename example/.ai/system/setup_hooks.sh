#!/usr/bin/env bash
# Installs git hooks to run .ai/system/sync.sh after checkout and merge.
# Existing hook logic is preserved; AgentSync block is appended once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

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

append_agentsync_block() {
    local hook_file="$1"

    if grep -qF "$BLOCK_START" "$hook_file"; then
        echo "AgentSync hook already present in $(basename "$hook_file")."
        return 0
    fi

    {
        echo ""
        echo "$BLOCK_START"
        cat <<'EOF'
if [ -f ".ai/system/sync.sh" ]; then
    echo "Running AI Config Sync (.ai/system)..."
    bash .ai/system/sync.sh
elif [ -f "agent/.ai/system/sync.sh" ]; then
    echo "Running AI Config Sync (agent/.ai/system)..."
    bash agent/.ai/system/sync.sh
elif command -v dart >/dev/null 2>&1; then
    echo "Running AI Config Sync (dart wrapper)..."
    dart run agent_sync:agent_sync sync --project-dir .
else
    echo "AgentSync: no sync entrypoint found (.ai/system, agent/.ai/system, or dart)." >&2
fi
EOF
        echo "$BLOCK_END"
    } >> "$hook_file"
}

install_hook() {
    local hook_name="$1"
    local hook_file="$HOOKS_DIR/$hook_name"

    if [[ ! -f "$hook_file" ]]; then
        {
            echo "#!/bin/sh"
            echo ""
        } > "$hook_file"
    fi

    append_agentsync_block "$hook_file"
    chmod +x "$hook_file"
    echo "Configured $hook_name hook."
}

install_hook "post-merge"
install_hook "post-checkout"

echo "Git hooks configured successfully."
