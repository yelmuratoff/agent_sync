#!/usr/bin/env bash
# agentsync refresh — pull updated rule/skill/command/subagent templates
# into an existing .ai/src/, with per-file diff and approve/skip.
#
# Scope: source content only (rules, skills, commands, agents). AGENTS.md is
# off by default (almost always heavily customized). Tool configs (settings,
# mcp, hooks, tools) are intentionally excluded — they have their own
# customize/simplify/resolve flow.
#
# Mental model: walk lib/templates/ and compare each file against .ai/src/.
#   * exists locally + matches → unchanged (silent)
#   * exists locally + differs → conflict (diff shown; user picks)
#   * missing locally          → new (offered for adding)
#   * exists locally, NOT in templates → user's custom content; left alone

# Categories considered by refresh. Keep in sync with init's --content tokens
# and the lib/templates/ layout. AGENTS.md is handled separately under a flag.
_REFRESH_CATEGORIES_VALID="rules skills commands agents subagents"
_REFRESH_CATEGORIES_DEFAULT="rules skills commands agents"

# Populated by _refresh_collect_changes. Scoped at file level for readability;
# each entry is "<rel-path>|<absolute-template-path>" (NEW/CONFLICT) or just
# "<rel-path>" (UNCHANGED).
NEW_FILES=()
CONFLICT_FILES=()
UNCHANGED_FILES=()

cmd_refresh() {
    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    local dry_run=false
    local assume_yes=false
    local include_agents_md=false
    local only_flag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)            dry_run=true; shift ;;
            --yes|-y)             assume_yes=true; shift ;;
            --include-agents-md)  include_agents_md=true; shift ;;
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

    NEW_FILES=()
    CONFLICT_FILES=()
    UNCHANGED_FILES=()
    _refresh_collect_changes "$templates_dir" "$repo_root" "$categories" "$include_agents_md"

    local new_count=${#NEW_FILES[@]}
    local conflict_count=${#CONFLICT_FILES[@]}
    local unchanged_count=${#UNCHANGED_FILES[@]}

    echo ""
    _bold "  AgentSync Refresh"; echo ""
    echo ""
    echo "  $(_dim "Templates:") $templates_dir"
    echo "  $(_dim "Project:")   $repo_root/$_SRC_BASE"
    echo "  $(_dim "Scope:")     $(echo "$categories" | tr ' ' ',')$([[ "$include_agents_md" == "true" ]] && echo ",AGENTS.md")"
    echo ""

    if (( new_count == 0 && conflict_count == 0 )); then
        echo "  $(_green "Already up to date!") $unchanged_count file(s) match the current templates."
        echo ""
        return 0
    fi

    echo "  $(_green "Summary:")"
    (( new_count > 0 ))       && echo "    $(_green "+") $new_count new template(s) — not in your .ai/src/"
    (( conflict_count > 0 ))  && echo "    $(_yellow "~") $conflict_count modified — your version differs from the template"
    (( unchanged_count > 0 )) && echo "    $(_dim "·") $unchanged_count unchanged"
    echo ""

    _refresh_list_proposed

    if [[ "$dry_run" == "true" ]]; then
        echo "  $(_yellow "Dry run") — no files written."
        echo ""
        return 0
    fi

    if ! is_tty && [[ "$assume_yes" != "true" ]]; then
        echo "  $(_red "Error"): Cannot run interactively (not a TTY)." >&2
        echo "  Use $(_cyan "--yes") to accept new files (conflicts always skipped non-interactively)." >&2
        echo "  Use $(_cyan "--dry-run") to preview." >&2
        return 1
    fi

    local added=0 updated=0 skipped=0 cancelled=false

    if (( new_count > 0 )); then
        local entry
        for entry in "${NEW_FILES[@]}"; do
            [[ "$cancelled" == "true" ]] && break
            local rel="${entry%%|*}"
            local src="${entry#*|}"
            local dest="$repo_root/$_SRC_BASE/$rel"

            if [[ "$assume_yes" == "true" ]]; then
                _refresh_copy "$src" "$dest"
                echo "  $(_green "+") $rel"
                added=$((added + 1))
                continue
            fi

            local choice
            choice=$(_refresh_prompt_new "$rel" "$src")
            case "$choice" in
                a)  _refresh_copy "$src" "$dest"
                    echo "    $(_green "added.")"
                    added=$((added + 1)) ;;
                s)  echo "    $(_dim "skipped.")"
                    skipped=$((skipped + 1)) ;;
                q)  cancelled=true ;;
            esac
        done
    fi

    if (( conflict_count > 0 )) && [[ "$cancelled" != "true" ]]; then
        local entry
        for entry in "${CONFLICT_FILES[@]}"; do
            [[ "$cancelled" == "true" ]] && break
            local rel="${entry%%|*}"
            local src="${entry#*|}"
            local dest="$repo_root/$_SRC_BASE/$rel"

            if [[ "$assume_yes" == "true" ]]; then
                echo "  $(_yellow "~") $rel $(_dim "(conflict — skipped; run interactively to review)")"
                skipped=$((skipped + 1))
                continue
            fi

            local choice
            choice=$(_refresh_prompt_conflict "$rel" "$src" "$dest")
            case "$choice" in
                u)  _refresh_copy "$src" "$dest"
                    echo "    $(_yellow "updated.")"
                    updated=$((updated + 1)) ;;
                s)  echo "    $(_dim "skipped.")"
                    skipped=$((skipped + 1)) ;;
                q)  cancelled=true ;;
            esac
        done
    fi

    echo ""
    if [[ "$cancelled" == "true" ]]; then
        echo "  $(_yellow "Cancelled.") Files already applied are kept."
    fi
    echo "  $(_green "Done.") Added: $added · Updated: $updated · Skipped: $skipped · Unchanged: $unchanged_count"
    if (( added + updated > 0 )); then
        echo ""
        echo "  Next: $(_cyan "agentsync sync") to distribute the updates to enabled tools."
    fi
    echo ""
}

