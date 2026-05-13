#!/usr/bin/env bash
# agentsync refresh — pull updated rule/skill/command/subagent templates
# into an existing .ai/src/, with three-way diff (template_old vs template_new
# vs user_current) so files the user hasn't touched auto-update silently and
# only true conflicts require interactive review.
#
# Scope: source content only (rules, skills, commands, agents). AGENTS.md is
# off by default (almost always heavily customized). Tool configs (settings,
# mcp, hooks, tools) are intentionally excluded — they have their own
# customize/simplify/resolve flow.
#
# Three-way decision logic (per template file):
#   * declined override (agent_sync.yaml)        → ignore entirely (silent)
#   * pinned override (agent_sync.yaml)          → ignore template changes (silent)
#   * file missing locally + not in manifest     → NEW       (offer to add)
#   * file missing locally + in manifest         → DELETED   (silent unless --include-deleted)
#   * file matches current template              → UNCHANGED (silent; manifest healed)
#   * user untouched (current == manifest_old)
#     and template moved (new != manifest_old)   → AUTO_UPDATE (silent apply)
#   * template static (new == manifest_old)
#     but user edited locally                    → silent (their custom version;
#                                                  --review surfaces it)
#   * both diverged from manifest_old            → CONFLICT (diff + prompt)
#   * no manifest entry at all + user differs    → CONFLICT (no baseline → manual)
#
# When the user picks `[s]kip` on a CONFLICT, we record manifest_new for that
# path. On the next refresh the file lands in the "template static" branch and
# stays silent until a newer template ships, at which point it surfaces as a
# fresh CONFLICT. `agentsync refresh --review` forces every silent divergence
# to surface so the user can revisit earlier skip decisions.
#
# When the manifest is missing (project predates v2 of refresh), the logic
# degrades to two-way diff and every divergence is treated as a CONFLICT.

# ── Static configuration ─────────────────────────────────────────────────────

_REFRESH_CATEGORIES_VALID="rules skills commands agents subagents"
_REFRESH_CATEGORIES_DEFAULT="rules skills commands agents"

# ── Globals populated by _refresh_collect_changes ───────────────────────────
# Each entry is one of:
#   "<rel-path>|<absolute-template-path>|<template-hash>"   for NEW/CONFLICT/AUTO_UPDATE/DELETED
#   "<rel-path>"                                             for UNCHANGED
NEW_FILES=()
CONFLICT_FILES=()
AUTO_UPDATE_FILES=()
DELETED_FILES=()
UNCHANGED_FILES=()

# Count of files where the user's content differs from the current template
# but the manifest already records the current template hash — typically a
# prior `[s]kip` on a conflict, occasionally a local edit since the last
# refresh. Used to surface a discoverable hint about --review on no-op runs.
SILENTLY_KEPT_COUNT=0

# When true, _refresh_classify treats SILENTLY_KEPT entries as CONFLICTs so
# the user can revisit them. Set from --review.
REFRESH_REVIEW_MODE=false

# Loaded from agent_sync.yaml: template_overrides.{declined,pinned}
DECLINED_OVERRIDES=()
PINNED_OVERRIDES=()

