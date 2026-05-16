#!/usr/bin/env bash
# agentsync dedupe — interactively remove source files in the current
# .ai/src/ that duplicate (or diverge from) a parent .ai/src/.
#
# Two modes:
#   * default            — compare against the nearest parent .ai/src/
#                          (walk-up bounded by git boundary; see paths.sh)
#   * --against PATH     — compare against an explicit .ai/src/ tree
#   * --workspace        — bottom-up alphabetical fan-out across every
#                          .ai/ below cwd; each project deduped against
#                          its own nearest parent
#
# For each shared path:
#   * identical hash, file IS shipped as a template
#       → offer: [d]elete + add to template_overrides.declined
#   * identical hash, file is NOT shipped as a template
#       → offer: [d]elete (no manifest write — declined is template-only)
#   * different hash
#       → show diff, leave decision to the human; no automatic action
#
# Exit codes: 0 on success (including "nothing to do"), 1 on usage/setup error.

# shellcheck source=paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
# shellcheck source=template_manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/template_manifest.sh"
# shellcheck source=yaml_edit.sh
source "$(dirname "${BASH_SOURCE[0]}")/yaml_edit.sh"
# shellcheck source=shared.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

# Walk the shipped templates and load every relative path into a lookup set.
# Used to classify duplicates as "template-derived" (eligible for
# template_overrides.declined) vs "manual" (just delete it).
_DEDUPE_TEMPLATE_SET="|"

_dedupe_load_template_set() {
    _DEDUPE_TEMPLATE_SET="|"
    local templates_dir
    templates_dir=$(resolve_system_dir 2>/dev/null)/templates
    [[ -d "$templates_dir" ]] || return 0

    local f rel
    if [[ -f "$templates_dir/AGENTS.md" ]]; then
        _DEDUPE_TEMPLATE_SET="${_DEDUPE_TEMPLATE_SET}AGENTS.md|"
    fi
    local cat
    for cat in rules commands agents; do
        [[ -d "$templates_dir/$cat" ]] || continue
        for f in "$templates_dir/$cat"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            _DEDUPE_TEMPLATE_SET="${_DEDUPE_TEMPLATE_SET}${rel}|"
        done
    done
    if [[ -d "$templates_dir/skills" ]]; then
        while IFS= read -r -d '' f; do
            rel="${f#"$templates_dir/"}"
            _DEDUPE_TEMPLATE_SET="${_DEDUPE_TEMPLATE_SET}${rel}|"
        done < <(find "$templates_dir/skills" -type f ! -name '.*' -print0 2>/dev/null)
    fi
}

_dedupe_is_template() {
    local rel="$1"
    [[ "$_DEDUPE_TEMPLATE_SET" == *"|${rel}|"* ]]
}

# Locate the project's agent_sync.yaml — required for declined-list writes.
# Echoes path or empty.
_dedupe_config_path() {
    local repo_root="$1"
    if [[ -f "$repo_root/.ai/agent_sync.yaml" ]]; then
        echo "$repo_root/.ai/agent_sync.yaml"
    elif [[ -f "$repo_root/agent_sync.yaml" ]]; then
        echo "$repo_root/agent_sync.yaml"
    fi
}

# Show a unified diff between two files via the system `diff`, or an
# apologetic message if diff is missing.
_dedupe_show_diff() {
    local local_file="$1" parent_file="$2"
    echo "" >&2
    echo "  $(_dim "──── diff: yours → parent ────")" >&2
    echo "" >&2
    if command -v diff >/dev/null 2>&1; then
        diff -u --label "yours" --label "parent" "$local_file" "$parent_file" >&2 || true
    else
        echo "  $(_red "(diff command not available)")" >&2
    fi
    echo "" >&2
}

# Show the head of a single file (for confirming "delete this exact content").
_dedupe_show_head() {
    local file="$1"
    local max_lines=20
    echo "" >&2
    echo "  $(_dim "──── content (first ${max_lines} lines) ────")" >&2
    echo "" >&2
    local n=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ $n -gt $max_lines ]] && { echo "  $(_dim "  …")" >&2; break; }
        printf '  %s\n' "$line" >&2
    done < "$file"
    echo "" >&2
}

