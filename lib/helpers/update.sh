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

    echo "  Updating..."
    if ! git pull --quiet origin main 2>/dev/null; then
        echo "  $(_red "Error"): git pull failed. Try reinstalling:" >&2
        echo "    curl -fsSL https://raw.githubusercontent.com/$AGENTSYNC_REPO/main/install.sh | bash" >&2
        exit 1
    fi

    # Re-link CLI binary (handles renames across versions)
    local cli_script="$install_dir/bin/agentsync.sh"
    if [[ -f "$cli_script" ]]; then
        chmod +x "$cli_script"
        local current_bin
        current_bin=$(command -v agentsync 2>/dev/null) || true
        if [[ -n "$current_bin" ]] && [[ -L "$current_bin" ]]; then
            ln -sf "$cli_script" "$current_bin"
        fi
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

    # Show what's new from CHANGELOG.md
    _show_changelog "$install_dir" "$new_version"

    echo ""
}

# Show changelog entries for a specific version
# Usage: _show_changelog "/path/to/install" "0.2.0"
_show_changelog() {
    local install_dir="$1"
    local version="$2"
    local changelog="$install_dir/CHANGELOG.md"

    [[ -f "$changelog" ]] || return 0

    # Extract the section for this version (between ## $version and the next ## or EOF)
    local in_section=false
    local entries=""

    while IFS= read -r line; do
        if [[ "$line" == "## $version"* ]]; then
            in_section=true
            continue
        fi
        if [[ "$in_section" == "true" ]]; then
            # Stop at the next version header
            if [[ "$line" == "## "* ]]; then
                break
            fi
            entries+="$line"$'\n'
        fi
    done < "$changelog"

    if [[ -z "$entries" ]]; then
        return 0
    fi

    echo ""
    echo "  $(_cyan "What's new in v${version}:")"
    echo ""

    # Print entries with indentation, skip empty lines at start/end
    local started=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && [[ "$started" == "false" ]] && continue
        started=true
        if [[ "$line" == "### "* ]]; then
            echo "  $(_bold "${line#"### "}")"
        elif [[ "$line" == "- "* ]]; then
            echo "    $(_dim "•") ${line#"- "}"
        elif [[ -n "$line" ]]; then
            echo "    $line"
        fi
    done <<< "$entries"
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
        # Fetch changelog summary for the latest version
        local changelog_hint=""
        local remote_changelog
        remote_changelog=$(curl -sf --max-time 3 \
            "https://raw.githubusercontent.com/$AGENTSYNC_REPO/main/CHANGELOG.md" 2>/dev/null) || true

        if [[ -n "$remote_changelog" ]]; then
            # Count entries in the target version section
            local count=0
            local in_section=false
            while IFS= read -r line; do
                if [[ "$line" == "## $latest_tag"* ]]; then
                    in_section=true
                    continue
                fi
                if [[ "$in_section" == "true" ]]; then
                    [[ "$line" == "## "* ]] && break
                    [[ "$line" == "- "* ]] && count=$((count + 1))
                fi
            done <<< "$remote_changelog"
            if [[ $count -gt 0 ]]; then
                changelog_hint=" ($count changes)"
            fi
        fi

        echo ""
        echo "  ╭──────────────────────────────────────────────────────╮"
        echo "  │  $(_yellow "Update available"): $(_dim "v${VERSION}") → $(_green "v${latest_tag}")${changelog_hint}              "
        echo "  │  Run: $(_cyan "agentsync update")                                "
        echo "  ╰──────────────────────────────────────────────────────╯"
        echo ""
    fi
}
