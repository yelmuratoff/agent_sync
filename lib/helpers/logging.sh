#!/usr/bin/env bash
# Logging utilities for AI Sync Script
# Cross-platform compatible (Unix/macOS/Git Bash)

# Colors (works in most terminals including Git Bash)
readonly COLOR_RESET='\033[0m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RED='\033[0;31m'

# Detect if colors are supported
_use_colors() {
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

# Print separator line
log_separator() {
    echo "═══════════════════════════════════════════════════════════════"
}

# 🔵 [INFO] message
log_info() {
    local msg="$1"
    if _use_colors; then
        echo -e "${COLOR_BLUE}🔵 [INFO]${COLOR_RESET} ${msg}"
    else
        echo "[INFO] ${msg}"
    fi
}

# ✅ [SUCCESS] message
log_success() {
    local msg="$1"
    if _use_colors; then
        echo -e "${COLOR_GREEN}✅ [SUCCESS]${COLOR_RESET} ${msg}"
    else
        echo "[SUCCESS] ${msg}"
    fi
}

# ⚠️ [WARNING] message
log_warning() {
    local msg="$1"
    if _use_colors; then
        echo -e "${COLOR_YELLOW}⚠️  [WARNING]${COLOR_RESET} ${msg}"
    else
        echo "[WARNING] ${msg}"
    fi
}

# ❌ [ERROR] message
log_error() {
    local msg="$1"
    if _use_colors; then
        echo -e "${COLOR_RED}❌ [ERROR]${COLOR_RESET} ${msg}" >&2
    else
        echo "[ERROR] ${msg}" >&2
    fi
}

# 📁 sub-step message (indented)
log_step() {
    local msg="$1"
    echo "   📁 ${msg}"
}

# Abbreviate an absolute path for readable log output: strip the repo-root
# prefix (the common case), else fold $HOME to ~, else leave it absolute.
# Presentation only — never feed the result back in as a real path.
display_path() {
    local path="$1"
    local root="${REPO_ROOT:-}"
    if [[ -n "$root" ]]; then
        [[ "$path" == "$root" ]] && { echo "."; return 0; }
        [[ "$path" == "$root"/* ]] && { echo "${path#"$root"/}"; return 0; }
    fi
    local home="${HOME:-}"
    if [[ -n "$home" ]] && [[ "$path" == "$home"/* ]]; then
        # Literal ~ for display; the result is never used as a real path.
        # shellcheck disable=SC2088
        echo "~/${path#"$home"/}"
        return 0
    fi
    echo "$path"
}

# ✅ [DONE] Final summary
log_done() {
    local msg="$1"
    if _use_colors; then
        echo -e "${COLOR_GREEN}✅ [DONE]${COLOR_RESET} ${msg}"
    else
        echo "[DONE] ${msg}"
    fi
}
