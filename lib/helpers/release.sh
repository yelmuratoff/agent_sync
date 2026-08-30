#!/usr/bin/env bash
# agentsync release — bump version, tag, and push.

cmd_release() {
    local bump_type="patch"
    local skip_push=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-push) skip_push=true; shift ;;
            major|minor|patch) bump_type="$1"; shift ;;
            *)
                echo "$(_red "Error"): Unknown bump type: $1" >&2
                echo "  Usage: agentsync release [major|minor|patch] [--no-push]" >&2
                exit 1
                ;;
        esac
    done

    local install_dir
    install_dir=$(resolve_install_dir 2>/dev/null) || install_dir=""

    # Must be run from the agentsync repo itself
    local repo_dir=""
    if [[ -f "VERSION" ]] && [[ -f "bin/agentsync.sh" ]]; then
        repo_dir="$(pwd)"
    elif [[ -n "$install_dir" ]] && [[ -f "$install_dir/VERSION" ]]; then
        repo_dir="$install_dir"
    else
        echo "$(_red "Error"): Must be run from the AgentSync repository." >&2
        exit 1
    fi

    cd "$repo_dir" || exit 1

    # Check for clean working tree
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo "$(_red "Error"): Working tree is not clean. Commit or stash changes first." >&2
        exit 1
    fi

    # Read current version
    local current_version=""
    read -r current_version < VERSION || true

    # Parse semver
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current_version"

    if [[ -z "$major" ]] || [[ -z "$minor" ]] || [[ -z "$patch" ]]; then
        echo "$(_red "Error"): Cannot parse VERSION: $current_version" >&2
        exit 1
    fi

    # Bump
    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
    esac

    local new_version="$major.$minor.$patch"

    echo ""
    _bold "  AgentSync Release"; echo ""
    echo ""
    echo "  $(_dim "$current_version") → $(_green "$new_version") ($bump_type)"
    echo ""

    # Confirm
    printf "  %s " "$(_green "▸") Continue? [Y/n]:"
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "  Cancelled."
        return 0
    fi

    # Update VERSION
    echo "$new_version" > VERSION
    echo "  Updated $(_cyan "VERSION") → $new_version"

    # Commit + tag
    git add VERSION
    git commit -m "release: v$new_version" --quiet
    echo "  Created commit: $(_dim "release: v$new_version")"

    # Build annotated tag message from CHANGELOG.md
    local tag_body
    tag_body=$(awk -v ver="## ${new_version}" \
        '$0 == ver {found=1; next} found && /^## /{exit} found' CHANGELOG.md)
    local tag_msg_file
    tag_msg_file="$(tmp_file agentsync_tag_msg)"
    printf 'v%s\n\n%s' "$new_version" "$tag_body" > "$tag_msg_file"
    git tag -a "$new_version" -F "$tag_msg_file"
    rm -f "$tag_msg_file"
    echo "  Created tag: $(_cyan "$new_version")"

    # Push
    if [[ "$skip_push" == "true" ]]; then
        echo ""
        echo "  $(_green "Released v$new_version!") (local only, --no-push)"
        echo ""
        echo "  Push manually:"
        echo "    git push origin main && git push origin $new_version"
        echo ""
    else
        echo ""
        echo "  Pushing to origin..."
        git push --quiet origin main
        git push --quiet origin "$new_version"
        echo ""
        echo "  $(_green "Released v$new_version!")"
        echo ""
        echo "  GitHub Release will be created automatically by CI."
        echo "  Users will see the update notification on next run."
        echo ""
    fi
}