# Interactive prompt for the identical-hash case.
# Echoes a single-char choice on stdout: d (delete), k (keep), v (view), q (quit).
_dedupe_prompt_identical() {
    local rel="$1" local_file="$2" is_tmpl="$3"
    local mfst_hint=""
    [[ "$is_tmpl" == "true" ]] && mfst_hint="$(_dim "(template-derived — declined entry will be added)")"
    while true; do
        echo "" >&2
        printf "  %s %s  %s\n" "$(_yellow "= IDENTICAL:")" "$(_cyan "$rel")" "$mfst_hint" >&2
        printf "    [%s]elete  [%s]eep  [v]iew  [q]uit  > " "$(_green "d")" "$(_yellow "k")" >&2
        local reply=""
        read -r reply </dev/tty || reply=""
        reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        reply="${reply:-k}"
        case "$reply" in
            d|delete) echo "d"; return 0 ;;
            k|keep)   echo "k"; return 0 ;;
            v|view)   _dedupe_show_head "$local_file" ;;
            q|quit)   echo "q"; return 0 ;;
            *)        echo "    $(_dim "(unknown choice — try d, k, v, q)")" >&2 ;;
        esac
    done
}

# Interactive prompt for the different-hash case. No delete option — divergent
# files require a human judgment that dedupe deliberately won't shortcut.
_dedupe_prompt_diverge() {
    local rel="$1" local_file="$2" parent_file="$3"
    while true; do
        echo "" >&2
        printf "  %s %s\n" "$(_yellow "~ DIVERGES:")" "$(_cyan "$rel")" >&2
        printf "    [%s]iew  [%s]kip  [q]uit  > " "$(_yellow "v")" "$(_yellow "s")" >&2
        local reply=""
        read -r reply </dev/tty || reply=""
        reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        reply="${reply:-s}"
        case "$reply" in
            v|view)   _dedupe_show_diff "$local_file" "$parent_file" ;;
            s|skip)   echo "s"; return 0 ;;
            q|quit)   echo "q"; return 0 ;;
            *)        echo "    $(_dim "(unknown choice — try v, s, q)")" >&2 ;;
        esac
    done
}

# Walk shared paths and populate two parallel arrays:
#   _DEDUPE_IDENTICAL_RELS / _DEDUPE_IDENTICAL_PATHS  ("<rel>|<local_abs>")
#   _DEDUPE_DIVERGENT_RELS / _DEDUPE_DIVERGENT_PATHS  ("<rel>|<local_abs>|<parent_abs>")
_DEDUPE_IDENTICAL=()
_DEDUPE_DIVERGENT=()

_dedupe_collect() {
    local child_src="$1" parent_src="$2"
    _DEDUPE_IDENTICAL=()
    _DEDUPE_DIVERGENT=()

    local rel cf pf ch ph cat f
    for cat in rules commands agents; do
        [[ -d "$parent_src/$cat" ]] || continue
        for f in "$parent_src/$cat"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            cf="$child_src/$rel"
            pf="$f"
            [[ -f "$cf" ]] || continue
            ch=$(template_manifest_hash "$cf") || continue
            ph=$(template_manifest_hash "$pf") || continue
            if [[ "$ch" == "$ph" ]]; then
                _DEDUPE_IDENTICAL+=("$rel|$cf")
            else
                _DEDUPE_DIVERGENT+=("$rel|$cf|$pf")
            fi
        done
    done

    if [[ -d "$parent_src/skills" ]]; then
        local fpath
        while IFS= read -r -d '' fpath; do
            rel="${fpath#"$parent_src/"}"
            cf="$child_src/$rel"
            pf="$fpath"
            [[ -f "$cf" ]] || continue
            ch=$(template_manifest_hash "$cf") || continue
            ph=$(template_manifest_hash "$pf") || continue
            if [[ "$ch" == "$ph" ]]; then
                _DEDUPE_IDENTICAL+=("$rel|$cf")
            else
                _DEDUPE_DIVERGENT+=("$rel|$cf|$pf")
            fi
        done < <(find "$parent_src/skills" -type f ! -name '.*' -print0 2>/dev/null | LC_ALL=C sort -z)
    fi
}

# Delete a child file, then prune any empty parent directories up to .ai/src/.
# Skill directories often hold one or two files; an emptied skill dir is
# itself noise.
_dedupe_delete_and_prune() {
    local file="$1" stop_at="$2"
    rm -f "$file"
    local dir
    dir=$(dirname "$file")
    while [[ "$dir" != "$stop_at" ]] && [[ "$dir" != "/" ]]; do
        rmdir "$dir" 2>/dev/null || break
        dir=$(dirname "$dir")
    done
}

