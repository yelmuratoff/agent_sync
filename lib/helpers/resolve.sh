#!/usr/bin/env bash
# Path resolution utilities for agentsync CLI.
# NOTE: This file is sourced from bin/agentsync.
#       _AGENTSYNC_ENGINE_ROOT is set by _load_lib before sourcing.

# Resolve the engine's system directory.
# Priority:
#   1. AGENTSYNC_HOME env var (global install)
#   2. Engine root (set during lib loading)
#   3. lib in current working directory
resolve_system_dir() {
    if [[ -n "${AGENTSYNC_HOME:-}" ]] && [[ -d "$AGENTSYNC_HOME/lib" ]]; then
        echo "$AGENTSYNC_HOME/lib"
        return 0
    fi

    if [[ -n "${_AGENTSYNC_ENGINE_ROOT:-}" ]] && [[ -d "$_AGENTSYNC_ENGINE_ROOT/lib" ]]; then
        echo "$_AGENTSYNC_ENGINE_ROOT/lib"
        return 0
    fi

    if [[ -d "$(pwd)/lib" ]]; then
        echo "$(pwd)/lib"
        return 0
    fi

    return 1
}

# Resolve the git-based install directory for self-update.
resolve_install_dir() {
    if [[ -n "${AGENTSYNC_HOME:-}" ]] && [[ -d "$AGENTSYNC_HOME/.git" ]]; then
        echo "$AGENTSYNC_HOME"
        return 0
    fi

    if [[ -n "${_AGENTSYNC_ENGINE_ROOT:-}" ]] && [[ -d "$_AGENTSYNC_ENGINE_ROOT/.git" ]]; then
        echo "$_AGENTSYNC_ENGINE_ROOT"
        return 0
    fi

    return 1
}
