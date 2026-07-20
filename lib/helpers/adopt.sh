#!/usr/bin/env bash
# agentsync adopt — promote a manual edit in a destination file back into
# .ai/src/ as the new canonical content. Reverse direction of `sync`.
#
# Refuses transformed targets where the round-trip would corrupt source:
#   - merged rule files (merge_to_file / prepend_agents)
#   - inlined rules / skills (inline_into_agents)
#   - header-injected rules (cursor/junie style frontmatter)
#   - format-converted commands/subagents (toml, amazonq_json, opencode_md)
#
# After copy, updates the manifest entry so the next `sync` is idempotent.
#
# `--all` batch mode adopts every drifted (manually-edited) tracked output in
# one pass: it skips refused targets and same-source conflicts (two edited
# outputs mapping to one source with divergent content) rather than clobbering.

# Outputs (set by _adopt_resolve_dest):
_ADOPT_TOOL=""           # tool name owning the dest
_ADOPT_RESOURCE=""       # agents | rules | skills | commands | subagents | settings | mcp | hooks
_ADOPT_DEST_REL=""       # repo-relative dest path
_ADOPT_DEST_ABS=""       # canonical absolute dest path
_ADOPT_SOURCE_ABS=""     # absolute source path to write
_ADOPT_SOURCE_REL=""     # repo-relative source path (for messages)
_ADOPT_REFUSAL=""        # non-empty = refusal reason; bail with this message

# Batch-mode plan (set by _adopt_collect_all), parallel arrays over drifted
# outputs. _ADOPT_ALL_OK[i] gates whether entry i is applied.
_ADOPT_ALL_DEST_REL=()
_ADOPT_ALL_DEST_ABS=()
_ADOPT_ALL_SRC_REL=()
_ADOPT_ALL_SRC_ABS=()
_ADOPT_ALL_TOOL=()
_ADOPT_ALL_RES=()
_ADOPT_ALL_HASH=()
_ADOPT_ALL_OK=()
_ADOPT_ALL_SKIP_REL=()
_ADOPT_ALL_SKIP_REASON=()

_adopt_prepare_context() {
    local project_dir
    project_dir="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    project_dir="$(cd "$project_dir" && pwd)"
    REPO_ROOT="$project_dir"
    REPO_ROOT_CANONICAL="$(cd -P "$project_dir" && pwd)"

    local system_dir
    system_dir=$(resolve_system_dir 2>/dev/null) || {
        echo "$(_red "Error"): AgentSync engine not found." >&2
        exit 2
    }
    DEFAULT_REPO_ROOT="$(cd "$system_dir/.." && pwd)"

    PROJECT_CONFIG_PATH=""
    if [[ -f "$project_dir/.ai/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/.ai/agent_sync.yaml"
    elif [[ -f "$project_dir/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/agent_sync.yaml"
    fi

    export REPO_ROOT REPO_ROOT_CANONICAL DEFAULT_REPO_ROOT PROJECT_CONFIG_PATH
}

# Discover the agents/rules/skills/commands/subagents source root (project
# override → install template fallback). Sets SOURCE_<KEY> globals like sync.sh.
_adopt_discover_sources() {
    SOURCE_AGENTS=""
    SOURCE_RULES=""
    SOURCE_SKILLS=""
    SOURCE_COMMANDS=""
    SOURCE_SUBAGENTS=""

    if [[ -f "$REPO_ROOT/.ai/src/AGENTS.md" ]]; then
        SOURCE_AGENTS=".ai/src/AGENTS.md"
    elif [[ -f "$REPO_ROOT/.ai/AGENTS.md" ]]; then
        SOURCE_AGENTS=".ai/AGENTS.md"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/rules" ]]; then
        SOURCE_RULES=".ai/src/rules"
    elif [[ -d "$REPO_ROOT/.ai/rules" ]]; then
        SOURCE_RULES=".ai/rules"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/skills" ]]; then
        SOURCE_SKILLS=".ai/src/skills"
    elif [[ -d "$REPO_ROOT/.ai/skills" ]]; then
        SOURCE_SKILLS=".ai/skills"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/commands" ]]; then
        SOURCE_COMMANDS=".ai/src/commands"
    elif [[ -d "$REPO_ROOT/.ai/commands" ]]; then
        SOURCE_COMMANDS=".ai/commands"
    fi

    if [[ -d "$REPO_ROOT/.ai/src/agents" ]]; then
        SOURCE_SUBAGENTS=".ai/src/agents"
    elif [[ -d "$REPO_ROOT/.ai/agents" ]]; then
        SOURCE_SUBAGENTS=".ai/agents"
    fi
}

# Compute the dest abs path declared by a tool's targets.<key>.dest.
# Echoes empty if not declared. Always exits 0.
_adopt_dest_for() {
    local tool="$1"
    local key="$2"
    local raw
    raw=$(get_tool_value "$tool" "targets.$key.dest")
    [[ -z "$raw" ]] && { echo ""; return 0; }
    resolve_dest_path "$raw" "targets.$key.dest for $tool" 2>/dev/null
}

# Pick the source root for a directory-mode resource (rules/skills/commands/subagents).
# Honors targets.<key>.source override; falls back to global SOURCE_*.
_adopt_dir_source_root() {
    local tool="$1"
    local key="$2"
    local override fallback
    override=$(get_tool_value "$tool" "targets.$key.source")
    case "$key" in
        rules)     fallback="$SOURCE_RULES" ;;
        skills)    fallback="$SOURCE_SKILLS" ;;
        commands)  fallback="$SOURCE_COMMANDS" ;;
        subagents) fallback="$SOURCE_SUBAGENTS" ;;
        *)         fallback="" ;;
    esac
    local raw="${override:-$fallback}"
    [[ -z "$raw" ]] && { echo ""; return 0; }
    resolve_source_path "$raw" "targets.$key.source for $tool" 2>/dev/null
}