cmd_refresh() {
    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    local dry_run=false
    local assume_yes=false
    local include_agents_md=false
    local include_deleted=false
    local review=false
    local status_only=false
    local only_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)            dry_run=true; shift ;;
            --yes|-y)             assume_yes=true; shift ;;
            --include-agents-md)  include_agents_md=true; shift ;;
            --include-deleted)    include_deleted=true; shift ;;
            --review)             review=true; shift ;;
            --status)             status_only=true; shift ;;
            --only)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --only requires a value" >&2; return 1; }
                only_flag="$2"; shift 2 ;;
            --only=*)             only_flag="${1#--only=}"; shift ;;
            --help|-h)            _refresh_usage; return 0 ;;
            -*)
                echo "$(_red "Error"): Unknown option: $1" >&2
                _refresh_usage >&2
                return 1
                ;;
            *)
                echo "$(_red "Error"): Unexpected argument: $1" >&2
                _refresh_usage >&2
                return 1
                ;;
        esac
    done

    _resolve_source_paths "$repo_root"
    if [[ -z "$_SRC_BASE" ]]; then
        echo "$(_red "Error"): No .ai/ directory found in $repo_root" >&2
        echo "Run $(_cyan "agentsync init") first." >&2
        return 1
    fi

    local templates_dir
    templates_dir=$(_refresh_find_templates) || {
        echo "$(_red "Error"): Cannot locate AgentSync templates directory." >&2
        echo "Reinstall AgentSync or set $(_cyan "AGENTSYNC_HOME")." >&2
        return 1
    }

    local categories
    categories=$(_refresh_resolve_scope "$only_flag" "$repo_root/$_SRC_BASE") || return 1

    # Persist any AGENTSYNC_REPO_ROOT we infer so manifest helpers see the same root.
    AGENTSYNC_REPO_ROOT="$repo_root"
    export AGENTSYNC_REPO_ROOT

    template_manifest_load
    local has_manifest=false
    [[ ${#TEMPLATE_MANIFEST_KEYS[@]} -gt 0 ]] && has_manifest=true

    _refresh_load_overrides "$repo_root"

    NEW_FILES=()
    CONFLICT_FILES=()
    AUTO_UPDATE_FILES=()
    DELETED_FILES=()
    UNCHANGED_FILES=()
    SILENTLY_KEPT_COUNT=0
    REFRESH_REVIEW_MODE="$review"
    _refresh_collect_changes "$templates_dir" "$repo_root" "$categories" "$include_agents_md"

    # --status: print declined breakdown and return, no mutation.
    if [[ "$status_only" == "true" ]]; then
        _refresh_print_status "$repo_root"
        return 0
    fi

    local new_count=${#NEW_FILES[@]}
    local conflict_count=${#CONFLICT_FILES[@]}
    local auto_count=${#AUTO_UPDATE_FILES[@]}
    local deleted_count=${#DELETED_FILES[@]}
    local unchanged_count=${#UNCHANGED_FILES[@]}

    echo ""
    _bold "  AgentSync Refresh"; echo ""
    echo ""
    echo "  $(_dim "Templates:") $templates_dir"
    echo "  $(_dim "Project:")   $repo_root/$_SRC_BASE"
    local scope_label
    scope_label=$(echo "$categories" | tr ' ' ',')
    [[ "$include_agents_md" == "true" ]] && scope_label="$scope_label,AGENTS.md"
    echo "  $(_dim "Scope:")     $scope_label"
    if [[ "$has_manifest" == "false" ]]; then
        echo "  $(_dim "Manifest:")  $(_yellow "none — falling back to two-way diff")"
    fi
    echo ""

    local has_visible_deleted=false
    if [[ "$include_deleted" == "true" ]] && (( deleted_count > 0 )); then
        has_visible_deleted=true
    fi

    if (( new_count == 0 && conflict_count == 0 && auto_count == 0 )) && [[ "$has_visible_deleted" != "true" ]]; then
        echo "  $(_green "Already up to date!") $unchanged_count file(s) match the current templates."
        local persistent_count=${#DECLINED_OVERRIDES[@]}
        if (( persistent_count > 0 )); then
            echo "  $(_dim "Persistently declined (agent_sync.yaml): $persistent_count file(s).")"
        fi
        if (( deleted_count > 0 )); then
            echo "  $(_dim "Locally declined (.template-manifest):    $deleted_count file(s); --include-deleted to revisit.")"
        fi
        if (( persistent_count > 0 )) || (( deleted_count > 0 )); then
            echo "  $(_dim "Pass --status for the full list.")"
        fi
        if (( SILENTLY_KEPT_COUNT > 0 )) && [[ "$review" != "true" ]]; then
            echo "  $(_dim "$SILENTLY_KEPT_COUNT file(s) differ from the shipped template (local edits or earlier skips); pass --review to revisit.")"
        fi
        # Heal manifest with current matches even if no other change is needed.
        _refresh_heal_unchanged "$templates_dir" "$repo_root/$_SRC_BASE"
        if [[ "$dry_run" != "true" ]]; then
            template_manifest_write
        fi
        echo ""
        return 0
    fi

    echo "  $(_green "Summary:")"
    (( new_count > 0 ))      && echo "    $(_green "+") $new_count new template(s)"
    (( auto_count > 0 ))     && echo "    $(_cyan "↑") $auto_count auto-update(s) — you hadn't touched them locally"
    (( conflict_count > 0 )) && echo "    $(_yellow "~") $conflict_count conflict(s) — your version differs from the template"
    [[ "$has_visible_deleted" == "true" ]] && \
        echo "    $(_dim "?") $deleted_count previously declined — pass --include-deleted to revisit"
    if (( SILENTLY_KEPT_COUNT > 0 )) && [[ "$review" != "true" ]]; then
        echo "    $(_dim "·") $SILENTLY_KEPT_COUNT silently kept (local edits or earlier skips) — pass --review to revisit"
    fi
    (( unchanged_count > 0 )) && echo "    $(_dim "·") $unchanged_count unchanged"
    echo ""

    _refresh_list_proposed "$has_visible_deleted"

    if [[ "$dry_run" == "true" ]]; then
        echo "  $(_yellow "Dry run") — no files written."
        echo ""
        return 0
    fi

    if ! is_tty && [[ "$assume_yes" != "true" ]] && (( new_count + conflict_count > 0 )); then
        echo "  $(_red "Error"): Cannot run interactively (not a TTY)." >&2
        echo "  Use $(_cyan "--yes") to add new files and apply auto-updates" >&2
        echo "  (conflicts are always skipped non-interactively)." >&2
        echo "  Use $(_cyan "--dry-run") to preview." >&2
        return 1
    fi

    local added=0 updated=0 auto_applied=0 skipped=0 cancelled=false

    # Auto-updates always apply silently — by definition the user hadn't touched them.
    if (( auto_count > 0 )); then
        local entry rel src t_new dest
        for entry in "${AUTO_UPDATE_FILES[@]}"; do
            rel="${entry%%|*}"
            local rest="${entry#*|}"
            src="${rest%|*}"
            t_new="${rest##*|}"
            dest="$repo_root/$_SRC_BASE/$rel"
            _refresh_copy "$src" "$dest"
            template_manifest_record "$rel" "$t_new"
            echo "  $(_cyan "↑") $rel  $(_dim "(auto-updated; you hadn't touched it)")"
            auto_applied=$((auto_applied + 1))
        done
    fi

    if [[ "$has_visible_deleted" == "true" ]]; then
        local entry rel src t_new dest
        for entry in "${DELETED_FILES[@]}"; do
            [[ "$cancelled" == "true" ]] && break
            rel="${entry%%|*}"
            local rest="${entry#*|}"
            src="${rest%|*}"
            t_new="${rest##*|}"
            dest="$repo_root/$_SRC_BASE/$rel"
            if [[ "$assume_yes" == "true" ]]; then
                # Restoring deleted files non-interactively is too aggressive — skip.
                echo "  $(_dim "?") $rel $(_dim "(previously declined — skipped under --yes; run interactively)")"
                skipped=$((skipped + 1))
                continue
            fi
            local choice
            choice=$(_refresh_prompt_deleted "$rel" "$src")
            case "$choice" in
                a)  _refresh_copy "$src" "$dest"
                    template_manifest_record "$rel" "$t_new"
                    echo "    $(_green "restored.")"
                    added=$((added + 1)) ;;
                s)  echo "    $(_dim "still declined.")"
                    skipped=$((skipped + 1)) ;;
                q)  cancelled=true ;;
            esac
        done
    fi

    if (( new_count > 0 )) && [[ "$cancelled" != "true" ]]; then
        local entry rel src t_new dest
        for entry in "${NEW_FILES[@]}"; do
            [[ "$cancelled" == "true" ]] && break
            rel="${entry%%|*}"
            local rest="${entry#*|}"
            src="${rest%|*}"
            t_new="${rest##*|}"
            dest="$repo_root/$_SRC_BASE/$rel"

            if [[ "$assume_yes" == "true" ]]; then
                _refresh_copy "$src" "$dest"
                template_manifest_record "$rel" "$t_new"
                echo "  $(_green "+") $rel"
                added=$((added + 1))
                continue
            fi

            local choice
            choice=$(_refresh_prompt_new "$rel" "$src")
            case "$choice" in
                a)  _refresh_copy "$src" "$dest"
                    template_manifest_record "$rel" "$t_new"
                    echo "    $(_green "added.")"
                    added=$((added + 1)) ;;
                s)  # Skip-as-decline: record the manifest entry so the file
                    # never reappears as NEW. The user can revisit with
                    # --include-deleted.
                    template_manifest_record "$rel" "$t_new"
                    echo "    $(_dim "declined (will not be offered again — use --include-deleted to revisit).")"
                    skipped=$((skipped + 1)) ;;
                q)  cancelled=true ;;
            esac
        done
    fi

    if (( conflict_count > 0 )) && [[ "$cancelled" != "true" ]]; then
        local entry rel src t_new dest
        for entry in "${CONFLICT_FILES[@]}"; do
            [[ "$cancelled" == "true" ]] && break
            rel="${entry%%|*}"
            local rest="${entry#*|}"
            src="${rest%|*}"
            t_new="${rest##*|}"
            dest="$repo_root/$_SRC_BASE/$rel"

            if [[ "$assume_yes" == "true" ]]; then
                echo "  $(_yellow "~") $rel $(_dim "(conflict — skipped; run interactively to review)")"
                skipped=$((skipped + 1))
                continue
            fi

            local choice
            choice=$(_refresh_prompt_conflict "$rel" "$src" "$dest")
            case "$choice" in
                u)  _refresh_copy "$src" "$dest"
                    template_manifest_record "$rel" "$t_new"
                    echo "    $(_yellow "updated.")"
                    updated=$((updated + 1)) ;;
                s)  # Record manifest at t_new so the skip is remembered: the
                    # divergence stays silent on future refreshes until a
                    # newer template ships (at which point we resurface it).
                    # `agentsync refresh --review` lets the user revisit
                    # explicitly. For an unconditional pin, the user can add
                    # the path to template_overrides.pinned in agent_sync.yaml.
                    template_manifest_record "$rel" "$t_new"
                    echo "    $(_dim "skipped (remembered — agentsync refresh --review to revisit).")"
                    skipped=$((skipped + 1)) ;;
                q)  cancelled=true ;;
            esac
        done
    fi

    # Heal manifest with everything that already matches the current template.
    # This is what migrates a project from "no manifest" (v1 era) to a baselined
    # one without forcing the user to re-accept a wall of files.
    _refresh_heal_unchanged "$templates_dir" "$repo_root/$_SRC_BASE"

    template_manifest_write

    echo ""
    if [[ "$cancelled" == "true" ]]; then
        echo "  $(_yellow "Cancelled.") Files already applied are kept."
    fi
    echo "  $(_green "Done.") Added: $added · Auto-updated: $auto_applied · Updated: $updated · Skipped: $skipped · Unchanged: $unchanged_count"
    if (( added + auto_applied + updated > 0 )); then
        echo ""
        echo "  Next: $(_cyan "agentsync sync") to distribute the updates to enabled tools."
    fi
    echo ""
}