# ── Path / scope helpers ─────────────────────────────────────────────────────

# Locate lib/templates/ alongside the loaded helpers.
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
        # Dedupe.
        [[ " $out " == *" $tok "* ]] || out="${out:+$out }$tok"
    done

    if [[ -z "$out" ]]; then
        echo "$(_red "Error"): --only must include at least one category" >&2
        return 1
    fi
    echo "$out"
}

# ── Diff collection ──────────────────────────────────────────────────────────

# Walk templates_dir and populate NEW_FILES / CONFLICT_FILES / UNCHANGED_FILES.
_refresh_collect_changes() {
    local templates_dir="$1"
    local repo_root="$2"
    local categories="$3"
    local include_agents_md="$4"
    local user_base="$repo_root/$_SRC_BASE"

    if [[ "$include_agents_md" == "true" ]] && [[ -f "$templates_dir/AGENTS.md" ]]; then
        _refresh_compare_file "$templates_dir/AGENTS.md" "$user_base/AGENTS.md" "AGENTS.md"
    fi

    # Flat directories (rules, commands, agents).
    local cat
    for cat in rules commands agents; do
        [[ " $categories " == *" $cat "* ]] || continue
        local tdir="$templates_dir/$cat"
        [[ -d "$tdir" ]] || continue
        local f rel
        for f in "$tdir"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            _refresh_compare_file "$f" "$user_base/$rel" "$rel"
        done
    done

    # Skills are nested (skill/SKILL.md plus optional references/*.md).
    if [[ " $categories " == *" skills "* ]] && [[ -d "$templates_dir/skills" ]]; then
        local f rel
        while IFS= read -r -d '' f; do
            rel="${f#"$templates_dir/"}"
            _refresh_compare_file "$f" "$user_base/$rel" "$rel"
        done < <(find "$templates_dir/skills" -type f \( -name "*.md" -o -name "*.markdown" \) -print0 2>/dev/null | LC_ALL=C sort -z)
    fi
}

_refresh_compare_file() {
    local src="$1" dest="$2" rel="$3"
    if [[ ! -f "$dest" ]]; then
        NEW_FILES+=("$rel|$src")
    elif cmp -s "$src" "$dest"; then
        UNCHANGED_FILES+=("$rel")
    else
        CONFLICT_FILES+=("$rel|$src")
    fi
}

# ── Output helpers ───────────────────────────────────────────────────────────

_refresh_list_proposed() {
    local entry
    if (( ${#NEW_FILES[@]} > 0 )); then
        echo "  $(_green "New:")"
        for entry in "${NEW_FILES[@]}"; do
            echo "    $(_green "+") ${entry%%|*}"
        done
        echo ""
    fi
    if (( ${#CONFLICT_FILES[@]} > 0 )); then
        echo "  $(_yellow "Conflicts:") $(_dim "(your version differs from the template)")"
        for entry in "${CONFLICT_FILES[@]}"; do
            echo "    $(_yellow "~") ${entry%%|*}"
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
# All UI goes to stderr; only the chosen action ('a'/'s'/'u'/'q') reaches stdout
# so callers can capture it via `$(...)`.

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
        # diff -u returns 1 when files differ — expected here, swallow it.
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
    your local .ai/src/. New templates are offered for adding; modified files
    show a diff so you can update or skip per file. Files in .ai/src/ that
    aren't part of the templates (your custom content) are left alone.

  $(_green "OPTIONS")
    --only <csv>           Categories to consider: rules, skills, commands, agents
                           Default: only categories that already have a subdir
                           in your .ai/src/. Pass --only to opt into a category
                           you don't have yet.
    --include-agents-md    Also offer updates to AGENTS.md (off by default —
                           almost always heavily customized).
    --dry-run              Print the plan without writing anything.
    -y, --yes              Add new files; skip conflicts (no prompts).
                           Required in non-interactive contexts (CI, pipes).
    -h, --help             Show this help.

  $(_green "EXAMPLES")
    agentsync refresh
    agentsync refresh --only rules,skills
    agentsync refresh --dry-run
    agentsync refresh --yes               # CI-friendly: add new files only
    agentsync refresh --include-agents-md # also review AGENTS.md updates
HELP
}