# Try to match a candidate dest against a single tool's outputs.
# Returns 0 on match (sets _ADOPT_* globals), 1 if no match for this tool.
_adopt_try_tool() {
    local tool="$1"
    local target_abs="$2"     # absolute dest path

    local tool_agents tool_rules tool_skills tool_commands tool_subagents
    local tool_settings tool_mcp tool_hooks
    tool_agents=$(_adopt_dest_for "$tool" "agents")
    tool_rules=$(_adopt_dest_for "$tool" "rules")
    tool_skills=$(_adopt_dest_for "$tool" "skills")
    tool_commands=$(_adopt_dest_for "$tool" "commands")
    tool_subagents=$(_adopt_dest_for "$tool" "subagents")
    tool_settings=$(_adopt_dest_for "$tool" "settings")
    tool_mcp=$(_adopt_dest_for "$tool" "mcp")
    tool_hooks=$(_adopt_dest_for "$tool" "hooks")

    # File targets — exact match.
    if [[ -n "$tool_agents" ]] && [[ "$target_abs" == "$tool_agents" ]]; then
        _ADOPT_TOOL="$tool"; _ADOPT_RESOURCE="agents"
        _adopt_resolve_agents_source "$tool"
        return 0
    fi
    if [[ -n "$tool_settings" ]] && [[ "$target_abs" == "$tool_settings" ]]; then
        _ADOPT_TOOL="$tool"; _ADOPT_RESOURCE="settings"
        _adopt_resolve_payload_target "$tool" "settings"
        return 0
    fi
    if [[ -n "$tool_mcp" ]] && [[ "$target_abs" == "$tool_mcp" ]]; then
        _ADOPT_TOOL="$tool"; _ADOPT_RESOURCE="mcp"
        _adopt_resolve_payload_target "$tool" "mcp"
        return 0
    fi
    if [[ -n "$tool_hooks" ]] && [[ "$target_abs" == "$tool_hooks" ]]; then
        _ADOPT_TOOL="$tool"; _ADOPT_RESOURCE="hooks"
        _adopt_resolve_payload_target "$tool" "hooks"
        return 0
    fi

    # Directory targets — dest must live inside.
    local key dir
    for key in rules skills commands subagents; do
        case "$key" in
            rules)     dir="$tool_rules" ;;
            skills)    dir="$tool_skills" ;;
            commands)  dir="$tool_commands" ;;
            subagents) dir="$tool_subagents" ;;
        esac
        [[ -z "$dir" ]] && continue
        if [[ "$target_abs" == "$dir/"* ]]; then
            _ADOPT_TOOL="$tool"; _ADOPT_RESOURCE="$key"
            _adopt_resolve_dir_source "$tool" "$key" "$dir"
            return 0
        fi
    done

    return 1
}

