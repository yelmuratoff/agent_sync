#!/usr/bin/env bash
# agentsync import — import source files from a GitHub repo, archive, or local directory.
# Uses shared constants _BUNDLE_FILE_TARGETS, _BUNDLE_DIR_TARGETS, _BUNDLE_CONFIG from export.sh.

cmd_import() {
    local source=""
    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    local dry_run=false
    local force=false
    local only=""
    local branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   dry_run=true; shift ;;
            --force)     force=true; shift ;;
            --only)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --only requires a value" >&2; return 1; }
                only="$2"; shift 2 ;;
            --branch|-b)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --branch requires a value" >&2; return 1; }
                branch="$2"; shift 2 ;;
            --help|-h)   _import_usage; return 0 ;;
            -*)
                echo "$(_red "Error"): Unknown option: $1" >&2
                _import_usage >&2
                return 1
                ;;
            *)
                if [[ -z "$source" ]]; then
                    source="$1"
                else
                    echo "$(_red "Error"): Unexpected argument: $1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$source" ]]; then
        echo "$(_red "Error"): No source specified." >&2
        _import_usage >&2
        return 1
    fi

    echo ""
    _bold "  AgentSync Import"; echo ""
    echo ""

    # Create temp dir with guaranteed cleanup
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp_dir}'" EXIT

    # Determine source type and extract
    local source_label=""
    if _import_is_github_url "$source"; then
        source_label="GitHub: $source"
        _import_from_github "$source" "$tmp_dir" "$branch" || return 1
    elif [[ -f "$source" ]] && _import_is_archive "$source"; then
        source_label="Archive: $(basename "$source")"
        _import_from_archive "$source" "$tmp_dir" || return 1
    elif [[ -d "$source" ]]; then
        source_label="Directory: $source"
        _import_from_directory "$source" "$tmp_dir" || return 1
    else
        echo "  $(_red "Error"): Cannot recognize source: $source" >&2
        echo "  Expected: GitHub URL, .tar.gz file, or directory path." >&2
        return 1
    fi

    echo "  $(_dim "Source:") $source_label"
    echo ""

    # Locate .ai/src (or .ai/) inside extracted content
    local src_root="" src_project_root=""
    src_root=$(_import_find_ai_src "$tmp_dir")
    if [[ -z "$src_root" ]]; then
        echo "  $(_red "Error"): No .ai/src/ (or .ai/) directory found in source." >&2
        echo "  The source must contain a structure created by $(_cyan "agentsync init")." >&2
        return 1
    fi

    # Derive project root from found source:
    #   .ai/src → project root is 2 levels up
    #   .ai     → project root is 1 level up
    if [[ "$src_root" == */src ]]; then
        src_project_root=$(dirname "$(dirname "$src_root")")
    else
        src_project_root=$(dirname "$src_root")
    fi

    # Locate project config (canonical or legacy location)
    local imported_config=""
    if [[ -f "$src_project_root/$_BUNDLE_CONFIG" ]]; then
        imported_config="$src_project_root/$_BUNDLE_CONFIG"
    elif [[ -f "$src_project_root/$_BUNDLE_CONFIG_LEGACY" ]]; then
        imported_config="$src_project_root/$_BUNDLE_CONFIG_LEGACY"
    fi

    # Resolve local destination base
    _resolve_source_paths "$repo_root"
    local dest_base="$repo_root/${_SRC_BASE:-.ai/src}"

    # Build target list, applying --only filter
    local targets=()
    targets+=("${_BUNDLE_FILE_TARGETS[@]}")
    targets+=("${_BUNDLE_DIR_TARGETS[@]}")

    if [[ -n "$only" ]]; then
        local filtered=()
        local selected_item
        IFS=',' read -ra selected_arr <<< "$only"
        for t in "${targets[@]}"; do
            for selected_item in "${selected_arr[@]}"; do
                # Trim whitespace via parameter expansion (no subprocess)
                selected_item="${selected_item#"${selected_item%%[![:space:]]*}"}"
                selected_item="${selected_item%"${selected_item##*[![:space:]]}"}"
                if [[ "$t" == "$selected_item" ]] || [[ "${t%.md}" == "$selected_item" ]]; then
                    filtered+=("$t")
                    break
                fi
            done
        done
        targets=("${filtered[@]}")
    fi

    # Diff: compute changes
    local changes=()
    local new_count=0
    local update_count=0
    local skip_count=0

    for target in "${targets[@]}"; do
        local src_path="$src_root/$target"
        local dest_path="$dest_base/$target"
        [[ -e "$src_path" ]] || continue

        if [[ -f "$src_path" ]]; then
            _import_diff_file "$src_path" "$dest_path" "$target"
        elif [[ -d "$src_path" ]]; then
            _import_diff_dir "$src_path" "$dest_path" "$target"
        fi
    done

    # Check project config (compare against canonical location; ignore legacy)
    local config_action=""
    local config_dest="$repo_root/$_BUNDLE_CONFIG"
    if [[ -n "$imported_config" ]]; then
        if [[ -f "$config_dest" ]]; then
            if ! cmp -s "$imported_config" "$config_dest"; then
                config_action="update"
                update_count=$((update_count + 1))
            fi
        else
            config_action="new"
            new_count=$((new_count + 1))
        fi
    fi

    # Nothing to do?
    if [[ ${#changes[@]} -eq 0 ]] && [[ -z "$config_action" ]]; then
        echo "  $(_green "Already up to date!") Nothing to import."
        echo ""
        return 0
    fi

    # Print preview
    echo "  $(_green "Changes:")"
    local change
    for change in "${changes[@]}"; do
        local type="${change%%:*}"
        local name="${change#*:}"
        case "$type" in
            new)    echo "    $(_green "+") $name $(_dim "(new)")" ;;
            update) echo "    $(_yellow "~") $name $(_dim "(update)")" ;;
            dir)    echo "    $(_cyan "↳") $name" ;;
        esac
    done
    [[ "$config_action" == "new" ]]    && echo "    $(_green "+") agent_sync.yaml $(_dim "(new)")"
    [[ "$config_action" == "update" ]] && echo "    $(_yellow "~") agent_sync.yaml $(_dim "(update)")"
    echo ""
    echo "  $(_dim "Summary:") ${new_count} new, ${update_count} updated, ${skip_count} unchanged"
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        echo "  $(_yellow "Dry run") — no files written."
        echo ""
        return 0
    fi

    # Confirm when overwriting
    if [[ "$force" != "true" ]] && (( update_count > 0 )) && [[ -t 0 ]]; then
        echo -n "  Proceed? [Y/n] "
        local answer
        read -r answer
        case "$answer" in
            [Nn]*) echo "  Cancelled."; echo ""; return 0 ;;
        esac
    fi

    # Perform copy
    mkdir -p "$dest_base"

    for target in "${targets[@]}"; do
        local src_path="$src_root/$target"
        local dest_path="$dest_base/$target"
        [[ -e "$src_path" ]] || continue

        if [[ -f "$src_path" ]]; then
            cp "$src_path" "$dest_path"
        elif [[ -d "$src_path" ]]; then
            _import_copy_dir "$src_path" "$dest_path"
        fi
    done

    if [[ -n "$config_action" ]] && [[ -n "$imported_config" ]]; then
        mkdir -p "$(dirname "$config_dest")"
        cp "$imported_config" "$config_dest"
    fi

    echo "  $(_green "Imported!") ${new_count} new, ${update_count} updated files."
    echo ""
    echo "  Next steps:"
    echo "    1. Review imported files in $(_cyan "${dest_base#"$repo_root/"}")"
    echo "    2. Run $(_cyan "agentsync sync") to distribute to all tools"
    echo ""
}

