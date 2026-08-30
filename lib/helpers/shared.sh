#!/usr/bin/env bash
# Shared source overlay — implements `shared:` inheritance in agent_sync.yaml.
#
#   shared:
#     path: "../"
#     inherit: rules,skills,commands,agents
#
# Effect: at sync time, a shadow `.ai/src/` tree is built combining the
# child's own source with parent files in inherited categories (child wins
# on path conflicts). Sync then reads from the shadow tree, so every
# enabled tool — including ones that don't auto-load parent rules
# (Codex, Cursor, etc.) — receives the inherited content materialised
# into its own output.
#
# Manifest interaction: the shadow tree is transient. `.template-manifest`
# tracks only the child's actual .ai/src/ files (unchanged behavior).
# `.sync-manifest` tracks generated outputs as before — inherited content
# is part of those outputs but its origin is the parent's source, not
# the child's. This keeps the state model single-headed: one manifest
# per concern, no "inherited" flag, no second source of truth.

# Globals owned by this module
SHARED_OVERLAY_DIR=""        # absolute path to the tmpdir, "" when not active
SHARED_OVERLAY_DIR_CANONICAL="" # canonicalised SHARED_OVERLAY_DIR, used by paths.sh allowlist
# shellcheck disable=SC2034  # used by tests and external introspection
SHARED_OVERLAY_PARENT=""     # parent .ai/src/ that the overlay was built from
SHARED_OVERLAY_INHERIT=""    # CSV of categories that were inherited

# Per-profile overlay globals — mirror the shared ones but kept distinct so a
# profile pass can compose on top of an active `shared:` overlay (see profiles.sh).
PROFILE_OVERLAY_DIR=""
PROFILE_OVERLAY_DIR_CANONICAL=""

