#!/usr/bin/env bash
# agentsync update — self-update and update-check logic.

readonly AGENTSYNC_REPO="yelmuratoff/agent"
readonly UPDATE_CHECK_INTERVAL=86400  # 24 hours

cmd_update() {
    local install_dir
    install_dir=$(resolve_install_dir 2>/dev/null) || {
        echo "$(_red "Error"): AgentSync installation not found." >&2
        echo "Install globally first:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/$AGENTSYNC_REPO/main/install.sh | bash" >&2
        exit 1
    }

    echo ""
    _bold "  AgentSync Update"; echo ""
    echo ""

    local old_version="$VERSION"

    echo "  Checking for updates..."
    cd "$install_dir"

    if ! git fetch --quiet --tags origin main 2>/dev/null; then
        echo "  $(_red "Error"): Failed to fetch updates. Check your network connection." >&2
        exit 1
    fi

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse origin/main)

    if [[ "$local_head" == "$remote_head" ]]; then
        echo "  $(_green "Already up to date!") (v${VERSION})"
        echo ""
        _update_check_timestamp "$install_dir"
        return 0
    fi

    echo ""
    echo "  $(_cyan "Changelog:")"
    git log --oneline "$local_head..$remote_head" | while IFS= read -r line; do
        echo "    $(_dim "•") $line"
    done
    echo ""

    echo "  Updating..."
    if ! git pull --quiet origin main 2>/dev/null; then
        echo "  $(_red "Error"): git pull failed. Try reinstalling:" >&2
        echo "    curl -fsSL https://raw.githubusercontent.com/$AGENTSYNC_REPO/main/install.sh | bash" >&2
        exit 1
    fi

    local new_version="$old_version"
    if [[ -f "$install_dir/VERSION" ]]; then
        read -r new_version < "$install_dir/VERSION"
    fi

    _update_check_timestamp "$install_dir"

    echo ""
    if [[ "$old_version" != "$new_version" ]]; then
        echo "  $(_green "Updated!") v${old_version} → v${new_version}"
    else
        echo "  $(_green "Updated!") (v${new_version})"
    fi
    echo ""
}

_update_check_timestamp() {
    local install_dir="$1"
    date +%s > "$install_dir/.last_update_check" 2>/dev/null || true
}

check_for_updates() {
    [[ -t 1 ]] || return 0
    [[ -z "${AGENTSYNC_NO_UPDATE_CHECK:-}" ]] || return 0

    local install_dir
    install_dir=$(resolve_install_dir 2>/dev/null) || return 0
    [[ -d "$install_dir/.git" ]] || return 0

    local ts_file="$install_dir/.last_update_check"
    local now
    now=$(date +%s)

    if [[ -f "$ts_file" ]]; then
        local last_check
        read -r last_check < "$ts_file" 2>/dev/null || last_check=0
        local elapsed=$(( now - last_check ))
        if (( elapsed < UPDATE_CHECK_INTERVAL )); then
            return 0
        fi
    fi

    local latest_tag
    latest_tag=$(curl -sf --max-time 3 \
        "https://api.github.com/repos/$AGENTSYNC_REPO/tags?per_page=1" \
        2>/dev/null | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1) || true

    _update_check_timestamp "$install_dir"

    if [[ -z "$latest_tag" ]]; then
        return 0
    fi

    if [[ "$latest_tag" != "$VERSION" ]] && [[ "$(printf '%s\n%s' "$VERSION" "$latest_tag" | sort -V | tail -1)" == "$latest_tag" ]]; then
        echo ""
        echo "  ╭──────────────────────────────────────────────╮"
        echo "  │  $(_yellow "Update available"): $(_dim "v${VERSION}") → $(_green "v${latest_tag}")              │"
        echo "  │  Run: $(_cyan "agentsync update")                        │"
        echo "  ╰──────────────────────────────────────────────╯"
        echo ""
    fi
}
