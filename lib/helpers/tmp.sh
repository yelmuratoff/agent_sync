#!/usr/bin/env bash
# Per-run temp lifecycle.
#
# An entry point primes one directory per run and arms a trap that calls
# tmp_cleanup; everything scratch goes inside it, so a single rm -rf reclaims the
# run no matter which subshell created what. That matters because most helpers
# run inside $(...) command substitution, where appends to a parent array are
# discarded — a directory, and the strays file inside it, survive where an array
# cannot.
#
# Atomic-write staging files are the exception: `mv` onto the destination must be
# a same-filesystem rename, so they stay beside their destination and are tracked
# through tmp_sibling instead.

AGENTSYNC_RUN_TMPDIR="${AGENTSYNC_RUN_TMPDIR:-}"
AGENTSYNC_RUN_TMPDIR_OWNER="${AGENTSYNC_RUN_TMPDIR_OWNER:-}"

_tmp_error() {
    echo "Error: $1" >&2
}

# A child process (check.sh spawns sync.sh; cmd_engine spawns both) inherits the
# parent's run dir and must reuse it rather than open a second one. Adopt only a
# real directory this user owns: -O and -L are Bash builtins, so this stays free
# of `stat` on Bash 3.2 and Git Bash.
_tmp_can_adopt_run_dir() {
    local dir="${AGENTSYNC_RUN_TMPDIR:-}"
    [[ -n "$dir" ]] || return 1
    [[ -n "${AGENTSYNC_RUN_TMPDIR_OWNER:-}" ]] || return 1
    [[ -d "$dir" ]] || return 1
    [[ ! -L "$dir" ]] || return 1
    [[ -O "$dir" ]] || return 1
}

# Bash discards a subshell's exports, so this must run before any $(...) that
# reaches tmp_run_dir, or each subshell opens its own directory.
tmp_prime_run_dir() {
    _tmp_can_adopt_run_dir && return 0

    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    AGENTSYNC_RUN_TMPDIR="$(mktemp -d "$base/agentsync.$$.XXXXXX")" || {
        _tmp_error "Could not create a temporary run directory under $base"
        return 1
    }
    AGENTSYNC_RUN_TMPDIR_OWNER="$$"
    export AGENTSYNC_RUN_TMPDIR AGENTSYNC_RUN_TMPDIR_OWNER
}

tmp_run_dir() {
    if [[ -z "${AGENTSYNC_RUN_TMPDIR:-}" ]] || [[ ! -d "$AGENTSYNC_RUN_TMPDIR" ]]; then
        _tmp_error "Temp run directory is not primed; call tmp_prime_run_dir from the entry point"
        return 1
    fi
    printf '%s\n' "$AGENTSYNC_RUN_TMPDIR"
}

_tmp_validate_label() {
    local label="$1"
    if [[ -z "$label" ]] || [[ "$label" == */* ]] || [[ "$label" == .* ]]; then
        _tmp_error "Invalid temp label: ${label:-<empty>}"
        return 1
    fi
}

# Print the path of a scratch file inside the run directory.
# Usage: tmp_file <label>
tmp_file() {
    local label="${1:-scratch}"
    _tmp_validate_label "$label" || return 1
    local run_dir
    run_dir="$(tmp_run_dir)" || return 1
    mktemp "$run_dir/${label}.XXXXXX"
}

# Print the path of a scratch directory inside the run directory.
# Usage: tmp_dir <label>
tmp_dir() {
    local label="${1:-scratch}"
    _tmp_validate_label "$label" || return 1
    local run_dir
    run_dir="$(tmp_run_dir)" || return 1
    mktemp -d "$run_dir/${label}.XXXXXX"
}

_tmp_record_stray() {
    local path="$1"
    [[ -n "$path" ]] || return 0
    [[ "$path" == /* ]] || path="$PWD/$path"

    local run_dir="${AGENTSYNC_RUN_TMPDIR:-}"
    [[ -n "$run_dir" ]] && [[ -d "$run_dir" ]] || return 0
    printf '%s\n' "$path" >> "$run_dir/strays" 2>/dev/null || true
}

# Print the path of an atomic-write staging file beside <dest>, registered for
# cleanup. Use this wherever the file is finished with `mv` onto <dest>: the
# rename has to stay on one filesystem, so these cannot live under $TMPDIR.
# Usage: tmp_sibling <dest>
tmp_sibling() {
    local dest="$1"
    if [[ -z "$dest" ]] || [[ "$dest" == */ ]]; then
        _tmp_error "tmp_sibling requires a destination file path: ${dest:-<empty>}"
        return 1
    fi

    local tmp
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    # Renaming over a file replaces its inode, and with it its mode, so an
    # existing destination would drop from 0644 to mktemp's 0600 on every
    # rewrite. `cp -p` then truncate carries the mode across without `stat`,
    # whose flags differ between GNU and BSD. A destination its owner cannot
    # write (0444) would yield staging nobody can write either, so fall back to
    # mktemp's mode there rather than handing back an unusable file.
    if [[ -f "$dest" ]] && cp -p "$dest" "$tmp" 2>/dev/null; then
        if ! { : > "$tmp"; } 2>/dev/null; then
            rm -f "$tmp"
            tmp="$(mktemp "${dest}.XXXXXX")" || return 1
        fi
    fi
    _tmp_record_stray "$tmp"
    printf '%s\n' "$tmp"
}

# A child that inherited the directory must not delete it while the parent is
# still using it, so only the owning process reclaims.
tmp_cleanup() {
    local run_dir="${AGENTSYNC_RUN_TMPDIR:-}"
    [[ -n "$run_dir" ]] || return 0
    [[ "${AGENTSYNC_RUN_TMPDIR_OWNER:-}" == "$$" ]] || return 0
    # Provenance, as in shared.sh: refuse a name this helper did not create, so
    # an inherited or hand-set value cannot turn cleanup into rm -rf on a real
    # directory.
    case "${run_dir##*/}" in
        agentsync.*) ;;
        *) return 0 ;;
    esac

    local stray
    if [[ -f "$run_dir/strays" ]]; then
        while IFS= read -r stray || [[ -n "$stray" ]]; do
            [[ -n "$stray" ]] || continue
            [[ "$stray" == /* ]] || continue
            [[ "$stray" != "/" ]] || continue
            case "$stray" in */../*|*/..) continue ;; esac
            rm -rf "$stray" 2>/dev/null || true
        done < "$run_dir/strays"
    fi

    rm -rf "$run_dir" 2>/dev/null || true
    AGENTSYNC_RUN_TMPDIR=""
    AGENTSYNC_RUN_TMPDIR_OWNER=""
    export AGENTSYNC_RUN_TMPDIR AGENTSYNC_RUN_TMPDIR_OWNER
}