# Run dedupe in a single project. Assumes REPO_ROOT is set to the project's
# absolute path. Returns 0 on completion, 1 on setup error.
_dedupe_run_one() {
    local repo_root="$1"
    local parent_override="$2"
    local assume_yes="$3"

    local child_src="$repo_root/.ai/src"
    if [[ ! -d "$child_src" ]]; then
        echo "  $(_yellow "skip"): no .ai/src/ in ${repo_root}"
        return 0
    fi

    local parent_src=""
    local parent_origin=""
    if [[ -n "$parent_override" ]]; then
        if [[ -d "$parent_override/.ai/src" ]]; then
            parent_src=$(cd "$parent_override/.ai/src" && pwd)
        elif [[ -d "$parent_override" ]] && [[ "$(basename "$parent_override")" == "src" ]]; then
            parent_src=$(cd "$parent_override" && pwd)
        elif [[ -d "$parent_override" ]]; then
            echo "$(_red "Error"): --against path has no .ai/src/: $parent_override" >&2
            return 1
        else
            echo "$(_red "Error"): --against path does not exist: $parent_override" >&2
            return 1
        fi
        parent_origin="explicit"
    else
        local config_path
        config_path=$(_dedupe_config_path "$repo_root")
        parent_src=$(shared_parent_src "$config_path" "$repo_root" 2>/dev/null) || parent_src=""
        if [[ -n "$parent_src" ]]; then
            parent_origin="shared"
        else
            parent_src=$(find_parent_ai_src "$repo_root" 2>/dev/null) || parent_src=""
            [[ -n "$parent_src" ]] && parent_origin="walk"
        fi
    fi

    if [[ -z "$parent_src" ]]; then
        echo "  $(_dim "·") no parent .ai/src/ found for ${repo_root}"
        return 0
    fi

    _dedupe_collect "$child_src" "$parent_src"

    local id_count=${#_DEDUPE_IDENTICAL[@]}
    local dv_count=${#_DEDUPE_DIVERGENT[@]}

    if [[ $id_count -eq 0 ]] && [[ $dv_count -eq 0 ]]; then
        echo "  $(_green "✓") nothing shared with parent ${parent_src}"
        return 0
    fi

    local origin_hint=""
    [[ "$parent_origin" == "shared" ]] && origin_hint=" $(_dim "(from shared.path)")"
    echo "  $(_dim "Parent:") ${parent_src}${origin_hint}"
    echo "  $(_dim "Identical:") ${id_count}  $(_dim "Divergent:") ${dv_count}"
    echo ""

    local config_path
    config_path=$(_dedupe_config_path "$repo_root")

    local deleted=0 kept=0 skipped=0 cancelled=false
    local entry rel cf is_tmpl choice

    for entry in ${_DEDUPE_IDENTICAL[@]+"${_DEDUPE_IDENTICAL[@]}"}; do
        [[ "$cancelled" == "true" ]] && break
        rel="${entry%%|*}"
        cf="${entry#*|}"

        is_tmpl=false
        _dedupe_is_template "$rel" && is_tmpl=true

        if [[ "$assume_yes" == "true" ]]; then
            _dedupe_delete_and_prune "$cf" "$child_src"
            if [[ "$is_tmpl" == "true" ]] && [[ -n "$config_path" ]]; then
                yaml_list_append "$config_path" "template_overrides.declined" "$rel"
            fi
            echo "  $(_green "−") $rel $(_dim "(deleted)")"
            deleted=$((deleted + 1))
            continue
        fi

        choice=$(_dedupe_prompt_identical "$rel" "$cf" "$is_tmpl")
        case "$choice" in
            d)
                _dedupe_delete_and_prune "$cf" "$child_src"
                if [[ "$is_tmpl" == "true" ]] && [[ -n "$config_path" ]]; then
                    yaml_list_append "$config_path" "template_overrides.declined" "$rel"
                    echo "    $(_green "deleted + declined.")"
                else
                    echo "    $(_green "deleted.")"
                fi
                deleted=$((deleted + 1))
                ;;
            k) echo "    $(_dim "kept.")"; kept=$((kept + 1)) ;;
            q) cancelled=true ;;
        esac
    done

    for entry in ${_DEDUPE_DIVERGENT[@]+"${_DEDUPE_DIVERGENT[@]}"}; do
        [[ "$cancelled" == "true" ]] && break
        rel="${entry%%|*}"
        local rest="${entry#*|}"
        cf="${rest%|*}"
        local pf="${rest##*|}"

        if [[ "$assume_yes" == "true" ]]; then
            echo "  $(_yellow "~") $rel $(_dim "(divergent — skipped under --yes; review interactively)")"
            skipped=$((skipped + 1))
            continue
        fi

        choice=$(_dedupe_prompt_diverge "$rel" "$cf" "$pf")
        case "$choice" in
            s) echo "    $(_dim "skipped.")"; skipped=$((skipped + 1)) ;;
            q) cancelled=true ;;
        esac
    done

    echo ""
    if [[ "$cancelled" == "true" ]]; then
        echo "  $(_yellow "Cancelled.") Decisions already made are kept."
    fi
    echo "  $(_green "Done.") Deleted: $deleted · Kept: $kept · Skipped: $skipped"
}

