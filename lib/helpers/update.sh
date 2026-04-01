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
    cd "$install_dir" || exit 1

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

    # Show what's new from CHANGELOG.md (all versions between old and new)
    _show_changelog_range "$install_dir" "$old_version" "$new_version"

    echo ""
}

# Show changelog entries for all versions between old_version (exclusive) and new_version (inclusive).
# Falls back to showing only new_version if old_version is unknown or equal.
# Usage: _show_changelog_range "/path/to/install" "0.2.0" "0.2.3"
_show_changelog_range() {
    local install_dir="$1"
    local old_version="$2"
    local new_version="$3"
    local changelog="$install_dir/CHANGELOG.md"

    [[ -f "$changelog" ]] || return 0

    # Collect all version headers from the changelog
    local all_versions=()
    while IFS= read -r line; do
        if [[ "$line" == "## "* ]]; then
            local v="${line#"## "}"
            v="${v%% *}"
            all_versions+=("$v")
        fi
    done < "$changelog"

    # Filter: old_version < v <= new_version
    local in_range=()
    for v in "${all_versions[@]}"; do
        local top_of_old_v
        top_of_old_v=$(printf '%s\n%s' "$old_version" "$v" | sort -V | tail -1)
        local top_of_v_new
        top_of_v_new=$(printf '%s\n%s' "$v" "$new_version" | sort -V | tail -1)
        if [[ "$top_of_old_v" == "$v" ]] && [[ "$v" != "$old_version" ]] \
            && [[ "$top_of_v_new" == "$new_version" ]]; then
            in_range+=("$v")
        fi
    done

    [[ ${#in_range[@]} -eq 0 ]] && return 0

    # Sort ascending so the user reads oldest → newest
    local sorted_versions
    sorted_versions=$(printf '%s\n' "${in_range[@]}" | sort -V)

    _show_changelog_sections "$changelog" "$sorted_versions"
}

# Print the changelog body for each version in sorted_versions (newline-separated list).
_show_changelog_sections() {
    local changelog="$1"
    local sorted_versions="$2"

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue
        echo ""
        echo "  $(_cyan "What's new in v${version}:")"
        echo ""

        local in_section=false
        local started=false
        while IFS= read -r line; do
            if [[ "$line" == "## $version"* ]]; then
                in_section=true
                continue
            fi
            if [[ "$in_section" == "true" ]]; then
                [[ "$line" == "## "* ]] && break
                [[ -z "$line" ]] && [[ "$started" == "false" ]] && continue
                started=true
                if [[ "$line" == "### "* ]]; then
                    echo "  $(_bold "${line#"### "}")"
                elif [[ "$line" == "- "* ]]; then
                    echo "    $(_dim "•") ${line#"- "}"
                elif [[ -n "$line" ]]; then
                    echo "    $line"
                fi
            fi
        done < "$changelog"
    done <<< "$sorted_versions"
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