# Remove an overlay tree only when this run created it. Provenance, not path
# shape: an allowlist of /tmp-like prefixes refuses to clean up under any custom
# TMPDIR (TMPDIR=$RUNNER_TEMP on CI), leaking a full .ai/src copy per sync.
# Compares raw against raw — SHARED_OVERLAY_DIR is deliberately left
# un-canonicalised (macOS /tmp is a symlink to /private/tmp), so mixing the
# canonical form in here would make every prefix test fail.
#
# Usage: _overlay_remove_if_ours <label> <dir>
_overlay_remove_if_ours() {
    local label="$1"
    local dir="$2"
    case "$dir" in
        "${AGENTSYNC_RUN_TMPDIR:-/nonexistent}"/*) rm -rf "$dir" ;;
        *) log_warning "$label overlay was not created by this run, NOT removing: $dir" ;;
    esac
}

# Build a shadow `src/` tree under a fresh tmpdir: mirror child_src (which wins
# on conflict), then fill in parent_src files for the given categories where the
# child has no same-path file. Pure aside from creating the tmpdir — echoes its
# absolute path; the caller owns the lifecycle globals and teardown.
#
# Usage: build_overlay_tree <child_src> <parent_src> <categories_csv>
build_overlay_tree() {
    local child_src="$1"
    local parent_src="$2"
    local categories_csv="$3"

    local -a cats=()
    local raw="${categories_csv//,/ }" tok
    for tok in $raw; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ -z "$tok" ]] && continue
        [[ "$tok" == "subagents" ]] && tok="agents"
        cats+=("$tok")
    done

    local tmpdir
    tmpdir=$(tmp_dir agentsync_shared) || return 1
    mkdir -p "$tmpdir/src"

    # Mirror child source. Only copy dirs that exist; `cp -R` preserves deep
    # skill trees.
    if [[ -d "$child_src" ]]; then
        [[ -f "$child_src/AGENTS.md" ]] && cp "$child_src/AGENTS.md" "$tmpdir/src/AGENTS.md"
        local item
        for item in rules skills commands agents; do
            [[ -d "$child_src/$item" ]] || continue
            cp -R "$child_src/$item" "$tmpdir/src/$item"
        done
    fi

    # Fill in parent files for inherited categories — skip any path the child
    # already provides (child wins).
    local cat pdir f rel target
    for cat in "${cats[@]}"; do
        pdir="$parent_src/$cat"
        [[ -d "$pdir" ]] || continue
        while IFS= read -r -d '' f; do
            rel="${f#"$pdir/"}"
            target="$tmpdir/src/$cat/$rel"
            [[ -e "$target" ]] && continue
            mkdir -p "$(dirname "$target")"
            cp "$f" "$target"
        done < <(find "$pdir" -type f -print0 2>/dev/null)
    done

    echo "$tmpdir"
}

# Point the caller's SOURCE_* at an overlay tmpdir's `src/`, but only for the
# categories the overlay actually materialised. Mutates caller-scope globals.
# Usage: _overlay_rewrite_sources <tmpdir>
_overlay_rewrite_sources() {
    local tmpdir="$1"
    # A missing final agents/ path previously became the function's status and
    # triggered set -e in the unguarded caller.
    if [[ -f "$tmpdir/src/AGENTS.md" ]]; then
        # shellcheck disable=SC2034
        SOURCE_AGENTS="$tmpdir/src/AGENTS.md"
    fi
    if [[ -d "$tmpdir/src/rules" ]]; then
        # shellcheck disable=SC2034
        SOURCE_RULES="$tmpdir/src/rules"
    fi
    if [[ -d "$tmpdir/src/skills" ]]; then
        # shellcheck disable=SC2034
        SOURCE_SKILLS="$tmpdir/src/skills"
    fi
    if [[ -d "$tmpdir/src/commands" ]]; then
        # shellcheck disable=SC2034
        SOURCE_COMMANDS="$tmpdir/src/commands"
    fi
    if [[ -d "$tmpdir/src/agents" ]]; then
        # shellcheck disable=SC2034
        SOURCE_SUBAGENTS="$tmpdir/src/agents"
    fi
}

# Read `shared.path` and `shared.inherit` from the project config and
# build a shadow `.ai/src/` tree under a temp dir. Updates SOURCE_*
# variables in the caller's scope to point into the shadow tree.
#
# When no `shared:` section exists, or the parent path can't be resolved,
# this is a no-op (SHARED_OVERLAY_DIR stays empty).
#
# Trap-based cleanup is the caller's responsibility — see shared_cleanup.
#
# Usage: shared_setup_overlay
shared_setup_overlay() {
    SHARED_OVERLAY_DIR=""
    SHARED_OVERLAY_PARENT=""
    SHARED_OVERLAY_INHERIT=""

    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || return 0
    [[ -f "$PROJECT_CONFIG_PATH" ]] || return 0

    local raw_path raw_inherit
    raw_path=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "shared.path")
    raw_inherit=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "shared.inherit")

    [[ -z "$raw_path" ]] && return 0
    [[ -z "$raw_inherit" ]] && return 0

    # Resolve parent root (absolute), then locate its .ai/src/.
    local parent_root
    if [[ "$raw_path" == /* ]]; then
        parent_root="$raw_path"
    else
        parent_root="$REPO_ROOT/$raw_path"
    fi
    if [[ ! -d "$parent_root" ]]; then
        log_warning "shared.path does not exist: $raw_path — overlay skipped"
        return 0
    fi
    parent_root=$(cd "$parent_root" && pwd)

    local parent_src=""
    if [[ -d "$parent_root/.ai/src" ]]; then
        parent_src="$parent_root/.ai/src"
    elif [[ "$(basename "$parent_root")" == "src" ]] && [[ -d "$parent_root" ]]; then
        parent_src="$parent_root"
    fi
    if [[ -z "$parent_src" ]]; then
        log_warning "shared.path has no .ai/src/: $raw_path — overlay skipped"
        return 0
    fi
    # Guard against the parent being us (same path) — would shadow the child
    # over itself and loop conceptually. Cheap check.
    if [[ "$parent_src" == "$REPO_ROOT/.ai/src" ]]; then
        log_warning "shared.path resolves to this project — overlay skipped"
        return 0
    fi

    # Parse inherit CSV. Strip whitespace; ignore empty tokens.
    local -a inherit_cats=()
    local raw="${raw_inherit//,/ }"
    local tok
    for tok in $raw; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ -z "$tok" ]] && continue
        # `subagents` token maps to the `agents/` directory on disk.
        [[ "$tok" == "subagents" ]] && tok="agents"
        case "$tok" in
            rules|skills|commands|agents) inherit_cats+=("$tok") ;;
            *) log_warning "shared.inherit: unknown category '$tok' — skipped" ;;
        esac
    done
    if [[ ${#inherit_cats[@]} -eq 0 ]]; then
        return 0
    fi

    # Build shadow tree (child .ai/src/ wins; parent fills inherited categories),
    # then point SOURCE_* into it.
    SHARED_OVERLAY_INHERIT=$(printf '%s,' "${inherit_cats[@]}")
    SHARED_OVERLAY_INHERIT="${SHARED_OVERLAY_INHERIT%,}"
    # shellcheck disable=SC2034
    SHARED_OVERLAY_PARENT="$parent_src"

    local tmpdir
    tmpdir=$(build_overlay_tree "$REPO_ROOT/.ai/src" "$parent_src" "$SHARED_OVERLAY_INHERIT")
    SHARED_OVERLAY_DIR="$tmpdir"
    SHARED_OVERLAY_DIR_CANONICAL=$(cd -P "$tmpdir" && pwd)
    export SHARED_OVERLAY_DIR_CANONICAL

    _overlay_rewrite_sources "$tmpdir"

    log_info "Shared overlay active: $parent_src ($SHARED_OVERLAY_INHERIT)"
}

# Remove the shadow tree if it was built. Safe to call when overlay is
# inactive (no-op). Invoked from sync.sh's EXIT trap.
shared_cleanup_overlay() {
    [[ -n "$SHARED_OVERLAY_DIR" ]] || return 0
    [[ -d "$SHARED_OVERLAY_DIR" ]] || return 0
    _overlay_remove_if_ours "shared" "$SHARED_OVERLAY_DIR"
    SHARED_OVERLAY_DIR=""
    SHARED_OVERLAY_DIR_CANONICAL=""
    unset SHARED_OVERLAY_DIR_CANONICAL
}

# Build a per-profile overlay: profile extras (.ai/profiles/<name>/src) win,
# base_src fills the rest (rules,skills,commands,agents). Rewrites the caller's
# SOURCE_* to point into the overlay and arms PROFILE_OVERLAY_DIR* for the
# paths.sh source allowlist. Returns 1 (no SOURCE_* change) when the profile
# declares no extras, so the personal base flows through unchanged.
#
# Usage: profile_setup_overlay <name> <base_src>
profile_setup_overlay() {
    local name="$1"
    local base_src="$2"

    local overlay_rel overlay_root profile_src
    overlay_rel=$(profile_overlay_dir "$name")
    overlay_root="$overlay_rel"
    [[ "$overlay_root" != /* ]] && overlay_root="$REPO_ROOT/$overlay_root"
    profile_src="$overlay_root/src"

    if [[ ! -d "$profile_src" ]]; then
        return 1
    fi

    local tmpdir
    tmpdir=$(build_overlay_tree "$profile_src" "$base_src" "rules,skills,commands,agents")
    PROFILE_OVERLAY_DIR="$tmpdir"
    PROFILE_OVERLAY_DIR_CANONICAL=$(cd -P "$tmpdir" && pwd)
    export PROFILE_OVERLAY_DIR_CANONICAL

    _overlay_rewrite_sources "$tmpdir"

    log_info "Profile overlay active: $name ($profile_src)"
    return 0
}

# Remove the per-profile overlay tmpdir. Safe to call when inactive (no-op).
profile_cleanup_overlay() {
    [[ -n "$PROFILE_OVERLAY_DIR" ]] || return 0
    [[ -d "$PROFILE_OVERLAY_DIR" ]] || { PROFILE_OVERLAY_DIR=""; return 0; }
    _overlay_remove_if_ours "profile" "$PROFILE_OVERLAY_DIR"
    PROFILE_OVERLAY_DIR=""
    PROFILE_OVERLAY_DIR_CANONICAL=""
    unset PROFILE_OVERLAY_DIR_CANONICAL
}

# Resolve `shared.path` from the project config to the parent's absolute
# `.ai/src/` directory. Read-only — does not build the overlay, just locates
# the declared parent.
#
# Returns 1 (and echoes nothing) when: no config path, no shared.path, parent
# path missing, parent has no .ai/src/, or parent resolves to this project.
#
# Used by `doctor` and `dedupe` so an explicit `shared.path` overrides the
# git-bounded walk-up. The two parent-resolution paths are intentionally
# asymmetric: walk-up is bounded by the git boundary because it's
# auto-detection; `shared.path` is an explicit user declaration and must work
# the same way overlay does at sync time — across repo boundaries.
#
# Both args optional; default to PROJECT_CONFIG_PATH / REPO_ROOT globals
# (doctor's call site). `dedupe --workspace` fans out across projects and
# passes explicit args to avoid mutating globals per iteration.
#
# Usage: shared_parent_src [config_path] [repo_root]  → absolute path | rc 1
shared_parent_src() {
    local config_path="${1:-${PROJECT_CONFIG_PATH:-}}"
    local repo_root="${2:-${REPO_ROOT:-$(pwd)}}"

    [[ -n "$config_path" ]] || return 1
    [[ -f "$config_path" ]] || return 1

    local raw_path
    raw_path=$(parse_yaml_value "$config_path" "shared.path")
    [[ -z "$raw_path" ]] && return 1

    local parent_root
    if [[ "$raw_path" == /* ]]; then
        parent_root="$raw_path"
    else
        parent_root="$repo_root/$raw_path"
    fi
    [[ -d "$parent_root" ]] || return 1
    parent_root=$(cd "$parent_root" && pwd)

    local parent_src=""
    if [[ -d "$parent_root/.ai/src" ]]; then
        parent_src="$parent_root/.ai/src"
    elif [[ "$(basename "$parent_root")" == "src" ]]; then
        parent_src="$parent_root"
    fi
    [[ -n "$parent_src" ]] || return 1

    # Reject self-reference — sync also rejects this; matching it here keeps
    # callers from comparing a tree to itself.
    [[ "$parent_src" == "$repo_root/.ai/src" ]] && return 1

    echo "$parent_src"
}

# Is the given category being inherited via `shared:` in this project?
# Reads PROJECT_CONFIG_PATH directly (does NOT require shared_setup_overlay
# to have run), so it's safe to call from doctor/dedupe which don't go
# through sync's setup flow.
#
# Usage: shared_inherits_category "rules"  → exit 0 if inherited, 1 otherwise
shared_inherits_category() {
    local want="$1"
    [[ -n "${PROJECT_CONFIG_PATH:-}" ]] || return 1
    [[ -f "$PROJECT_CONFIG_PATH" ]] || return 1

    local raw
    raw=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "shared.inherit")
    [[ -z "$raw" ]] && return 1

    local tok
    for tok in ${raw//,/ }; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ "$tok" == "subagents" ]] && tok="agents"
        [[ "$tok" == "$want" ]] && return 0
    done
    return 1
}