# ── Path / scope helpers ─────────────────────────────────────────────────────

_refresh_find_templates() {
    local system_dir
    system_dir=$(resolve_system_dir 2>/dev/null) || return 1
    local templates_dir="$system_dir/templates"
    [[ -d "$templates_dir" ]] || return 1
    echo "$templates_dir"
}

# Validate and normalize --only into a space-separated category list.
# When --only is empty, default to categories that already have a subdirectory
# in the user's .ai/src/ — respects the user's original `init --content` choice
# and prevents `refresh` from silently introducing categories they opted out of.
# Pass --only explicitly to bring in a brand-new category.
_refresh_resolve_scope() {
    local only="$1"
    local user_base="$2"

    if [[ -z "$only" ]]; then
        local out="" cat
        for cat in $_REFRESH_CATEGORIES_DEFAULT; do
            [[ -d "$user_base/$cat" ]] && out="${out:+$out }$cat"
        done
        if [[ -z "$out" ]]; then
            echo "$(_red "Error"): No source content categories present in $user_base." >&2
            echo "Pass $(_cyan "--only rules,skills,commands,agents") to opt into specific ones," >&2
            echo "or run $(_cyan "agentsync init") to scaffold them." >&2
            return 1
        fi
        echo "$out"
        return 0
    fi

    local out="" tok
    IFS=',' read -ra toks <<< "$only"
    for tok in "${toks[@]}"; do
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ -z "$tok" ]] && continue
        # `subagents` is the init/--content token; the dir name is `agents`.
        [[ "$tok" == "subagents" ]] && tok="agents"
        if [[ " $_REFRESH_CATEGORIES_VALID " != *" $tok "* ]]; then
            echo "$(_red "Error"): Unknown --only value: $tok" >&2
            echo "Valid: rules, skills, commands, agents (or subagents)" >&2
            return 1
        fi
        [[ " $out " == *" $tok "* ]] || out="${out:+$out }$tok"
    done

    if [[ -z "$out" ]]; then
        echo "$(_red "Error"): --only must include at least one category" >&2
        return 1
    fi
    echo "$out"
}

