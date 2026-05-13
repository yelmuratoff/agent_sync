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

    # Build shadow tree: mirror child .ai/src/ via cp -R, then fill in
    # parent files for inherited categories where child has no same-path
    # file. We never overwrite child's own files — child wins on collision.
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agentsync_shared.XXXXXX")
    SHARED_OVERLAY_DIR="$tmpdir"
    SHARED_OVERLAY_DIR_CANONICAL=$(cd -P "$tmpdir" && pwd)
    export SHARED_OVERLAY_DIR_CANONICAL
    # shellcheck disable=SC2034
    SHARED_OVERLAY_PARENT="$parent_src"
    SHARED_OVERLAY_INHERIT=$(printf '%s,' "${inherit_cats[@]}")
    SHARED_OVERLAY_INHERIT="${SHARED_OVERLAY_INHERIT%,}"

    # Mirror child source. The child may have any subset of dirs — only
    # copy what exists. Use `cp -R` so deep skill trees are preserved.
    mkdir -p "$tmpdir/src"
    local child_src="$REPO_ROOT/.ai/src"
    if [[ -d "$child_src" ]]; then
        if [[ -f "$child_src/AGENTS.md" ]]; then
            cp "$child_src/AGENTS.md" "$tmpdir/src/AGENTS.md"
        fi
        local item
        for item in rules skills commands agents; do
            [[ -d "$child_src/$item" ]] || continue
            cp -R "$child_src/$item" "$tmpdir/src/$item"
        done
    fi

    # Fill in parent files for inherited categories. Skip any path that
    # already exists in the shadow (child wins). Skill directories use
    # nested paths; flat dirs use one level.
    local cat pdir f rel target
    for cat in "${inherit_cats[@]}"; do
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

    # Rewrite SOURCE_* to point into the overlay. Each variable below is
    # already declared in the caller's scope (sync.sh main). Shellcheck
    # cannot see the cross-file usage, so the disables are explicit.
    # shellcheck disable=SC2034
    if [[ -f "$tmpdir/src/AGENTS.md" ]]; then
        SOURCE_AGENTS="$tmpdir/src/AGENTS.md"
    fi
    # shellcheck disable=SC2034
    [[ -d "$tmpdir/src/rules" ]]    && SOURCE_RULES="$tmpdir/src/rules"
    # shellcheck disable=SC2034
    [[ -d "$tmpdir/src/skills" ]]   && SOURCE_SKILLS="$tmpdir/src/skills"
    # shellcheck disable=SC2034
    [[ -d "$tmpdir/src/commands" ]] && SOURCE_COMMANDS="$tmpdir/src/commands"
    # shellcheck disable=SC2034
    [[ -d "$tmpdir/src/agents" ]]   && SOURCE_SUBAGENTS="$tmpdir/src/agents"

    log_info "Shared overlay active: $parent_src ($SHARED_OVERLAY_INHERIT)"
}

# Remove the shadow tree if it was built. Safe to call when overlay is
# inactive (no-op). Invoked from sync.sh's EXIT trap.
shared_cleanup_overlay() {
    [[ -n "$SHARED_OVERLAY_DIR" ]] || return 0
    [[ -d "$SHARED_OVERLAY_DIR" ]] || return 0
    # Cheap sanity guard: never rm -rf a path outside the OS temp area.
    case "$SHARED_OVERLAY_DIR" in
        /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$SHARED_OVERLAY_DIR" ;;
        *) log_warning "shared overlay path looks suspicious, NOT removing: $SHARED_OVERLAY_DIR" ;;
    esac
    SHARED_OVERLAY_DIR=""
    SHARED_OVERLAY_DIR_CANONICAL=""
    unset SHARED_OVERLAY_DIR_CANONICAL
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
