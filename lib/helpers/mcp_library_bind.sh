#!/usr/bin/env bash
# Materialize an explicit library selection as an ordinary per-tool MCP source.
# Deliberately no live bindings, dependency installs, native writes or overwrites.

_mcp_library_render_r() {
    local catalog="$1" default_variant="$2"
    shift 2
    local selection id variant manifest server info seen
    local body="" separator=""
    local -a ids=()
    for selection in "$@"; do
        id="${selection%%@*}"
        variant="$default_variant"
        [[ "$selection" != *@* ]] || variant="${selection#*@}"
        _mcp_library_valid_id "$id" && _mcp_library_valid_id "$variant" || {
            _mcp_library_error "Expected a safe id or id@variant: $selection"
            return 1
        }
        for seen in "${ids[@]+"${ids[@]}"}"; do
            [[ "$seen" != "$id" ]] || {
                _mcp_library_error "Duplicate selected MCP id: $id"
                return 1
            }
        done
        ids+=("$id")
        _mcp_library_manifest_r "$catalog" "$id" || return 1
        manifest="$REPLY"
        server=$(_mcp_library_parser "$manifest" "$id" server "$variant") || return 1
        info=$(_mcp_library_parser "$manifest" "$id" selection "$variant") || return 1
        # The parser escapes all display controls; metadata never enters JSON.
        printf 'Selected %s: %s\n' "$id" "$info" >&2
        body="$body$separator\"$id\":$server"
        separator=","
    done
    REPLY="{\"mcpServers\":{$body}}"
}