# Read template_overrides.{declined,pinned} from agent_sync.yaml. Both are
# optional lists of rel paths (e.g. "rules/foo.md"). Read-only in v2 — users
# edit the YAML directly to mark a template as ignored.
_refresh_load_overrides() {
    local repo_root="$1"
    DECLINED_OVERRIDES=()
    PINNED_OVERRIDES=()

    local config="$repo_root/.ai/agent_sync.yaml"
    [[ -f "$config" ]] || config="$repo_root/agent_sync.yaml"
    [[ -f "$config" ]] || return 0

    local item
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        DECLINED_OVERRIDES+=("$item")
    done < <(parse_yaml_list "$config" "template_overrides.declined" 2>/dev/null || true)

    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        PINNED_OVERRIDES+=("$item")
    done < <(parse_yaml_list "$config" "template_overrides.pinned" 2>/dev/null || true)
}

_refresh_in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ── Diff collection ──────────────────────────────────────────────────────────

# Walk templates_dir and populate the global *_FILES arrays.
_refresh_collect_changes() {
    local templates_dir="$1"
    local repo_root="$2"
    local categories="$3"
    local include_agents_md="$4"
    local user_base="$repo_root/$_SRC_BASE"

    if [[ "$include_agents_md" == "true" ]] && [[ -f "$templates_dir/AGENTS.md" ]]; then
        _refresh_classify "$templates_dir/AGENTS.md" "$user_base/AGENTS.md" "AGENTS.md"
    fi

    local cat
    for cat in rules commands agents; do
        [[ " $categories " == *" $cat "* ]] || continue
        local tdir="$templates_dir/$cat"
        [[ -d "$tdir" ]] || continue
        local f rel
        for f in "$tdir"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            _refresh_classify "$f" "$user_base/$rel" "$rel"
        done
    done

    if [[ " $categories " == *" skills "* ]] && [[ -d "$templates_dir/skills" ]]; then
        local f rel
        while IFS= read -r -d '' f; do
            rel="${f#"$templates_dir/"}"
            _refresh_classify "$f" "$user_base/$rel" "$rel"
        done < <(find "$templates_dir/skills" -type f \( -name "*.md" -o -name "*.markdown" \) -print0 2>/dev/null | LC_ALL=C sort -z)
    fi
}

