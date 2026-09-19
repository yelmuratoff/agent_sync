#!/usr/bin/env bash
# MCP library reading and validation. Explicit source materialization lives in
# mcp_library_bind.sh; no library command executes a described server.

readonly MCP_LIBRARY_MAX_MANIFEST_BYTES=131072
# Tests and constrained callers may lower the source limit, but never raise the
# 32 MiB safety ceiling.
_mcp_library_source_limit="${MCP_LIBRARY_MAX_SOURCE_BYTES:-33554432}"
if [[ ! "$_mcp_library_source_limit" =~ ^[1-9][0-9]*$ ]] || \
   (( ${#_mcp_library_source_limit} > 8 )) || \
   { (( ${#_mcp_library_source_limit} == 8 )) && (( _mcp_library_source_limit > 33554432 )); }; then
    _mcp_library_source_limit=33554432
fi
readonly MCP_LIBRARY_MAX_SOURCE_BYTES="$_mcp_library_source_limit"
unset _mcp_library_source_limit
readonly MCP_LIBRARY_MAX_DEPTH=16
readonly MCP_LIBRARY_MAX_ENTRIES=256

_mcp_library_error() {
    echo "$(_red "Error"): $*" >&2
}

_mcp_library_usage() {
    cat <<'USAGE'
Usage:
  agentsync mcp list [--library PATH]
  agentsync mcp show <id> [--library PATH]
  agentsync mcp validate [id] [--library PATH]
  agentsync mcp render <id[@variant]>... [--variant NAME] [--library PATH]
  agentsync mcp use <id[@variant]>... --tool claude|opencode|codex|kimi [--apply]
                    [--merge [--replace ID]...] [--variant NAME] [--library PATH]

Read an explicitly selected local MCP library. --library may be absolute or
relative to the selected AgentSync root. Without it, library.mcp.path in the
selected agent_sync.yaml is required. render emits an AgentSync MCP source, not
a native OpenCode config. use previews that source; --apply creates a per-tool
source for a later sync. --merge is limited to an existing canonical per-tool
source and requires --replace ID for every selected differing server.
Variant defaults to default; recommended must be explicitly requested.
USAGE
}

_mcp_library_valid_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

_mcp_library_path_within() {
    local path="$1"
    local root="$2"
    [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

# Set REPLY to a canonical file path while following a bounded symlink chain.
# The caller checks that the result remains inside its selected catalog.
_mcp_library_canonical_file_r() {
    local path="$1" target dir hops=0
    while [[ -L "$path" ]]; do
        [[ $hops -lt 40 ]] || return 1
        hops=$((hops + 1))
        target=$(readlink "$path") || return 1
        if [[ "$target" != /* ]]; then
            dir=$(cd -P "${path%/*}" 2>/dev/null && pwd) || return 1
            target="$dir/$target"
        fi
        path="$target"
    done
    [[ -f "$path" ]] || return 1
    dir=$(cd -P "${path%/*}" 2>/dev/null && pwd) || return 1
    REPLY="$dir/${path##*/}"
}

_mcp_library_parser() {
    local manifest="$1"
    local expected_id="${2:-}"
    local output_mode="${3:-validate}"
    local selected_variant="${4:-default}"
    local max_bytes="${5:-$MCP_LIBRARY_MAX_MANIFEST_BYTES}"
    local overlay_path="${6:-}"
    local replace_ids="${7:-}"
    _mcp_library_valid_id "$selected_variant" || {
        _mcp_library_error "Unsafe MCP variant: $selected_variant"
        return 1
    }
    [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || {
        _mcp_library_error "Invalid MCP parser byte limit"
        return 1
    }
    local size
    size=$(wc -c < "$manifest") || {
        _mcp_library_error "Cannot read manifest: $manifest"
        return 1
    }
    if (( size > max_bytes )); then
        _mcp_library_error "MCP source exceeds ${max_bytes} byte limit: $manifest"
        return 1
    fi

    # Native macOS awk can truncate input at NUL before JSON parsing begins.
    # Check bytes, not shell strings; escaped JSON NUL remains valid data.
    local input input_size nonnul_size
    for input in "$manifest" "$overlay_path"; do
        [[ -n "$input" ]] || continue
        input_size=$(wc -c < "$input") || return 1
        (( input_size <= max_bytes )) || {
            _mcp_library_error "MCP input exceeds ${max_bytes} byte limit"
            return 1
        }
        nonnul_size=$(set -o pipefail; LC_ALL=C tr -d '\000' < "$input" | wc -c) || return 1
        if (( nonnul_size != input_size )); then
            _mcp_library_error "MCP input contains a raw NUL byte"
            return 1
        fi
    done

    local parser="${BASH_SOURCE[0]%/*}/mcp_library_parser.awk"
    local diagnostic
    diagnostic=$(LC_ALL=C awk \
        -v max_depth="$MCP_LIBRARY_MAX_DEPTH" \
        -v max_bytes="$max_bytes" \
        -v expected_id="$expected_id" \
        -v output_mode="$output_mode" \
        -v selected_variant="$selected_variant" \
        -v overlay_path="$overlay_path" \
        -v replace_ids="$replace_ids" \
        -f "$parser" "$manifest" 2>&1) || {
        _mcp_library_error "${diagnostic:-Malformed MCP library manifest: $manifest}"
        return 1
    }
    [[ -n "$diagnostic" ]] && printf '%s\n' "$diagnostic"
    return 0
}

_mcp_library_merge_source_r() (
    local source="$1" payload="$2" mode="$3" replace_ids="$4"
    local overlay=""
    _mcp_library_merge_cleanup() {
        [[ -z "$overlay" ]] || rm -f -- "$overlay"
    }
    trap _mcp_library_merge_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    overlay=$(mktemp "${TMPDIR:-/tmp}/agentsync-mcp-overlay.XXXXXX") || return 1
    if ! printf '%s\n' "$payload" > "$overlay"; then
        return 1
    fi
    local status=0
    _mcp_library_parser "$source" "" "$mode" default "$MCP_LIBRARY_MAX_SOURCE_BYTES" "$overlay" "$replace_ids" || status=$?
    return "$status"
)

_mcp_library_select_root_r() {
    local explicit_path="$1"
    local root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    root=$(cd -P "$root" 2>/dev/null && pwd) || {
        _mcp_library_error "Selected AgentSync root does not exist: ${AGENTSYNC_REPO_ROOT:-$(pwd)}"
        return 1
    }

    local raw_path="$explicit_path" config_path
    if [[ -z "$raw_path" ]]; then
        project_config_path_r "$root"
        config_path="$REPLY"
        if [[ -n "${AGENTSYNC_CONFIG_PATH:-}" && ! -f "$config_path" ]]; then
            _mcp_library_error "AGENTSYNC_CONFIG_PATH is set but file not found: $config_path"
            return 1
        fi
        if [[ -z "$config_path" ]]; then
            _mcp_library_error "No MCP library selected. Pass --library PATH or configure library.mcp.path."
            return 1
        fi
        parse_yaml_value_r "$config_path" "library.mcp.path"
        raw_path="$REPLY"
        if [[ -z "$raw_path" ]]; then
            _mcp_library_error "No MCP library selected. Pass --library PATH or configure library.mcp.path."
            return 1
        fi
        [[ "$raw_path" == /* ]] || raw_path="$root/$raw_path"
    elif [[ "$raw_path" != /* ]]; then
        raw_path="$root/$raw_path"
    fi

    local catalog
    catalog=$(cd -P "$raw_path" 2>/dev/null && pwd) || {
        _mcp_library_error "MCP library directory not found: $raw_path"
        return 1
    }
    if [[ -z "$explicit_path" ]] && ! _mcp_library_path_within "$catalog" "$root"; then
        _mcp_library_error "Configured MCP library resolves outside the selected root: $raw_path -> $catalog"
        return 1
    fi
    REPLY="$catalog"
}

_mcp_library_manifest_r() {
    local catalog="$1"
    local id="$2"
    _mcp_library_valid_id "$id" || {
        _mcp_library_error "Unsafe MCP library id: $id"
        return 1
    }

    local entry="$catalog/$id"
    if [[ -L "$entry" ]]; then
        _mcp_library_error "MCP library entry must not be a symlink: $id"
        return 1
    fi
    [[ -d "$entry" ]] || {
        _mcp_library_error "Unknown MCP library id '$id' in $catalog"
        return 1
    }
    local entry_canonical
    entry_canonical=$(cd -P "$entry" 2>/dev/null && pwd) || return 1
    if ! _mcp_library_path_within "$entry_canonical" "$catalog"; then
        _mcp_library_error "MCP library entry resolves outside the selected catalog: $id"
        return 1
    fi

    _mcp_library_canonical_file_r "$entry/manifest.json" || {
        _mcp_library_error "Missing readable manifest for MCP library id '$id'"
        return 1
    }
    if ! _mcp_library_path_within "$REPLY" "$catalog"; then
        _mcp_library_error "Manifest for MCP library id '$id' resolves outside the selected catalog"
        return 1
    fi
}

# Print catalog entry directories in deterministic order. A root-level symlink
# is rejected before it can become a path escape through a catalog entry.
_mcp_library_entry_dirs() {
    local catalog="$1" path name
    local -a names=()
    if [[ ! -r "$catalog" || ! -x "$catalog" ]]; then
        _mcp_library_error "MCP library directory is not readable: $catalog"
        return 1
    fi
    for path in "$catalog"/*; do
        [[ -e "$path" || -L "$path" ]] || continue
        name="${path##*/}"
        # Root-level files and hidden directories are not catalog entries. IDs
        # cannot start with a dot, so they cannot hide an entry from this scan.
        [[ -d "$path" || -L "$path" ]] || continue
        if ! _mcp_library_valid_id "$name"; then
            _mcp_library_error "Unsafe MCP library entry directory: $name"
            return 1
        fi
        names+=("$name")
    done

    if (( ${#names[@]} > MCP_LIBRARY_MAX_ENTRIES )); then
        _mcp_library_error "MCP library exceeds ${MCP_LIBRARY_MAX_ENTRIES} entry limit"
        return 1
    fi
    if (( ${#names[@]} > 0 )); then
        printf '%s\n' "${names[@]}" | LC_ALL=C sort
    fi
}

_mcp_library_validate_catalog() {
    local catalog="$1"
    local id manifest metadata parsed_id entries
    local -a ids=() dirs=()
    entries=$(_mcp_library_entry_dirs "$catalog") || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        _mcp_library_manifest_r "$catalog" "$id" || return 1
        manifest="$REPLY"
        metadata=$(_mcp_library_parser "$manifest" "" metadata) || return 1
        IFS=$'\t' read -r parsed_id _ <<< "$metadata"

        local seen
        for seen in "${ids[@]+"${ids[@]}"}"; do
            if [[ "$seen" == "$parsed_id" ]]; then
                _mcp_library_error "Duplicate MCP library id '$parsed_id'"
                return 1
            fi
        done
        ids+=("$parsed_id")
        dirs+=("$id")
    done <<< "$entries"

    local index
    for ((index = 0; index < ${#ids[@]}; index++)); do
        if [[ "${ids[index]}" != "${dirs[index]}" ]]; then
            _mcp_library_error "Manifest id '${ids[index]}' does not match catalog directory '${dirs[index]}'"
            return 1
        fi
    done
}

cmd_mcp_library() {
    local action="${1:-}"
    [[ -n "$action" ]] || { _mcp_library_usage >&2; return 1; }
    case "$action" in
        --help|-h|help) _mcp_library_usage; return 0 ;;
        render|use)
            _need paths tool_resolver mcp_library_bind
            cmd_mcp_library_bind "$@"
            return
            ;;
    esac
    shift

    local library="" id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --library)
                [[ $# -ge 2 ]] || { _mcp_library_error "--library requires a path"; return 1; }
                [[ -n "$2" ]] || { _mcp_library_error "--library requires a non-empty path"; return 1; }
                library="$2"
                shift 2
                ;;
            --help|-h)
                _mcp_library_usage
                return 0
                ;;
            -*)
                _mcp_library_error "Unknown MCP library option: $1"
                return 1
                ;;
            *)
                if [[ -n "$id" ]]; then
                    _mcp_library_error "Unexpected MCP library argument: $1"
                    return 1
                fi
                id="$1"
                shift
                ;;
        esac
    done

    case "$action" in
        list)
            [[ -z "$id" ]] || { _mcp_library_error "mcp list does not take an id"; return 1; }
            ;;
        show)
            [[ -n "$id" ]] || { _mcp_library_error "mcp show requires an id"; return 1; }
            ;;
        validate)
            ;;
        *)
            _mcp_library_error "Unknown MCP command '$action'. Use list, show, or validate."
            return 1
            ;;
    esac

    _mcp_library_select_root_r "$library" || return 1
    local catalog="$REPLY" manifest metadata item_id title

    if [[ "$action" == "list" ]]; then
        # A list is only useful when it names a coherent catalog. This also
        # ensures an enumeration failure cannot be turned into an empty list.
        _mcp_library_validate_catalog "$catalog" || return 1
        local entry_id entries
        entries=$(_mcp_library_entry_dirs "$catalog") || return 1
        while IFS= read -r entry_id; do
            [[ -n "$entry_id" ]] || continue
            _mcp_library_manifest_r "$catalog" "$entry_id" || return 1
            metadata=$(_mcp_library_parser "$REPLY" "$entry_id" metadata) || return 1
            IFS=$'\t' read -r item_id title <<< "$metadata"
            printf '%s\t%s\n' "$item_id" "$title"
        done <<< "$entries"
        return 0
    fi

    if [[ "$action" == "validate" && -z "$id" ]]; then
        _mcp_library_validate_catalog "$catalog" || return 1
        echo "MCP library is valid: $catalog"
        return 0
    fi

    _mcp_library_manifest_r "$catalog" "$id" || return 1
    manifest="$REPLY"
    metadata=$(_mcp_library_parser "$manifest" "$id" metadata) || return 1

    case "$action" in
        validate)
            echo "MCP library entry is valid: $id"
            ;;
        show)
            # The parser validates first; printing the source file keeps all
            # supported JSON spelling, Unicode, and argument strings intact.
            cat "$manifest"
            ;;
        list)
            # list never reaches here because it has no id; kept for clarity.
            ;;
    esac
}