# Refuse symlink components even if they currently resolve inside the project.
# Canonicalizing the project root once permits a user-selected root symlink.
_mcp_library_write_path_ok() {
    local target="$1" root="$2" part current="$2" rest
    _mcp_library_path_within "$target" "$root" || return 1
    [[ "$target" != "$root" ]] || return 1
    rest="${target#"$root/"}"
    while [[ -n "$rest" ]]; do
        part="${rest%%/*}"
        [[ "$part" != . && "$part" != .. && -n "$part" ]] || return 1
        current="$current/$part"
        [[ ! -L "$current" ]] || return 1
        if [[ "$rest" == */* ]]; then
            [[ ! -e "$current" || -d "$current" ]] || return 1
            rest="${rest#*/}"
        else
            rest=""
        fi
    done
}

_mcp_library_staged_source_within_limit() {
    local staged="$1" size
    size=$(wc -c < "$staged") || return 1
    if (( size > MCP_LIBRARY_MAX_SOURCE_BYTES )); then
        _mcp_library_error "Merged MCP source exceeds ${MCP_LIBRARY_MAX_SOURCE_BYTES} byte limit"
        return 1
    fi
}

_mcp_library_source_target_r() {
    local tool="$1" payload="$2" allow_existing="${3:-false}"
    local target dir path declared user_file lock
    tool_resolver_init_user_dir
    normalize_absolute_path_r "$TOOL_RESOLVER_USER_DIR/$tool/mcp.json"
    target="$REPLY"
    _mcp_library_write_path_ok "$target" "$REPO_ROOT" || {
        _mcp_library_error "Refusing MCP source outside the project or through a symlink: $target"
        return 1
    }
    # A project declaration is intent, even before its file exists. Distinguish
    # it from the built-in legacy default so normal new projects still work.
    user_file=$(tool_resolver_user_file "$tool")
    parse_yaml_value_r "$user_file" targets.mcp.source
    declared="$REPLY"
    if [[ -n "$declared" ]]; then
        [[ "$declared" == /* ]] || declared="$REPO_ROOT/$declared"
        normalize_absolute_path_r "$declared"
        [[ "$REPLY" == "$target" ]] || {
            _mcp_library_error "Declared MCP source would be shadowed: $declared"
            return 1
        }
    fi
    if [[ -e "$target" ]]; then
        if [[ -f "$target" ]] && cmp -s "$target" <(printf '%s\n' "$payload"); then
            REPLY="$target"
            return 0
        fi
        [[ "$allow_existing" == true ]] || {
            _mcp_library_error "Existing MCP source differs; use render and merge explicitly: $target"
            return 1
        }
    fi
    # Creating a higher-priority source must not silently shadow user entries.
    dir="${target%/*}"
    lock="${target}.mcp-library.lock"
    for path in "$dir"/mcp.* "$REPO_ROOT/.ai/src/mcp/$tool".* "$REPO_ROOT/.ai/src/mcp.json"; do
        [[ "$path" == "$target" || "$path" == "$lock" ]] && continue
        if [[ -e "$path" || -L "$path" ]]; then
            _mcp_library_error "Existing MCP source would be shadowed; use render and merge explicitly: $path"
            return 1
        fi
    done
    get_tool_value_r "$tool" targets.mcp.source
    declared="$REPLY"
    if [[ -n "$declared" ]]; then
        [[ "$declared" == /* ]] || declared="$REPO_ROOT/$declared"
        normalize_absolute_path_r "$declared"
        declared="$REPLY"
        # The effective declaration may intentionally name this canonical
        # source. It is not a competing source for an explicit merge.
        if [[ "$declared" != "$target" ]] && [[ -e "$declared" || -L "$declared" ]]; then
            _mcp_library_error "Declared MCP source would be shadowed: $declared"
            return 1
        fi
    fi
    REPLY="$target"
}

cmd_mcp_library_bind() (
    # macOS Bash can unwind function locals before the EXIT trap on a signal.
    # This entire function is a subshell, so these paths cannot leak to callers.
    cleanup_snapshot="" cleanup_staging="" cleanup_lock=""
    _mcp_library_bind_cleanup() {
        [[ -z "$cleanup_snapshot" ]] || rm -f -- "$cleanup_snapshot"
        [[ -z "$cleanup_staging" ]] || rm -f -- "$cleanup_staging"
        [[ -z "$cleanup_lock" ]] || rmdir "$cleanup_lock" 2>/dev/null || true
    }
    trap _mcp_library_bind_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local action="$1" library="" tool="" default_variant="default" apply=false dry_run=false merge=false
    shift
    local -a selections=() replace_ids=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --library|--tool|--variant)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
                    _mcp_library_error "$1 requires a non-empty value"
                    return 1
                }
                case "$1" in
                    --library) library="$2" ;;
                    --tool) tool="$2" ;;
                    --variant) default_variant="$2" ;;
                esac
                shift 2 ;;
            --apply) apply=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --merge) merge=true; shift ;;
            --replace)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
                    _mcp_library_error "--replace requires a non-empty id"
                    return 1
                }
                _mcp_library_valid_id "$2" || { _mcp_library_error "Unsafe replacement id: $2"; return 1; }
                replace_ids+=("$2")
                shift 2 ;;
            --help|-h) _mcp_library_usage; return 0 ;;
            -*) _mcp_library_error "Unknown MCP option: $1"; return 1 ;;
            *) selections+=("$1"); shift ;;
        esac
    done
    (( ${#selections[@]} > 0 && ${#selections[@]} <= MCP_LIBRARY_MAX_ENTRIES )) || {
        _mcp_library_error "Select between 1 and $MCP_LIBRARY_MAX_ENTRIES MCP entries"
        return 1
    }
    [[ "$apply" != true || "$dry_run" != true ]] || {
        _mcp_library_error "--apply and --dry-run are mutually exclusive"; return 1
    }
    _mcp_library_valid_id "$default_variant" || { _mcp_library_error "Unsafe variant"; return 1; }
    [[ "$merge" == true || ${#replace_ids[@]} -eq 0 ]] || {
        _mcp_library_error "--replace requires --merge"
        return 1
    }
    if [[ "$action" == render ]]; then
        [[ -z "$tool" && "$apply" == false && "$merge" == false ]] || {
            _mcp_library_error "render produces a source fragment; use use --tool for materialization"
            return 1
        }
    else
        case "$tool" in
            claude|opencode|codex|kimi) ;;
            *) _mcp_library_error "use requires --tool claude, opencode, codex or kimi; other adapters are not supported yet"; return 1 ;;
        esac
    fi
    _mcp_library_select_root_r "$library" || return 1
    local catalog="$REPLY" payload
    _mcp_library_render_r "$catalog" "$default_variant" "${selections[@]}" || return 1
    payload="$REPLY"
    local selection selected_id replace_id found
    for replace_id in "${replace_ids[@]+"${replace_ids[@]}"}"; do
        found=false
        for selection in "${selections[@]}"; do
            selected_id="${selection%%@*}"
            [[ "$replace_id" != "$selected_id" ]] || { found=true; break; }
        done
        [[ "$found" == true ]] || {
            _mcp_library_error "Replacement id is not selected: $replace_id"
            return 1
        }
    done
    if [[ "$action" == render ]]; then
        printf '%s\n' "$payload"
        return 0
    fi

    # Dynamic locals supply the same resolver context as sync without touching
    # any native config. Explicit missing config never falls back.
    local REPO_ROOT DEFAULT_REPO_ROOT PROJECT_CONFIG_PATH TOOL_RESOLVER_USER_DIR
    REPO_ROOT=$(cd -P "${AGENTSYNC_REPO_ROOT:-.}" && pwd) || return 1
    # shellcheck disable=SC2034 # consumed by the shared tool resolver
    DEFAULT_REPO_ROOT="$_AGENTSYNC_ENGINE_ROOT"
    project_config_path_r "$REPO_ROOT" || {
        _mcp_library_error "AGENTSYNC_CONFIG_PATH is set but file not found: $REPLY"; return 1
    }
    PROJECT_CONFIG_PATH="$REPLY"
    [[ -n "$PROJECT_CONFIG_PATH" ]] || { _mcp_library_error "Initialize an AgentSync project before use"; return 1; }
    local enabled=false candidate
    tool_resolver_init_user_dir
    while IFS= read -r candidate; do
        [[ "$candidate" != "$tool" ]] || enabled=true
    done < <(list_enabled_tools)
    [[ "$enabled" == true ]] || { _mcp_library_error "Enable $tool explicitly before use"; return 1; }
    [[ "$(get_tool_bool "$tool" targets.mcp.enabled)" != false ]] || {
        _mcp_library_error "Enable the MCP target for $tool before use"
        return 1
    }
    if [[ "$tool" == codex ]]; then
        _need codex
        local settings
        settings=$(resolve_payload_source "$tool" settings)
        codex_settings_allow_mcp "$settings" || {
            _mcp_library_error "Codex MCP ownership conflict or ambiguous settings keys; keep MCP in one source"
            return 1
        }
    fi
    _mcp_library_source_target_r "$tool" "$payload" "$merge" || return 1
    local target="$REPLY" staging="" snapshot="" plan merged replace_csv="" lock=""
    if [[ "$merge" == true ]]; then
        [[ -f "$target" && ! -L "$target" ]] || {
            _mcp_library_error "--merge requires an existing canonical per-tool MCP source: $target"
            return 1
        }
        for replace_id in "${replace_ids[@]+"${replace_ids[@]}"}"; do
            if [[ -n "$replace_csv" ]]; then
                replace_csv+=","
            fi
            replace_csv+="$replace_id"
        done
        if [[ "$apply" == true ]]; then
            lock="${target}.mcp-library.lock"
            _mcp_library_write_path_ok "$lock" "$REPO_ROOT" || {
                _mcp_library_error "Refusing MCP merge lock outside the project or through a symlink: $lock"
                return 1
            }
            if ! mkdir "$lock"; then
                _mcp_library_error "MCP source is locked by another merge; remove a stale lock after an interrupted run: $lock"
                return 1
            fi
            cleanup_lock="$lock"
        fi
        snapshot=$(mktemp "${TMPDIR:-/tmp}/agentsync-mcp-source.XXXXXX") || return 1
        cleanup_snapshot="$snapshot"
        if ! cp "$target" "$snapshot"; then
            rm -f "$snapshot"
            return 1
        fi
        plan=$(_mcp_library_merge_source_r "$snapshot" "$payload" merge-plan "$replace_csv") || {
            rm -f "$snapshot"
            return 1
        }
        local action needs_write=false
        while IFS=$'\t' read -r selected_id action; do
            [[ -n "$selected_id" ]] || continue
            case "$action" in
                add|replace) needs_write=true ;;
                identical) ;;
                *) rm -f "$snapshot"; _mcp_library_error "Invalid MCP merge plan"; return 1 ;;
            esac
        done <<< "$plan"
        if [[ "$apply" != true ]]; then
            while IFS=$'\t' read -r selected_id action; do
                [[ -n "$selected_id" ]] && printf 'Preview: %s %s in %s; native config is unchanged.\n' "$action" "$selected_id" "$target" >&2
            done <<< "$plan"
            rm -f "$snapshot"
            return 0
        fi
        if [[ "$needs_write" != true ]]; then
            rm -f "$snapshot"
            printf 'MCP source already matches: %s\n' "$target"
            return 0
        fi
        merged=$(_mcp_library_merge_source_r "$snapshot" "$payload" merge-json "$replace_csv") || {
            rm -f "$snapshot"
            return 1
        }
        _mcp_library_write_path_ok "$target" "$REPO_ROOT" || { rm -f "$snapshot"; return 1; }
        staging=$(mktemp "${target%/*}/.mcp-library.XXXXXX") || { rm -f "$snapshot"; return 1; }
        cleanup_staging="$staging"
        if ! printf '%s\n' "$merged" > "$staging"; then
            rm -f "$snapshot" "$staging"
            return 1
        fi
        _mcp_library_staged_source_within_limit "$staging" || return 1
        if ! cmp -s "$target" "$snapshot"; then
            rm -f "$snapshot" "$staging"
            _mcp_library_error "MCP source changed after preview; nothing overwritten: $target"
            return 1
        fi
        _need backup
        backup_configure "$REPO_ROOT" || { rm -f "$snapshot" "$staging"; return 1; }
        (
            umask 077
            backup_create "$REPO_ROOT" mcp-use-merge "$target"
        ) >/dev/null || { rm -f "$snapshot" "$staging"; return 1; }
        if ! cmp -s "$target" "$snapshot"; then
            rm -f "$snapshot" "$staging"
            _mcp_library_error "MCP source changed after preview; nothing overwritten: $target"
            return 1
        fi
        # A hostile directory race between this check and mv is outside this
        # local-path guard; ordinary concurrent file edits are rejected above.
        mv "$staging" "$target" || { rm -f "$snapshot" "$staging"; return 1; }
        rm -f "$snapshot"
        printf 'Merged MCP source: %s\nRun agentsync sync --only %s to update native config.\n' "$target" "$tool"
        return 0
    fi
    if [[ "$apply" != true ]]; then
        printf 'Preview: create %s; native config is unchanged. Add --apply, then run sync --only %s.\n' "$target" "$tool" >&2
        printf '%s\n' "$payload"
        return 0
    fi
    if [[ -f "$target" ]]; then
        printf 'MCP source already matches: %s\n' "$target"
        return 0
    fi
    mkdir -p "${target%/*}" || return 1
    _mcp_library_write_path_ok "$target" "$REPO_ROOT" || return 1
    staging=$(mktemp "${target%/*}/.mcp-library.XXXXXX") || return 1
    cleanup_staging="$staging"
    if ! printf '%s\n' "$payload" > "$staging"; then
        rm -f "$staging"
        return 1
    fi
    # Publish a complete file without replacing a concurrently created file.
    if [[ -e "$target" || -L "$target" ]] || ! ln "$staging" "$target"; then
        rm -f "$staging"
        _mcp_library_error "MCP source appeared concurrently; nothing overwritten: $target"
        return 1
    fi
    rm -f "$staging"
    printf 'Created MCP source: %s\nRun agentsync sync --only %s to update native config.\n' "$target" "$tool"
)