# Three-way classification for one (template, user) pair.
_refresh_classify() {
    local src="$1" dest="$2" rel="$3"

    if _refresh_in_array "$rel" ${DECLINED_OVERRIDES[@]+"${DECLINED_OVERRIDES[@]}"}; then
        return 0  # silent
    fi

    local t_new
    t_new=$(template_manifest_hash "$src") || return 0

    local t_old
    t_old=$(template_manifest_lookup "$rel" 2>/dev/null) || t_old=""

    if [[ ! -f "$dest" ]]; then
        if [[ -n "$t_old" ]]; then
            DELETED_FILES+=("$rel|$src|$t_new")
        else
            NEW_FILES+=("$rel|$src|$t_new")
        fi
        return 0
    fi

    local u_cur
    u_cur=$(template_manifest_hash "$dest") || return 0

    if [[ "$u_cur" == "$t_new" ]]; then
        UNCHANGED_FILES+=("$rel")
        return 0
    fi

    if _refresh_in_array "$rel" ${PINNED_OVERRIDES[@]+"${PINNED_OVERRIDES[@]}"}; then
        # Pinned: user wants their own version, ignore template changes.
        return 0
    fi

    if [[ -z "$t_old" ]]; then
        CONFLICT_FILES+=("$rel|$src|$t_new")
        return 0
    fi

    if [[ "$u_cur" == "$t_old" ]]; then
        AUTO_UPDATE_FILES+=("$rel|$src|$t_new")
        return 0
    fi

    if [[ "$t_old" == "$t_new" ]]; then
        # Template hasn't moved since the manifest was recorded. Two ways we
        # land here:
        #   1. User edited locally and no new template has shipped since.
        #   2. User previously hit `[s]kip` on a conflict — we recorded the
        #      template hash at that time, so on subsequent refreshes the
        #      divergence stays silent until a newer template ships.
        # Default: silent. --review forces it to surface so users can revisit
        # their earlier decision (or audit local edits against the templates).
        SILENTLY_KEPT_COUNT=$((SILENTLY_KEPT_COUNT + 1))
        if [[ "$REFRESH_REVIEW_MODE" == "true" ]]; then
            CONFLICT_FILES+=("$rel|$src|$t_new")
        fi
        return 0
    fi

    CONFLICT_FILES+=("$rel|$src|$t_new")
}