# ── Diff helpers ─────────────────────────────────────────────────────────────

_import_diff_file() {
    local src="$1" dest="$2" label="$3"
    if [[ -f "$dest" ]]; then
        if cmp -s "$src" "$dest"; then
            skip_count=$((skip_count + 1))
        else
            changes+=("update:$label")
            update_count=$((update_count + 1))
        fi
    else
        changes+=("new:$label")
        new_count=$((new_count + 1))
    fi
}

_import_diff_dir() {
    local src_dir="$1" dest_dir="$2" label="$3"
    local dir_new=0 dir_update=0 dir_skip=0

    while IFS= read -r -d '' file; do
        local rel="${file#"$src_dir/"}"
        if [[ -f "$dest_dir/$rel" ]]; then
            if cmp -s "$file" "$dest_dir/$rel"; then
                dir_skip=$((dir_skip + 1))
            else
                dir_update=$((dir_update + 1))
            fi
        else
            dir_new=$((dir_new + 1))
        fi
    done < <(find "$src_dir" -type f -print0 2>/dev/null)

    if (( dir_new + dir_update > 0 )); then
        local detail=""
        (( dir_new > 0 ))    && detail="${dir_new} new"
        (( dir_update > 0 )) && { [[ -n "$detail" ]] && detail+=", "; detail+="${dir_update} updated"; }
        (( dir_skip > 0 ))   && { [[ -n "$detail" ]] && detail+=", "; detail+="${dir_skip} unchanged"; }
        changes+=("dir:$label ($detail)")
        new_count=$((new_count + dir_new))
        update_count=$((update_count + dir_update))
        skip_count=$((skip_count + dir_skip))
    else
        skip_count=$((skip_count + dir_skip))
    fi
}