_adopt_resolve_agents_source() {
    local tool="$1"
    local override raw_rel
    override=$(get_tool_value "$tool" "targets.agents.source")
    raw_rel="${override:-$SOURCE_AGENTS}"
    if [[ -z "$raw_rel" ]]; then
        _ADOPT_REFUSAL="No agents source resolved for $tool — set source.agents in agent_sync.yaml or place AGENTS.md in .ai/src/."
        return 0
    fi
    if [[ "$raw_rel" != /* ]]; then
        _ADOPT_SOURCE_ABS="$REPO_ROOT/$raw_rel"
        _ADOPT_SOURCE_REL="$raw_rel"
    else
        _ADOPT_SOURCE_ABS="$raw_rel"
        _ADOPT_SOURCE_REL="${raw_rel#"$REPO_ROOT/"}"
    fi
}

# For settings/mcp/hooks, write into the canonical per-tool override path,
# unless an existing override already exists (any layout — we honor it).
# A user-declared targets.<resource>.source in the override YAML wins; the
# base YAML's declared path is treated as legacy and ignored at write time.
_adopt_resolve_payload_target() {
    local tool="$1"
    local resource="$2"

    local existing
    existing=$(_find_any_payload_override "$tool" "$resource")
    if [[ -n "$existing" ]]; then
        _ADOPT_SOURCE_ABS="$existing"
        _ADOPT_SOURCE_REL="${existing#"$REPO_ROOT/"}"
        return 0
    fi

    local user_file declared_user
    user_file=$(tool_resolver_user_file "$tool")
    if [[ -f "$user_file" ]]; then
        declared_user=$(parse_yaml_value "$user_file" "targets.${resource}.source")
        if [[ -n "$declared_user" ]]; then
            local declared_abs="$declared_user"
            [[ "$declared_abs" != /* ]] && declared_abs="$REPO_ROOT/$declared_user"
            if [[ "$declared_abs" == "$REPO_ROOT"/* ]]; then
                _ADOPT_SOURCE_ABS="$declared_abs"
                _ADOPT_SOURCE_REL="${declared_abs#"$REPO_ROOT/"}"
                return 0
            fi
        fi
    fi

    local canonical
    canonical=$(_payload_override_path "$tool" "$resource")
    if [[ -z "$canonical" ]]; then
        _ADOPT_REFUSAL="No base template for $tool $resource — cannot pick a canonical override path."
        return 0
    fi
    _ADOPT_SOURCE_ABS="$canonical"
    _ADOPT_SOURCE_REL="${canonical#"$REPO_ROOT/"}"
}

_adopt_resolve_dir_source() {
    local tool="$1"
    local key="$2"
    local dest_dir="$3"

    # Reject merged / inlined / format-converted variants up front.
    case "$key" in
        rules)
            local merge inline header scoped_header
            merge=$(get_tool_value "$tool" "targets.rules.merge_to_file")
            inline=$(get_tool_value "$tool" "targets.rules.inline_into_agents")
            header=$(get_tool_value "$tool" "targets.rules.header")
            scoped_header=$(get_tool_value "$tool" "targets.rules.scoped_header")
            if [[ "$merge" == "true" ]]; then
                _ADOPT_REFUSAL="$tool merges rules into a single file. Edit the source rules in $SOURCE_RULES/ instead."
                return 0
            fi
            if [[ "$inline" == "true" ]]; then
                _ADOPT_REFUSAL="$tool inlines rules into AGENTS.md. Edit the source rules in $SOURCE_RULES/ instead."
                return 0
            fi
            if [[ -n "$header" || -n "$scoped_header" ]]; then
                _ADOPT_REFUSAL="$tool injects a frontmatter header on sync. Adopting would propagate it to other tools' rule files. Edit $SOURCE_RULES/ instead."
                return 0
            fi
            ;;
        skills)
            local inline
            inline=$(get_tool_value "$tool" "targets.skills.inline_into_agents")
            if [[ "$inline" == "true" ]]; then
                _ADOPT_REFUSAL="$tool inlines a skill index into AGENTS.md. Edit $SOURCE_SKILLS/ instead."
                return 0
            fi
            ;;
        commands)
            local fmt
            fmt=$(get_tool_value "$tool" "targets.commands.format")
            if [[ "$fmt" == "toml" ]]; then
                _ADOPT_REFUSAL="$tool serializes commands as TOML. Conversion is not reversible — edit $SOURCE_COMMANDS/ instead."
                return 0
            fi
            ;;
        subagents)
            local fmt
            fmt=$(get_tool_value "$tool" "targets.subagents.format")
            if [[ "$fmt" == "toml" ]] || [[ "$fmt" == "amazonq_json" ]] || [[ "$fmt" == "opencode_md" ]]; then
                _ADOPT_REFUSAL="$tool serializes subagents as $fmt. Conversion is not reversible — edit $SOURCE_SUBAGENTS/ instead."
                return 0
            fi
            ;;
    esac

    local src_root
    src_root=$(_adopt_dir_source_root "$tool" "$key")
    if [[ -z "$src_root" ]]; then
        _ADOPT_REFUSAL="No source directory resolved for $tool $key."
        return 0
    fi

    # Map dest path inside dest_dir to source path inside src_root, restoring
    # the .md extension when the tool changed it (cursor: .mdc → .md).
    local rel_inside="${_ADOPT_DEST_ABS#"$dest_dir/"}"
    if [[ "$key" == "rules" ]] || [[ "$key" == "commands" ]] || [[ "$key" == "subagents" ]]; then
        local ext
        ext=$(get_tool_value "$tool" "targets.$key.extension")
        if [[ -n "$ext" ]] && [[ "$rel_inside" == *"$ext" ]]; then
            rel_inside="${rel_inside%"$ext"}.md"
        fi
    fi
    _ADOPT_SOURCE_ABS="$src_root/$rel_inside"
    _ADOPT_SOURCE_REL="${_ADOPT_SOURCE_ABS#"$REPO_ROOT/"}"
}

# Resolve the dest path provided by the user to a tool/resource/source mapping.
# Sets _ADOPT_* globals or _ADOPT_REFUSAL.
_adopt_resolve_dest() {
    local raw="$1"
    _ADOPT_TOOL=""
    _ADOPT_RESOURCE=""
    _ADOPT_DEST_REL=""
    _ADOPT_DEST_ABS=""
    _ADOPT_SOURCE_ABS=""
    _ADOPT_SOURCE_REL=""
    _ADOPT_REFUSAL=""

    local abs canonical
    abs=$(normalize_absolute_path "$raw")
    canonical=$(canonicalize_with_existing_ancestor "$abs") || {
        _ADOPT_REFUSAL="Cannot resolve path: $raw"
        return 0
    }

    if ! is_path_within_repo_root "$canonical"; then
        _ADOPT_REFUSAL="Path is outside the project: $raw"
        return 0
    fi

    if [[ ! -f "$abs" ]]; then
        _ADOPT_REFUSAL="Destination file not found: $raw"
        return 0
    fi

    _ADOPT_DEST_ABS="$abs"
    _ADOPT_DEST_REL="${abs#"$REPO_ROOT/"}"

    # Walk every tool that has a base or override (matches sync.sh's catalog).
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        if _adopt_try_tool "$t" "$_ADOPT_DEST_ABS"; then
            return 0
        fi
    done < <(list_all_tools)

    _ADOPT_REFUSAL="$_ADOPT_DEST_REL is not a recognised AgentSync output (no enabled tool produces it)."
}

# Drift-scan every tracked output and partition it into adoptable entries and a
# skip list. Requires manifest_load already run. Fills the _ADOPT_ALL_* arrays.
_adopt_collect_all() {
    _ADOPT_ALL_DEST_REL=(); _ADOPT_ALL_DEST_ABS=()
    _ADOPT_ALL_SRC_REL=();  _ADOPT_ALL_SRC_ABS=()
    _ADOPT_ALL_TOOL=();     _ADOPT_ALL_RES=(); _ADOPT_ALL_HASH=()
    _ADOPT_ALL_SKIP_REL=(); _ADOPT_ALL_SKIP_REASON=()

    manifest_check_drift

    local i rel cur_hash
    for ((i = 0; i < ${#SYNC_DRIFT_DETECTED[@]}; i++)); do
        rel="${SYNC_DRIFT_DETECTED[$i]}"
        _adopt_resolve_dest "$REPO_ROOT/$rel"
        if [[ -n "$_ADOPT_REFUSAL" ]]; then
            _ADOPT_ALL_SKIP_REL+=("$rel")
            _ADOPT_ALL_SKIP_REASON+=("$_ADOPT_REFUSAL")
            continue
        fi
        cur_hash=$(manifest_compute_hash "$_ADOPT_DEST_ABS") || {
            _ADOPT_ALL_SKIP_REL+=("$rel")
            _ADOPT_ALL_SKIP_REASON+=("cannot hash destination")
            continue
        }
        _ADOPT_ALL_DEST_REL+=("$_ADOPT_DEST_REL")
        _ADOPT_ALL_DEST_ABS+=("$_ADOPT_DEST_ABS")
        _ADOPT_ALL_SRC_REL+=("$_ADOPT_SOURCE_REL")
        _ADOPT_ALL_SRC_ABS+=("$_ADOPT_SOURCE_ABS")
        _ADOPT_ALL_TOOL+=("$_ADOPT_TOOL")
        _ADOPT_ALL_RES+=("$_ADOPT_RESOURCE")
        _ADOPT_ALL_HASH+=("$cur_hash")
    done

    _adopt_flag_source_conflicts
}

# Two edited outputs that resolve to the same source with different content
# would silently clobber each other. Flag every member of such a group as not-OK
# and divert it to the skip list, so the user adopts one explicitly.
_adopt_flag_source_conflicts() {
    _ADOPT_ALL_OK=()
    local n=${#_ADOPT_ALL_DEST_REL[@]}
    local i j ok
    for ((i = 0; i < n; i++)); do
        ok="true"
        for ((j = 0; j < n; j++)); do
            [[ $i -eq $j ]] && continue
            if [[ "${_ADOPT_ALL_SRC_ABS[$i]}" == "${_ADOPT_ALL_SRC_ABS[$j]}" ]] \
               && [[ "${_ADOPT_ALL_HASH[$i]}" != "${_ADOPT_ALL_HASH[$j]}" ]]; then
                ok="false"; break
            fi
        done
        _ADOPT_ALL_OK+=("$ok")
        if [[ "$ok" == "false" ]]; then
            _ADOPT_ALL_SKIP_REL+=("${_ADOPT_ALL_DEST_REL[$i]}")
            _ADOPT_ALL_SKIP_REASON+=("multiple edited outputs map to ${_ADOPT_ALL_SRC_REL[$i]} — adopt one explicitly")
        fi
    done
}

_adopt_all_render_plan() {
    local ok_count="$1"
    local n=${#_ADOPT_ALL_DEST_REL[@]}
    local i
    echo ""
    _bold "  Adopt plan (--all)"; echo ""
    if [[ $ok_count -gt 0 ]]; then
        echo "    $ok_count file(s) will be promoted to source:"; echo ""
        for ((i = 0; i < n; i++)); do
            [[ "${_ADOPT_ALL_OK[$i]}" == "true" ]] || continue
            printf '    %s  %s %s %s\n' \
                "$(_cyan "${_ADOPT_ALL_TOOL[$i]}")" \
                "$(_yellow "${_ADOPT_ALL_DEST_REL[$i]}")" \
                "$(_dim "→")" \
                "$(_green "${_ADOPT_ALL_SRC_REL[$i]}")"
        done
        echo ""
    fi
    local sn=${#_ADOPT_ALL_SKIP_REL[@]}
    if [[ $sn -gt 0 ]]; then
        echo "    $(_dim "$sn skipped (edit .ai/src/ directly):")"
        for ((i = 0; i < sn; i++)); do
            printf '    %s %s %s\n' \
                "$(_yellow "${_ADOPT_ALL_SKIP_REL[$i]}")" \
                "$(_dim "—")" \
                "$(_dim "${_ADOPT_ALL_SKIP_REASON[$i]}")"
        done
        echo ""
    fi
}

# Copy every OK entry dest → source and refresh its manifest hash.
_adopt_all_apply() {
    local n=${#_ADOPT_ALL_DEST_REL[@]}
    local i applied=0
    echo ""
    for ((i = 0; i < n; i++)); do
        [[ "${_ADOPT_ALL_OK[$i]}" == "true" ]] || continue
        ensure_dir "$(dirname "${_ADOPT_ALL_SRC_ABS[$i]}")"
        cp "${_ADOPT_ALL_DEST_ABS[$i]}" "${_ADOPT_ALL_SRC_ABS[$i]}"
        manifest_update_entry "${_ADOPT_ALL_DEST_REL[$i]}" "${_ADOPT_ALL_HASH[$i]}"
        echo "$(_green "✓") $(_dim "adopted") ${_ADOPT_ALL_SRC_REL[$i]}"
        applied=$((applied + 1))
    done
    echo ""
    echo "$(_green "✓") Adopted $applied file(s) into .ai/src/ and refreshed .ai/.sync-manifest"
    echo ""
    echo "$(_dim "Run") $(_cyan "agentsync sync") $(_dim "to verify everything is consistent.")"
}

# Orchestrate --all: collect drift → plan → confirm → apply.
_adopt_all() {
    local dry_run="$1"
    local assume_yes="$2"

    _adopt_collect_all

    local n=${#_ADOPT_ALL_DEST_REL[@]}
    local ok_count=0 i
    for ((i = 0; i < n; i++)); do
        [[ "${_ADOPT_ALL_OK[$i]}" == "true" ]] && ok_count=$((ok_count + 1))
    done
    local skip_count=${#_ADOPT_ALL_SKIP_REL[@]}

    if [[ $ok_count -eq 0 && $skip_count -eq 0 ]]; then
        echo "$(_dim "Nothing to adopt: every tracked output matches its source.")"
        return 0
    fi

    _adopt_all_render_plan "$ok_count"

    if [[ $ok_count -eq 0 ]]; then
        echo "$(_dim "No adoptable edits — the drifted files above need manual source edits.")"
        return 0
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "$(_dim "Dry-run — nothing written.")"
        return 0
    fi

    if [[ "$assume_yes" != "true" ]]; then
        if ! is_tty; then
            echo "$(_red "Error"): refusing to adopt non-interactively without --yes." >&2
            return 1
        fi
        if ! prompt_confirm "Apply these $ok_count adoption(s)?" "n"; then
            echo "$(_dim "Cancelled.")"
            return 0
        fi
    fi

    _adopt_all_apply
}

cmd_adopt() {
    local dry_run="false"
    local assume_yes="false"
    local adopt_all="false"
    local dest_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   dry_run="true"; shift ;;
            --yes|-y)    assume_yes="true"; shift ;;
            --all|-a)    adopt_all="true"; shift ;;
            --help|-h)
                cat << 'EOF'
Usage: agentsync adopt [--dry-run] [--yes] <dest-file>
       agentsync adopt --all [--dry-run] [--yes]

Promote a manual edit in a destination file back into .ai/src/ as the new
canonical content. Refuses transformed targets (merged rules, inlined skills,
format-converted commands/subagents).

With --all, adopt every drifted (manually-edited) tracked output at once,
skipping refused targets and same-source conflicts.

Options:
  --all,-a     Adopt every drifted output (no <dest-file>)
  --dry-run    Show the plan without writing
  --yes,-y     Skip confirmation (required outside a TTY)
EOF
                return 0
                ;;
            -*)
                echo "$(_red "Error"): unknown flag: $1" >&2
                return 2
                ;;
            *)
                if [[ -n "$dest_arg" ]]; then
                    echo "$(_red "Error"): adopt accepts a single destination file" >&2
                    return 2
                fi
                dest_arg="$1"
                shift
                ;;
        esac
    done

    if [[ "$adopt_all" == "true" && -n "$dest_arg" ]]; then
        echo "$(_red "Error"): adopt --all takes no <dest-file>" >&2
        return 2
    fi
    if [[ "$adopt_all" != "true" && -z "$dest_arg" ]]; then
        echo "$(_red "Error"): missing <dest-file>" >&2
        echo "Usage: agentsync adopt [--dry-run] [--yes] <dest-file>" >&2
        echo "       agentsync adopt --all [--dry-run] [--yes]" >&2
        return 2
    fi

    _adopt_prepare_context
    _adopt_discover_sources

    local mfile
    mfile=$(manifest_path)
    if [[ ! -f "$mfile" ]]; then
        echo "$(_red "Error"): no .ai/.sync-manifest yet — run 'agentsync sync' first." >&2
        return 1
    fi
    manifest_load

    if [[ "$adopt_all" == "true" ]]; then
        _adopt_all "$dry_run" "$assume_yes"
        return $?
    fi

    _adopt_resolve_dest "$dest_arg"
    if [[ -n "$_ADOPT_REFUSAL" ]]; then
        echo "$(_red "Cannot adopt"): $_ADOPT_REFUSAL" >&2
        return 1
    fi

    # Manifest-tracked guard.
    if ! manifest_lookup "$_ADOPT_DEST_REL" >/dev/null; then
        echo "$(_red "Cannot adopt"): $_ADOPT_DEST_REL is not tracked in the manifest." >&2
        echo "  AgentSync only adopts files it produced. Run sync first to register the file." >&2
        return 1
    fi

    # Already in sync? Nothing to do.
    local cur_hash old_hash
    cur_hash=$(manifest_compute_hash "$_ADOPT_DEST_ABS") || {
        echo "$(_red "Error"): cannot hash $_ADOPT_DEST_REL" >&2
        return 1
    }
    old_hash=$(manifest_lookup "$_ADOPT_DEST_REL" || echo "")
    if [[ "$cur_hash" == "$old_hash" ]] && [[ -f "$_ADOPT_SOURCE_ABS" ]]; then
        local src_hash
        src_hash=$(manifest_compute_hash "$_ADOPT_SOURCE_ABS" 2>/dev/null || echo "")
        if [[ "$src_hash" == "$cur_hash" ]]; then
            echo "$(_dim "Nothing to adopt: $_ADOPT_DEST_REL already matches the source.")"
            return 0
        fi
    fi

    # Plan summary.
    echo ""
    _bold "  Adopt plan"; echo ""
    echo "    $(_dim "tool:")     $(_cyan "$_ADOPT_TOOL")"
    echo "    $(_dim "resource:") $_ADOPT_RESOURCE"
    echo "    $(_dim "from:")     $(_yellow "$_ADOPT_DEST_REL") $(_dim "(destination — your edit)")"
    echo "    $(_dim "to:")       $(_green "$_ADOPT_SOURCE_REL") $(_dim "(source)")"
    echo ""

    if [[ ! -f "$_ADOPT_SOURCE_ABS" ]]; then
        echo "    $(_dim "(creating new source file)")"
        echo ""
    elif command -v diff >/dev/null 2>&1; then
        local diff_output
        diff_output=$(diff -u "$_ADOPT_SOURCE_ABS" "$_ADOPT_DEST_ABS" 2>/dev/null | head -n 40 || true)
        if [[ -n "$diff_output" ]]; then
            echo "$diff_output" | sed 's/^/    /'
            echo ""
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        echo "$(_dim "Dry-run — nothing written.")"
        return 0
    fi

    if [[ "$assume_yes" != "true" ]]; then
        if ! is_tty; then
            echo "$(_red "Error"): refusing to adopt non-interactively without --yes." >&2
            return 1
        fi
        if ! prompt_confirm "Apply this adoption?" "n"; then
            echo "$(_dim "Cancelled.")"
            return 0
        fi
    fi

    ensure_dir "$(dirname "$_ADOPT_SOURCE_ABS")"
    cp "$_ADOPT_DEST_ABS" "$_ADOPT_SOURCE_ABS"

    # Refresh manifest entry — the dest content is unchanged, but its hash now
    # represents the new canonical state, so the next sync sees no drift.
    manifest_update_entry "$_ADOPT_DEST_REL" "$cur_hash"

    echo ""
    _success_line() { echo "$(_green "✓") $1"; }
    _success_line "Wrote $_ADOPT_SOURCE_REL"
    _success_line "Updated .ai/.sync-manifest"
    echo ""
    echo "$(_dim "Run") $(_cyan "agentsync sync") $(_dim "to verify everything is consistent.")"
}