# Heal the manifest with hashes for files that already match the current
# template. Lets v1-era projects get a baseline on their first v2 refresh
# without surfacing a wall of conflicts.
_refresh_heal_unchanged() {
    template_manifest_heal_from_match "$1" "$2"
}

# Print a full breakdown of declined templates. Two sources:
#   * Persistent: template_overrides.declined in agent_sync.yaml — these will
#     never be offered, even by --include-deleted.
#   * Local: .template-manifest entries whose corresponding file is missing
#     on disk and which are NOT in the persistent list — these will resurface
#     under --include-deleted.
_refresh_print_status() {
    local repo_root="$1"

    echo ""
    _bold "  Declined templates"; echo ""

    local persistent_count=${#DECLINED_OVERRIDES[@]}
    local deleted_count=${#DELETED_FILES[@]}

    if (( persistent_count == 0 )) && (( deleted_count == 0 )); then
        echo "  $(_dim "Nothing declined.")"
        echo ""
        return 0
    fi

    if (( persistent_count > 0 )); then
        echo "  $(_yellow "Persistent")  $(_dim "(template_overrides.declined in agent_sync.yaml — never offered):")"
        local item
        for item in "${DECLINED_OVERRIDES[@]}"; do
            echo "    $(_dim "·") $item"
        done
        echo ""
    fi

    if (( deleted_count > 0 )); then
        echo "  $(_yellow "Local")       $(_dim "(.template-manifest — deleted from disk; --include-deleted to restore):")"
        local entry
        for entry in "${DELETED_FILES[@]}"; do
            echo "    $(_dim "·") ${entry%%|*}"
        done
        echo ""
    fi
}

# ── Output helpers ───────────────────────────────────────────────────────────

_refresh_list_proposed() {
    local include_deleted="$1"
    local entry
    if (( ${#NEW_FILES[@]} > 0 )); then
        echo "  $(_green "New:")"
        for entry in "${NEW_FILES[@]}"; do
            echo "    $(_green "+") ${entry%%|*}"
        done
        echo ""
    fi
    if (( ${#AUTO_UPDATE_FILES[@]} > 0 )); then
        echo "  $(_cyan "Auto-update:") $(_dim "(your version matches the previous template; safe to update)")"
        for entry in "${AUTO_UPDATE_FILES[@]}"; do
            echo "    $(_cyan "↑") ${entry%%|*}"
        done
        echo ""
    fi
    if (( ${#CONFLICT_FILES[@]} > 0 )); then
        echo "  $(_yellow "Conflicts:") $(_dim "(both your version and the template diverged from the recorded baseline)")"
        for entry in "${CONFLICT_FILES[@]}"; do
            echo "    $(_yellow "~") ${entry%%|*}"
        done
        echo ""
    fi
    if [[ "$include_deleted" == "true" ]] && (( ${#DELETED_FILES[@]} > 0 )); then
        echo "  $(_dim "Previously declined:")"
        for entry in "${DELETED_FILES[@]}"; do
            echo "    $(_dim "?") ${entry%%|*}"
        done
        echo ""
    fi
}

_refresh_copy() {
    local src="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
}

# ── Interactive prompts ──────────────────────────────────────────────────────
# UI goes to stderr; only the chosen action ('a'/'s'/'u'/'q') reaches stdout.

_refresh_prompt_new() {
    local rel="$1" src="$2"
    while true; do
        echo "" >&2
        printf "  %s %s\n" "$(_green "+ NEW:")" "$(_cyan "$rel")" >&2
        printf "    [%s]dd  [%s]kip  [v]iew  [q]uit  > " "$(_green "a")" "$(_yellow "s")" >&2
        local reply=""
        read -r reply </dev/tty || reply=""
        reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        reply="${reply:-s}"
        case "$reply" in
            a|add)    echo "a"; return 0 ;;
            s|skip)   echo "s"; return 0 ;;
            v|view)   _refresh_show_new "$src" >&2 ;;
            q|quit)   echo "q"; return 0 ;;
            *)        echo "    $(_dim "(unknown choice — try a, s, v, q)")" >&2 ;;
        esac
    done
}

_refresh_prompt_conflict() {
    local rel="$1" src="$2" dest="$3"
    while true; do
        echo "" >&2
        printf "  %s %s\n" "$(_yellow "~ CONFLICT:")" "$(_cyan "$rel")" >&2
        printf "    [%s]pdate  [%s]kip  [v]iew  [q]uit  > " "$(_yellow "u")" "$(_yellow "s")" >&2
        local reply=""
        read -r reply </dev/tty || reply=""
        reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        reply="${reply:-s}"
        case "$reply" in
            u|update) echo "u"; return 0 ;;
            s|skip)   echo "s"; return 0 ;;
            v|view)   _refresh_show_diff "$dest" "$src" >&2 ;;
            q|quit)   echo "q"; return 0 ;;
            *)        echo "    $(_dim "(unknown choice — try u, s, v, q)")" >&2 ;;
        esac
    done
}

_refresh_prompt_deleted() {
    local rel="$1" src="$2"
    while true; do
        echo "" >&2
        printf "  %s %s  %s\n" "$(_dim "? RESTORE:")" "$(_cyan "$rel")" "$(_dim "(previously declined)")" >&2
        printf "    [%s]dd  [%s]kip  [v]iew  [q]uit  > " "$(_green "a")" "$(_yellow "s")" >&2
        local reply=""
        read -r reply </dev/tty || reply=""
        reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        reply="${reply:-s}"
        case "$reply" in
            a|add)    echo "a"; return 0 ;;
            s|skip)   echo "s"; return 0 ;;
            v|view)   _refresh_show_new "$src" >&2 ;;
            q|quit)   echo "q"; return 0 ;;
            *)        echo "    $(_dim "(unknown choice — try a, s, v, q)")" >&2 ;;
        esac
    done
}