# ── Copy helper ──────────────────────────────────────────────────────────────

_import_copy_dir() {
    local src_dir="$1" dest_dir="$2"
    mkdir -p "$dest_dir"
    while IFS= read -r -d '' file; do
        local rel="${file#"$src_dir/"}"
        local dest_file="$dest_dir/$rel"
        mkdir -p "$(dirname "$dest_file")"
        cp "$file" "$dest_file"
    done < <(find "$src_dir" -type f -print0 2>/dev/null)
}

# ── Source type detection ────────────────────────────────────────────────────

_import_is_github_url() {
    [[ "$1" =~ ^https?://(www\.)?github\.com/[^/]+/[^/]+ ]]
}

_import_is_archive() {
    [[ "$1" == *.tar.gz ]] || [[ "$1" == *.tgz ]]
}

# ── Source handlers ──────────────────────────────────────────────────────────

_import_from_github() {
    local url="$1" tmp_dir="$2" branch="$3"

    if ! command -v curl &>/dev/null; then
        echo "  $(_red "Error"): curl is required for GitHub import." >&2
        return 1
    fi

    # Normalize URL
    url="${url%.git}"
    url="${url%/}"

    # Extract owner/repo (always the two segments after github.com/)
    local owner="" repo_name=""
    if [[ "$url" =~ github\.com/([^/]+)/([^/]+) ]]; then
        owner="${BASH_REMATCH[1]}"
        repo_name="${BASH_REMATCH[2]}"
    fi

    if [[ -z "$owner" ]] || [[ -z "$repo_name" ]]; then
        echo "  $(_red "Error"): Cannot parse GitHub URL: $url" >&2
        return 1
    fi

    local repo_path="$owner/$repo_name"

    # Extract branch from /tree/<branch> if not provided via --branch
    if [[ -z "$branch" ]] && [[ "$url" =~ /tree/([^/]+) ]]; then
        branch="${BASH_REMATCH[1]}"
    fi
    [[ -z "$branch" ]] && branch="main"

    echo "  Downloading $(_cyan "$repo_path") (branch: $branch)..."

    local archive_url="https://github.com/$repo_path/archive/refs/heads/$branch.tar.gz"
    local archive_file="$tmp_dir/repo.tar.gz"

    if ! curl -sfL --max-time 30 -o "$archive_file" "$archive_url" 2>/dev/null; then
        # Fallback: try master when default branch was assumed
        if [[ "$branch" == "main" ]]; then
            echo "  $(_dim "Branch 'main' not found, trying 'master'...")"
            branch="master"
            archive_url="https://github.com/$repo_path/archive/refs/heads/$branch.tar.gz"
            if ! curl -sfL --max-time 30 -o "$archive_file" "$archive_url" 2>/dev/null; then
                echo "  $(_red "Error"): Failed to download repository." >&2
                echo "  Check the URL and your network connection." >&2
                return 1
            fi
        else
            echo "  $(_red "Error"): Failed to download branch '$branch'." >&2
            return 1
        fi
    fi

    tar -xzf "$archive_file" -C "$tmp_dir" || {
        echo "  $(_red "Error"): Failed to extract archive." >&2
        return 1
    }

    echo "  $(_green "Downloaded.")"
}

_import_from_archive() {
    local archive="$1" tmp_dir="$2"

    echo "  Extracting $(_cyan "$(basename "$archive")")..."

    tar -xzf "$archive" -C "$tmp_dir" || {
        echo "  $(_red "Error"): Failed to extract archive." >&2
        return 1
    }

    echo "  $(_green "Extracted.")"
}

_import_from_directory() {
    local src_dir="$1" tmp_dir="$2"

    src_dir="$(cd "$src_dir" 2>/dev/null && pwd)" || {
        echo "  $(_red "Error"): Cannot access directory: $1" >&2
        return 1
    }

    echo "  Reading from $(_cyan "$src_dir")..."

    # Only copy .ai/ and project config — never the entire project
    if [[ -d "$src_dir/.ai" ]]; then
        mkdir -p "$tmp_dir/.ai"
        cp -R "$src_dir/.ai/." "$tmp_dir/.ai/"
    fi
    # Legacy fallback: copy root-level config if .ai/ one doesn't exist
    if [[ ! -f "$tmp_dir/$_BUNDLE_CONFIG" ]] && [[ -f "$src_dir/$_BUNDLE_CONFIG_LEGACY" ]]; then
        mkdir -p "$tmp_dir/.ai"
        cp "$src_dir/$_BUNDLE_CONFIG_LEGACY" "$tmp_dir/$_BUNDLE_CONFIG"
    fi
}

# ── Find .ai/src inside extracted content ────────────────────────────────────

_import_find_ai_src() {
    local search_root="$1"

    # Direct: prefer .ai/src/ over .ai/
    if [[ -d "$search_root/.ai/src" ]]; then
        echo "$search_root/.ai/src"
        return 0
    fi
    if [[ -d "$search_root/.ai" ]]; then
        echo "$search_root/.ai"
        return 0
    fi

    # One level deep (GitHub archives extract into a subdirectory like repo-main/)
    local dir
    for dir in "$search_root"/*/; do
        [[ -d "$dir" ]] || continue
        if [[ -d "${dir}.ai/src" ]]; then
            echo "${dir}.ai/src"
            return 0
        fi
        if [[ -d "${dir}.ai" ]]; then
            echo "${dir}.ai"
            return 0
        fi
    done

    return 1
}

# ── Usage ────────────────────────────────────────────────────────────────────

_import_usage() {
    echo ""
    echo "  $(_bold "agentsync import") — import config from GitHub, archive, or directory"
    echo ""
    echo "  $(_green "USAGE")"
    echo "    agentsync import <source> [options]"
    echo ""
    echo "  $(_green "SOURCES")"
    echo "    GitHub URL       https://github.com/user/repo"
    echo "    Archive file     path/to/agentsync-bundle.tar.gz"
    echo "    Local directory  path/to/project/"
    echo ""
    echo "  $(_green "OPTIONS")"
    echo "    --branch, -b <name>   Git branch to download (default: main)"
    echo "    --only <targets>      Import only specific targets (comma-separated)"
    echo "                          Targets: rules,skills,commands,agents,settings,mcp,hooks,tools"
    echo "    --force               Overwrite without confirmation"
    echo "    --dry-run             Preview changes without writing"
    echo "    --help, -h            Show this message"
    echo ""
    echo "  $(_green "EXAMPLES")"
    echo "    agentsync import https://github.com/user/repo"
    echo "    agentsync import https://github.com/user/repo/tree/develop"
    echo "    agentsync import agentsync-bundle.tar.gz"
    echo "    agentsync import ../other-project/"
    echo "    agentsync import https://github.com/user/repo --only rules,skills"
    echo "    agentsync import bundle.tar.gz --dry-run"
    echo ""
}
