#!/usr/bin/env bash
# Transactional backups for AgentSync-managed project paths.
#
# A snapshot mirrors each existing target below .ai/backups/<id>/files/ and
# records missing targets as well, so restore can remove paths created by a
# failed or accidental operation. Snapshot directories are self-ignored by git.

BACKUP_PREPARED_TARGETS=()
BACKUP_LOADED_STATES=()
BACKUP_LOADED_RELS=()
BACKUP_LOADED_PATHS=()
ROLLBACK_ROOT=""
ROLLBACK_SAFETY_PATH=""
ROLLBACK_TRANSACTION_ACTIVE="false"

_backup_error() {
    echo "Error: $1" >&2
}

_backup_canonical_root() {
    local root="$1"
    [[ -d "$root" ]] || {
        _backup_error "Backup root is not a directory: $root"
        return 1
    }
    cd -P "$root" 2>/dev/null && pwd
}

_backup_validate_rel() {
    local rel="$1"
    local allow_store_parent="${2:-false}"

    if [[ -z "$rel" ]] || [[ "$rel" == "." ]] || [[ "$rel" == /* ]]; then
        _backup_error "Refusing unsafe backup target: ${rel:-<empty>}"
        return 1
    fi
    case "/$rel/" in
        */../*|*/./*)
            _backup_error "Refusing non-normalized backup target: $rel"
            return 1
            ;;
    esac
    case "$rel" in
        .ai)
            if [[ "$allow_store_parent" != "true" ]]; then
                _backup_error "Refusing to back up a parent of the backup store: $rel"
                return 1
            fi
            ;;
        .ai/backups|.ai/backups/*)
            _backup_error "Refusing to back up the backup store itself: $rel"
            return 1
            ;;
    esac
    if [[ "$rel" == *$'\t'* ]] || [[ "$rel" == *$'\n'* ]] || [[ "$rel" == *$'\r'* ]]; then
        _backup_error "Backup targets cannot contain tabs or newlines"
        return 1
    fi
}

_backup_safe_target_path() {
    local canonical_root="$1"
    local rel="$2"
    local allow_store_parent="${3:-false}"
    _backup_validate_rel "$rel" "$allow_store_parent" || return 1

    local abs="$canonical_root/$rel"
    local probe
    probe=$(dirname "$abs")
    while [[ ! -e "$probe" ]] && [[ ! -L "$probe" ]]; do
        local parent
        parent=$(dirname "$probe")
        [[ "$parent" != "$probe" ]] || break
        probe="$parent"
    done

    if [[ ! -d "$probe" ]]; then
        _backup_error "Backup target parent is not a directory: $rel"
        return 1
    fi

    local resolved
    resolved=$(cd -P "$probe" 2>/dev/null && pwd) || {
        _backup_error "Could not resolve backup target parent: $rel"
        return 1
    }
    if [[ "$resolved" != "$canonical_root" ]] && [[ "$resolved" != "$canonical_root/"* ]]; then
        _backup_error "Backup target resolves outside the repository root: $rel"
        return 1
    fi

    echo "$abs"
}

_backup_target_abs() {
    local supplied_root="$1"
    local canonical_root="$2"
    local target="$3"
    local rel=""

    if [[ "$target" == "$supplied_root" ]] || [[ "$target" == "$canonical_root" ]]; then
        _backup_error "Refusing to back up the repository root"
        return 1
    elif [[ "$target" == "$supplied_root/"* ]]; then
        rel="${target#"$supplied_root"/}"
    elif [[ "$target" == "$canonical_root/"* ]]; then
        rel="${target#"$canonical_root"/}"
    elif [[ "$target" != /* ]]; then
        rel="$target"
    else
        _backup_error "Backup target is outside the repository root: $target"
        return 1
    fi

    _backup_validate_rel "$rel" || return 1
    _backup_safe_target_path "$canonical_root" "$rel"
}

# Normalize, validate, deduplicate, and collapse nested paths into their
# shallowest target root. Results are placed in BACKUP_PREPARED_TARGETS.
_backup_prepare_targets() {
    local supplied_root="$1"
    shift
    local canonical_root
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1

    BACKUP_PREPARED_TARGETS=()
    local target candidate existing skip_existing
    for target in "$@"; do
        candidate=$(_backup_target_abs "$supplied_root" "$canonical_root" "$target") || return 1
        skip_existing=false
        local -a retained=()

        for existing in "${BACKUP_PREPARED_TARGETS[@]+"${BACKUP_PREPARED_TARGETS[@]}"}"; do
            if [[ "$candidate" == "$existing" ]] || [[ "$candidate" == "$existing/"* ]]; then
                skip_existing=true
                retained+=("$existing")
            elif [[ "$existing" == "$candidate/"* ]]; then
                continue
            else
                retained+=("$existing")
            fi
        done

        BACKUP_PREPARED_TARGETS=("${retained[@]+"${retained[@]}"}")
        if [[ "$skip_existing" != "true" ]]; then
            BACKUP_PREPARED_TARGETS+=("$candidate")
        fi
    done

    if [[ ${#BACKUP_PREPARED_TARGETS[@]} -eq 0 ]]; then
        _backup_error "No backup targets were provided"
        return 1
    fi
}

_backup_store_root() {
    local canonical_root="$1"
    echo "$canonical_root/.ai/backups"
}

_backup_validate_store() {
    local canonical_root="$1"
    local ai_dir="$canonical_root/.ai"
    local store
    store=$(_backup_store_root "$canonical_root")

    _backup_safe_target_path "$canonical_root" ".ai" "true" >/dev/null || return 1
    if [[ -L "$ai_dir" ]]; then
        _backup_error "AgentSync state directory cannot be a symlink: .ai"
        return 1
    fi
    if [[ -e "$ai_dir" ]] && [[ ! -d "$ai_dir" ]]; then
        _backup_error "AgentSync state path is not a directory: .ai"
        return 1
    fi
    if [[ -d "$ai_dir" ]] && [[ "$(cd -P "$ai_dir" && pwd)" != "$canonical_root/.ai" ]]; then
        _backup_error "AgentSync state directory resolves outside the repository root"
        return 1
    fi

    if [[ -L "$store" ]]; then
        _backup_error "Backup store cannot be a symlink: .ai/backups"
        return 1
    fi
    if [[ -e "$store" ]] && [[ ! -d "$store" ]]; then
        _backup_error "Backup store is not a directory: .ai/backups"
        return 1
    fi
    if [[ -d "$store" ]]; then
        local resolved
        resolved=$(cd -P "$store" 2>/dev/null && pwd) || return 1
        if [[ "$resolved" != "$canonical_root/.ai/backups" ]]; then
            _backup_error "Backup store resolves outside the repository root"
            return 1
        fi
    fi

    echo "$store"
}

_backup_write_latest() {
    local store="$1"
    local snapshot_id="$2"
    local tmp
    tmp=$(mktemp "$store/.latest.tmp.XXXXXX") || return 1

    printf '%s\n' "$snapshot_id" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$store/.latest"
}

_backup_write_ignore() {
    local store="$1"
    local tmp
    tmp=$(mktemp "$store/.gitignore.tmp.XXXXXX") || return 1
    printf '*\n' > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$store/.gitignore"
}

_backup_copy() {
    local src="$1"
    local dest="$2"

    # APFS clonefile (macOS), then reflink where GNU cp/filesystem supports it.
    # Both are copy-on-write; the portable physical copy remains the fallback.
    cp -c -pPR "$src" "$dest" 2>/dev/null && return 0
    rm -rf "$dest"
    cp --reflink=auto -pPR "$src" "$dest" 2>/dev/null && return 0
    rm -rf "$dest"
    cp -pPR "$src" "$dest"
}

# Usage: backup_create <project-root> <operation> <absolute-or-relative-target>...
backup_create() {
    local supplied_root="$1"
    local operation="$2"
    shift 2

    if [[ ! "$operation" =~ ^[a-z][a-z0-9-]*$ ]]; then
        _backup_error "Invalid backup operation name: $operation"
        return 1
    fi

    local canonical_root
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    _backup_prepare_targets "$supplied_root" "$@" || return 1

    local store
    store=$(_backup_validate_store "$canonical_root") || return 1
    mkdir -p "$store" || return 1
    store=$(_backup_validate_store "$canonical_root") || return 1
    _backup_write_ignore "$store" || return 1

    local stage
    stage=$(mktemp -d "$store/.tmp.${operation}.XXXXXX") || return 1
    mkdir -p "$stage/files" || {
        rm -rf "$stage"
        return 1
    }

    local created snapshot_id final counter=1
    created=$(date -u +%Y%m%dT%H%M%SZ)
    snapshot_id="${created}-${operation}-$$"
    final="$store/$snapshot_id"
    while [[ -e "$final" ]]; do
        counter=$((counter + 1))
        snapshot_id="${created}-${operation}-$$-$counter"
        final="$store/$snapshot_id"
    done

    {
        echo "schema=1"
        echo "operation=$operation"
        echo "created_at=$created"
    } > "$stage/metadata" || {
        rm -rf "$stage"
        return 1
    }
    : > "$stage/targets.tsv"

    local abs rel state
    local -a present_args=()
    for abs in "${BACKUP_PREPARED_TARGETS[@]}"; do
        rel="${abs#"$canonical_root"/}"
        state="missing"
        if [[ -e "$abs" ]] || [[ -L "$abs" ]]; then
            state="present"
            present_args+=("./$rel")
        fi
        printf '%s\t%s\n' "$state" "$rel" >> "$stage/targets.tsv" || {
            rm -rf "$stage"
            return 1
        }
    done

    # One archive stream avoids spawning a separate cp process per target while
    # still materializing a directly inspectable mirror in files/.
    if [[ ${#present_args[@]} -gt 0 ]]; then
        if ! (
            set -o pipefail
            (cd "$canonical_root" && tar -cf - "${present_args[@]}") |
                (cd "$stage/files" && tar -xf -)
        ); then
            rm -rf "$stage"
            return 1
        fi
    fi

    : > "$stage/.complete"
    mv "$stage" "$final" || {
        rm -rf "$stage"
        return 1
    }
    if ! _backup_write_latest "$store" "$snapshot_id"; then
        rm -rf "$final"
        return 1
    fi

    echo "$final"
}

_backup_snapshot_path() {
    local supplied_root="$1"
    local requested="$2"
    local canonical_root store snapshot_id
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    store=$(_backup_validate_store "$canonical_root") || return 1

    snapshot_id=$(basename "$requested")
    if [[ -z "$snapshot_id" ]] || [[ "$snapshot_id" == "." ]] || [[ "$snapshot_id" == ".." ]]; then
        _backup_error "Invalid backup snapshot: $requested"
        return 1
    fi

    local snapshot="$store/$snapshot_id"
    if [[ -L "$snapshot" ]] || [[ ! -d "$snapshot" ]] || \
       [[ ! -f "$snapshot/.complete" ]] || [[ ! -f "$snapshot/targets.tsv" ]]; then
        _backup_error "Backup snapshot is missing or incomplete: $snapshot_id"
        return 1
    fi
    if [[ "$(cd -P "$snapshot" && pwd)" != "$store/$snapshot_id" ]]; then
        _backup_error "Backup snapshot resolves outside the backup store: $snapshot_id"
        return 1
    fi
    echo "$snapshot"
}

_backup_snapshot_source() {
    local snapshot="$1"
    local rel="$2"
    local files_root="$snapshot/files"
    if [[ -L "$files_root" ]] || [[ ! -d "$files_root" ]] || \
       [[ "$(cd -P "$files_root" && pwd)" != "$files_root" ]]; then
        _backup_error "Snapshot files directory is unsafe"
        return 1
    fi

    local source="$files_root/$rel"
    local probe
    probe=$(dirname "$source")
    while [[ ! -e "$probe" ]] && [[ ! -L "$probe" ]]; do
        local parent
        parent=$(dirname "$probe")
        [[ "$parent" != "$probe" ]] || break
        probe="$parent"
    done
    if [[ ! -d "$probe" ]]; then
        _backup_error "Snapshot source parent is not a directory: $rel"
        return 1
    fi

    local resolved
    resolved=$(cd -P "$probe" 2>/dev/null && pwd) || return 1
    if [[ "$resolved" != "$files_root" ]] && [[ "$resolved" != "$files_root/"* ]]; then
        _backup_error "Snapshot source resolves outside the backup store: $rel"
        return 1
    fi
    echo "$source"
}

# Load and validate a snapshot manifest. Results are placed in
# BACKUP_LOADED_STATES, BACKUP_LOADED_RELS, and BACKUP_LOADED_PATHS.
backup_load_targets() {
    local supplied_root="$1"
    local requested="$2"
    local canonical_root snapshot
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    snapshot=$(_backup_snapshot_path "$supplied_root" "$requested") || return 1

    BACKUP_LOADED_STATES=()
    BACKUP_LOADED_RELS=()
    BACKUP_LOADED_PATHS=()

    local state rel extra
    while IFS=$'\t' read -r state rel extra || [[ -n "$state$rel$extra" ]]; do
        [[ -n "$state$rel$extra" ]] || continue
        if [[ "$state" != "present" ]] && [[ "$state" != "missing" ]]; then
            _backup_error "Invalid target state in snapshot: $state"
            return 1
        fi
        if [[ -n "$extra" ]]; then
            _backup_error "Invalid target record in snapshot: $rel"
            return 1
        fi
        _backup_validate_rel "$rel" || return 1
        if [[ "$state" == "present" ]]; then
            local snapshot_source
            snapshot_source=$(_backup_snapshot_source "$snapshot" "$rel") || return 1
            if [[ ! -e "$snapshot_source" ]] && [[ ! -L "$snapshot_source" ]]; then
                _backup_error "Snapshot content is missing for target: $rel"
                return 1
            fi
        fi
        local target_path
        target_path=$(_backup_safe_target_path "$canonical_root" "$rel") || return 1
        BACKUP_LOADED_STATES+=("$state")
        BACKUP_LOADED_RELS+=("$rel")
        BACKUP_LOADED_PATHS+=("$target_path")
    done < "$snapshot/targets.tsv"

    if [[ ${#BACKUP_LOADED_PATHS[@]} -eq 0 ]]; then
        _backup_error "Backup snapshot contains no targets"
        return 1
    fi
}

# Restore a snapshot exactly: current targets are removed first, then targets
# recorded as present are copied back. Missing targets remain absent.
# Usage: backup_restore <project-root> <snapshot-path-or-id>
backup_restore() {
    local supplied_root="$1"
    local requested="$2"
    local canonical_root snapshot
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    snapshot=$(_backup_snapshot_path "$supplied_root" "$requested") || return 1
    backup_load_targets "$supplied_root" "$snapshot" || return 1

    local path index rel parent
    for ((index = 0; index < ${#BACKUP_LOADED_PATHS[@]}; index++)); do
        rel="${BACKUP_LOADED_RELS[$index]}"
        path=$(_backup_safe_target_path "$canonical_root" "$rel") || return 1
        rm -rf "$path" || return 1
    done

    for ((index = 0; index < ${#BACKUP_LOADED_PATHS[@]}; index++)); do
        [[ "${BACKUP_LOADED_STATES[$index]}" == "present" ]] || continue
        rel="${BACKUP_LOADED_RELS[$index]}"
        path=$(_backup_safe_target_path "$canonical_root" "$rel") || return 1
        parent=$(dirname "$path")
        mkdir -p "$parent" || return 1
        local snapshot_source
        snapshot_source=$(_backup_snapshot_source "$snapshot" "$rel") || return 1
        _backup_copy "$snapshot_source" "$path" || return 1
    done
}

# Print the latest complete snapshot path, or return 1 when none exists.
backup_latest() {
    local supplied_root="$1"
    local canonical_root store snapshot_id candidate latest=""
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    store=$(_backup_validate_store "$canonical_root") || return 1
    [[ -d "$store" ]] || return 1

    if [[ -f "$store/.latest" ]] && [[ ! -L "$store/.latest" ]]; then
        IFS= read -r snapshot_id < "$store/.latest" || true
        if [[ -n "$snapshot_id" ]] && [[ "$snapshot_id" == "$(basename "$snapshot_id")" ]] && \
           [[ -f "$store/$snapshot_id/.complete" ]]; then
            echo "$store/$snapshot_id"
            return 0
        fi
    fi

    for candidate in "$store"/*; do
        [[ ! -L "$candidate" ]] || continue
        [[ -d "$candidate" ]] || continue
        [[ -f "$candidate/.complete" ]] || continue
        if [[ -z "$latest" ]] || [[ "$(basename "$candidate")" > "$(basename "$latest")" ]]; then
            latest="$candidate"
        fi
    done
    [[ -n "$latest" ]] || return 1
    echo "$latest"
}

# Print one TSV record per complete snapshot:
#   <id><TAB><operation><TAB><created_at>
backup_list() {
    local supplied_root="$1"
    local canonical_root store candidate operation created
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    store=$(_backup_validate_store "$canonical_root") || return 1
    [[ -d "$store" ]] || return 0

    for candidate in "$store"/*; do
        [[ ! -L "$candidate" ]] || continue
        [[ -d "$candidate" ]] || continue
        [[ -f "$candidate/.complete" ]] || continue
        operation=$(sed -n 's/^operation=//p' "$candidate/metadata" | head -1)
        created=$(sed -n 's/^created_at=//p' "$candidate/metadata" | head -1)
        printf '%s\t%s\t%s\n' "$(basename "$candidate")" "$operation" "$created"
    done
}

# Keep a bounded history after a successful operation. A limit of 0 disables
# pruning. The latest snapshot is always retained.
backup_prune() {
    local supplied_root="$1"
    local limit="${2:-${AGENTSYNC_BACKUP_LIMIT:-10}}"
    if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        _backup_error "Backup limit must be a non-negative integer: $limit"
        return 1
    fi
    [[ "$limit" -gt 0 ]] || return 0

    local canonical_root store
    canonical_root=$(_backup_canonical_root "$supplied_root") || return 1
    store=$(_backup_validate_store "$canonical_root") || return 1
    [[ -d "$store" ]] || return 0

    local -a snapshots=()
    local candidate latest=""
    for candidate in "$store"/*; do
        [[ ! -L "$candidate" ]] || continue
        [[ -d "$candidate" ]] || continue
        [[ -f "$candidate/.complete" ]] || continue
        snapshots+=("$candidate")
    done
    [[ ${#snapshots[@]} -gt "$limit" ]] || return 0

    latest=$(backup_latest "$canonical_root") || true
    local remove_count
    remove_count=$((${#snapshots[@]} - limit))
    while IFS= read -r candidate; do
        [[ $remove_count -gt 0 ]] || break
        [[ "$candidate" == "$latest" ]] && continue
        rm -rf "$candidate" || return 1
        remove_count=$((remove_count - 1))
    done < <(printf '%s\n' "${snapshots[@]}" | LC_ALL=C sort)
}

_rollback_on_exit() {
    local status=$?
    trap - EXIT

    if [[ "$ROLLBACK_TRANSACTION_ACTIVE" == "true" ]] && [[ $status -ne 0 ]]; then
        echo "Warning: Rollback failed; restoring the state from before rollback..." >&2
        if backup_restore "$ROLLBACK_ROOT" "$ROLLBACK_SAFETY_PATH"; then
            echo "Restored pre-rollback state from ${ROLLBACK_SAFETY_PATH#"$ROLLBACK_ROOT"/}" >&2
        else
            echo "Error: Recovery failed. Safety backup retained at ${ROLLBACK_SAFETY_PATH#"$ROLLBACK_ROOT"/}" >&2
        fi
    fi

    exit "$status"
}

_rollback_usage() {
    cat << 'HELP'
Usage: agentsync rollback [<backup-id>] [OPTIONS]

Restore AgentSync-managed targets from a backup. Without an ID, restores the
latest complete snapshot. A safety snapshot is created before every restore,
so the rollback itself can be undone.

Options:
  --list       List complete backups
  --dry-run    Show the restore plan without changing files
  -y, --yes    Skip the confirmation prompt
  -h, --help   Show this help
HELP
}

cmd_rollback() {
    local backup_id=""
    local list_only=false
    local dry_run=false
    local assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_only=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --yes|-y)
                assume_yes=true
                shift
                ;;
            --help|-h)
                _rollback_usage
                return 0
                ;;
            -*)
                _backup_error "Unknown rollback option: $1"
                _rollback_usage >&2
                return 1
                ;;
            *)
                if [[ -n "$backup_id" ]]; then
                    _backup_error "Unexpected rollback argument: $1"
                    return 1
                fi
                backup_id="$1"
                shift
                ;;
        esac
    done

    local supplied_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    local root
    root=$(_backup_canonical_root "$supplied_root") || return 1

    if [[ "$list_only" == "true" ]]; then
        if [[ -n "$backup_id" ]]; then
            _backup_error "A backup ID cannot be combined with --list"
            return 1
        fi
        local rows
        rows=$(backup_list "$root") || return 1
        if [[ -z "$rows" ]]; then
            echo "No AgentSync backups found."
            return 0
        fi
        echo "Backup ID	Operation	Created (UTC)"
        printf '%s\n' "$rows"
        return 0
    fi

    local snapshot
    if [[ -n "$backup_id" ]]; then
        if [[ "$backup_id" != "$(basename "$backup_id")" ]]; then
            _backup_error "Invalid backup ID: $backup_id"
            return 1
        fi
        snapshot=$(_backup_snapshot_path "$root" "$backup_id") || return 1
    else
        snapshot=$(backup_latest "$root") || {
            _backup_error "No complete AgentSync backup found"
            return 1
        }
        backup_id=$(basename "$snapshot")
    fi

    backup_load_targets "$root" "$snapshot" || return 1

    echo "Rollback plan:"
    echo "  Backup: $backup_id"
    local index action
    for ((index = 0; index < ${#BACKUP_LOADED_RELS[@]}; index++)); do
        if [[ "${BACKUP_LOADED_STATES[$index]}" == "present" ]]; then
            action="restore"
        else
            action="remove"
        fi
        printf '  %-7s %s\n' "$action" "${BACKUP_LOADED_RELS[$index]}"
    done

    if [[ "$dry_run" == "true" ]]; then
        echo "Dry run — nothing was written."
        return 0
    fi

    if [[ "$assume_yes" != "true" ]] && \
       ! prompt_confirm "Restore backup $backup_id?" "n"; then
        echo "Cancelled."
        return 130
    fi

    local -a current_targets=("${BACKUP_LOADED_PATHS[@]}")
    local safety
    safety=$(backup_create \
        "$root" \
        "rollback" \
        "${current_targets[@]+"${current_targets[@]}"}") || {
        _backup_error "Could not create a pre-rollback safety backup; no files were changed"
        return 1
    }

    ROLLBACK_ROOT="$root"
    ROLLBACK_SAFETY_PATH="$safety"
    ROLLBACK_TRANSACTION_ACTIVE="true"
    trap _rollback_on_exit EXIT

    backup_restore "$root" "$snapshot"

    ROLLBACK_TRANSACTION_ACTIVE="false"
    trap - EXIT
    if ! backup_prune "$root"; then
        echo "Warning: Could not prune old AgentSync backups." >&2
    fi

    echo "Restored backup $backup_id."
    echo "Undo backup: $(basename "$safety")"
}