_refresh_show_new() {
    local src="$1"
    echo ""
    echo "  $(_dim "──── new file content ────")"
    echo ""
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf "  %s\n" "$line"
    done < "$src"
    echo ""
}

_refresh_show_diff() {
    local user="$1" tmpl="$2"
    echo ""
    echo "  $(_dim "──── diff: yours → template ────")"
    echo ""
    if command -v diff >/dev/null 2>&1; then
        diff -u --label "yours" --label "template" "$user" "$tmpl" || true
    else
        echo "  $(_red "(diff command not available)")"
    fi
    echo ""
}

# ── Usage ────────────────────────────────────────────────────────────────────

_refresh_usage() {
    cat <<HELP

  $(_bold "agentsync refresh") — pull new template files into an existing .ai/src/

  $(_green "USAGE")
    agentsync refresh [options]

  $(_green "DESCRIPTION")
    Compares each shipped template (rules, skills, commands, agents) against
    your local .ai/src/ using a three-way diff (template-old vs template-new
    vs your current file) when a template manifest is present. Files you
    haven't touched auto-update silently; only true conflicts require review.
    Files in .ai/src/ that aren't part of the templates (your custom content)
    are left alone.

  $(_green "OPTIONS")
    --only <csv>           Categories to consider: rules, skills, commands, agents
                           Default: only categories that already have a subdir
                           in your .ai/src/. Pass --only to opt into a category
                           you don't have yet.
    --include-agents-md    Also offer updates to AGENTS.md (off by default —
                           almost always heavily customized).
    --include-deleted      Re-offer files you previously declined and removed
                           from disk so they can be restored.
    --review               Resurface every local divergence from the shipped
                           templates, including conflicts you previously
                           [s]kipped. Use this to revisit earlier decisions
                           or audit local edits.
    --status               Print declined breakdown (persistent + local) and
                           exit. No mutation, no prompts.
    --dry-run              Print the plan without writing anything.
    -y, --yes              Apply auto-updates and add new files; skip conflicts
                           (no prompts). Required in non-interactive contexts.
    -h, --help             Show this help.

  $(_green "REMEMBERED SKIPS")
    Picking $(_yellow "[s]kip") on a conflict records the current template hash in
    .ai/.template-manifest. The divergence stays silent on future refreshes
    until a newer template ships (at which point it resurfaces automatically
    so you can review the new change). Pass $(_cyan "--review") at any time to
    revisit your skips explicitly.

  $(_green "PERSISTENT OVERRIDES")
    Edit .ai/agent_sync.yaml to silence specific templates forever (this is
    stronger than $(_yellow "[s]kip") — even new template versions stay hidden):

      template_overrides:
        declined:        # always-skip; never offered
          - rules/some-rule.md
        pinned:          # ignore template updates; keep your version
          - rules/my-version.md

  $(_green "EXAMPLES")
    agentsync refresh
    agentsync refresh --only rules,skills
    agentsync refresh --dry-run
    agentsync refresh --yes               # CI-friendly: auto-update + add new
    agentsync refresh --include-deleted   # revisit previously declined files
    agentsync refresh --review            # revisit conflicts you skipped
HELP
}
