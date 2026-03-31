#!/usr/bin/env bash
# AgentSync Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/yelmuratoff/agent/main/install.sh | bash
#
# What it does:
#   1. Clones the AgentSync engine to ~/.agentsync/
#   2. Creates a symlink: /usr/local/bin/agentsync.sh → ~/.agentsync/bin/agentsync.sh
#
# To uninstall:
#   rm -rf ~/.agentsync && rm -f /usr/local/bin/agentsync.sh

set -euo pipefail

readonly REPO_URL="https://github.com/yelmuratoff/agent.git"
readonly INSTALL_DIR="$HOME/.agentsync"
readonly BIN_NAME="agentsync"

# ─── Colors ───────────────────────────────────────────────────────────────────
# Evaluate once at startup (not inside subshells where [[ -t 1 ]] would be false)
_USE_COLORS=false
[[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && _USE_COLORS=true

_bold()   { [[ "$_USE_COLORS" == true ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
_green()  { [[ "$_USE_COLORS" == true ]] && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"; }
_cyan()   { [[ "$_USE_COLORS" == true ]] && printf '\033[36m%s\033[0m' "$1" || printf '%s' "$1"; }
_yellow() { [[ "$_USE_COLORS" == true ]] && printf '\033[33m%s\033[0m' "$1" || printf '%s' "$1"; }
_red()    { [[ "$_USE_COLORS" == true ]] && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"; }
_dim()    { [[ "$_USE_COLORS" == true ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"; }

# ─── Checks ──────────────────────────────────────────────────────────────────
check_requirements() {
    if ! command -v git >/dev/null 2>&1; then
        echo "$(_red "Error"): git is required but not found." >&2
        exit 1
    fi

    if ! command -v bash >/dev/null 2>&1; then
        echo "$(_red "Error"): bash is required but not found." >&2
        exit 1
    fi
}

# ─── Determine where to put the symlink ──────────────────────────────────────
resolve_bin_dir() {
    # Prefer /usr/local/bin if writable, otherwise ~/.local/bin
    if [[ -d "/usr/local/bin" ]] && [[ -w "/usr/local/bin" ]]; then
        echo "/usr/local/bin"
    elif [[ -d "$HOME/.local/bin" ]]; then
        echo "$HOME/.local/bin"
    else
        mkdir -p "$HOME/.local/bin"
        echo "$HOME/.local/bin"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    _bold "  AgentSync Installer"; echo ""
    echo ""

    check_requirements

    # 1. Clone or update
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        echo "  Updating existing installation..."
        (cd "$INSTALL_DIR" && git pull --quiet origin main 2>/dev/null) || {
            echo "  $(_yellow "Warning"): git pull failed, re-cloning..."
            rm -rf "$INSTALL_DIR"
            git clone --quiet --depth 1 "$REPO_URL" "$INSTALL_DIR"
        }
    else
        if [[ -d "$INSTALL_DIR" ]]; then
            echo "  Cleaning up previous installation..."
            rm -rf "$INSTALL_DIR"
        fi
        echo "  Cloning AgentSync..."
        git clone --quiet --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi

    # 2. Verify the engine is present
    local engine_dir="$INSTALL_DIR"
    if [[ ! -d "$engine_dir/.ai/system" ]]; then
        echo "$(_red "Error"): Engine not found at $engine_dir/.ai/system" >&2
        echo "The repository structure may have changed." >&2
        exit 1
    fi

    # 3. Make CLI executable
    local cli_script="$engine_dir/bin/agentsync.sh"
    if [[ ! -f "$cli_script" ]]; then
        echo "$(_red "Error"): CLI script not found at $cli_script" >&2
        exit 1
    fi
    chmod +x "$cli_script"

    # 4. Create symlink
    local bin_dir
    bin_dir=$(resolve_bin_dir)
    local symlink_path="$bin_dir/$BIN_NAME"

    # Remove old symlink if exists
    rm -f "$symlink_path" 2>/dev/null || true

    if ln -sf "$cli_script" "$symlink_path" 2>/dev/null; then
        echo "  Linked $(_cyan "$symlink_path") → $(_dim "$cli_script")"
    else
        # Try with sudo
        echo "  Need sudo to create symlink in $bin_dir..."
        sudo ln -sf "$cli_script" "$symlink_path"
        echo "  Linked $(_cyan "$symlink_path") → $(_dim "$cli_script")"
    fi

    # 5. Set AGENTSYNC_HOME for the CLI to find the engine
    local shell_config=""
    local export_line="export AGENTSYNC_HOME=\"$engine_dir\""

    if [[ -f "$HOME/.zshrc" ]]; then
        shell_config="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_config="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
        shell_config="$HOME/.bash_profile"
    fi

    local needs_path_update=false
    if [[ "$bin_dir" == "$HOME/.local/bin" ]]; then
        # Check if ~/.local/bin is in PATH
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            needs_path_update=true
        fi
    fi

    if [[ -n "$shell_config" ]]; then
        # Add AGENTSYNC_HOME if not already set
        if ! grep -qF "AGENTSYNC_HOME" "$shell_config" 2>/dev/null; then
            {
                echo ""
                echo "# AgentSync"
                echo "$export_line"
            } >> "$shell_config"
            echo "  Added AGENTSYNC_HOME to $(_dim "$shell_config")"
        fi

        if [[ "$needs_path_update" == "true" ]]; then
            if ! grep -q 'local/bin' "$shell_config" 2>/dev/null; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_config"
                echo "  Added ~/.local/bin to PATH in $(_dim "$shell_config")"
            fi
        fi
    fi

    # 6. Done!
    echo ""
    echo "  $(_green "Installed successfully!")"
    echo ""
    echo "  Run $(_cyan "agentsync help") to get started."
    echo ""

    if [[ -n "$shell_config" ]]; then
        echo "  $(_yellow "Restart your terminal") or run:"
        echo "    source $shell_config"
        echo ""
    fi

    echo "  Quick start:"
    echo "    cd your-project"
    echo "    $(_cyan "agentsync init")"
    echo "    $(_cyan "agentsync sync")"
    echo ""

    echo "  To uninstall:"
    _dim "    rm -rf ~/.agentsync && rm -f $symlink_path"; echo ""
    echo ""
}

main "$@"