_dedupe_usage() {
    cat <<HELP

  $(_bold "agentsync dedupe") — remove source files that duplicate a parent .ai/src/

  $(_green "USAGE")
    agentsync dedupe [options]

  $(_green "OPTIONS")
    --against <path>   Compare against an explicit .ai/src/ (or a project
                       root containing one). Default: nearest parent
                       .ai/src/ walking up from cwd, bounded by the git
                       repository boundary.
    --workspace        Run dedupe in every .ai/ below cwd, bottom-up
                       alphabetical; each child is deduped against its
                       own nearest parent.
    -y, --yes          Non-interactive: delete every identical-hash file
                       (and add to template_overrides.declined when the
                       file is template-derived). Divergent files are
                       always left alone — pass --yes does not auto-pick
                       a side. Required when stdin is not a TTY.
    -h, --help         Show this help.

  $(_green "BEHAVIOR")
    For each path that exists in both your .ai/src/ and the parent:
      * identical hash, template-derived → offer delete + declined entry
      * identical hash, manual file      → offer delete only
      * different hash                   → show diff, skip by default

    Identical-hash deletions also prune empty parent directories so empty
    skill folders don't linger after their SKILL.md is removed.

  $(_green "EXAMPLES")
    agentsync dedupe
    agentsync dedupe --against ../
    agentsync dedupe --workspace
    agentsync dedupe --yes
HELP
}

cmd_dedupe() {
    local against=""
    local workspace=false
    local assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --against)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --against requires a path" >&2; return 1; }
                against="$2"; shift 2 ;;
            --against=*)         against="${1#--against=}"; shift ;;
            --workspace)         workspace=true; shift ;;
            --yes|-y)            assume_yes=true; shift ;;
            --help|-h)           _dedupe_usage; return 0 ;;
            -*)
                echo "$(_red "Error"): Unknown option: $1" >&2
                _dedupe_usage >&2
                return 1 ;;
            *)
                echo "$(_red "Error"): Unexpected argument: $1" >&2
                _dedupe_usage >&2
                return 1 ;;
        esac
    done

    if [[ "$workspace" == "true" ]] && [[ -n "$against" ]]; then
        echo "$(_red "Error"): --workspace and --against are mutually exclusive." >&2
        return 1
    fi

    if [[ "$assume_yes" != "true" ]] && ! is_tty; then
        echo "$(_red "Error"): dedupe needs an interactive TTY (or pass $(_cyan "--yes"))." >&2
        return 1
    fi

    _dedupe_load_template_set

    echo ""
    _bold "  AgentSync Dedupe"; echo ""

    if [[ "$workspace" == "true" ]]; then
        local cwd
        cwd=$(pwd)
        local -a ai_dirs=()
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            ai_dirs+=("$d")
        done < <(find_workspace_ai_dirs "$cwd")

        if [[ ${#ai_dirs[@]} -eq 0 ]]; then
            echo "  $(_red "Error"): No .ai/ directories found below $cwd" >&2
            return 1
        fi
        echo "  Found ${#ai_dirs[@]} project(s) below $cwd"; echo ""

        local project_root rel i
        for ((i = 0; i < ${#ai_dirs[@]}; i++)); do
            project_root=$(cd "${ai_dirs[$i]}/.." && pwd)
            if [[ "$project_root" == "$cwd" ]]; then
                rel="."
            else
                rel="${project_root#"$cwd/"}"
            fi
            echo "  $(_cyan "→") $rel"
            _dedupe_run_one "$project_root" "" "$assume_yes" || return $?
            echo ""
        done
        return 0
    fi

    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    repo_root=$(cd "$repo_root" && pwd)
    _dedupe_run_one "$repo_root" "$against" "$assume_yes"
}
