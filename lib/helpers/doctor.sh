#!/usr/bin/env bash
# agentsync doctor — validate project setup and surface actionable warnings.
#
# Exit codes:
#   0 — no problems (may still print info-level notes)
#   1 — warnings found (enabled tools without base, legacy flags, etc.)
#   2 — fatal setup problem (no .ai/, no config)

# shellcheck source=manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"
# shellcheck source=template_manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/template_manifest.sh"
# shellcheck source=format_conversion.sh
source "$(dirname "${BASH_SOURCE[0]}")/format_conversion.sh"
# shellcheck source=shared.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

_doctor_prepare_context() {
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

    tool_resolver_select_project_config 2
    tool_resolver_init_user_dir

    export REPO_ROOT REPO_ROOT_CANONICAL DEFAULT_REPO_ROOT PROJECT_CONFIG_PATH
}

DOCTOR_SOURCE_RAW=""
DOCTOR_SOURCE_ABS=""
DOCTOR_SOURCE_REFUSED=false
DOCTOR_SOURCE_UNTRUSTED=false

# Returns 0 when the project config points source.<key> outside the project,
# with the value in DOCTOR_SOURCE_RAW, its absolute path in DOCTOR_SOURCE_ABS,
# DOCTOR_SOURCE_REFUSED=true when sync would refuse that root, and
# DOCTOR_SOURCE_UNTRUSTED=true when AGENTSYNC_EXTERNAL_SOURCE_ROOTS does not list it.
_doctor_external_source() {
    local key="$1"
    DOCTOR_SOURCE_RAW=""
    DOCTOR_SOURCE_ABS=""
    DOCTOR_SOURCE_REFUSED=false
    DOCTOR_SOURCE_UNTRUSTED=false
    [[ -n "$PROJECT_CONFIG_PATH" ]] || return 1
    parse_yaml_value_r "$PROJECT_CONFIG_PATH" "source.$key"
    [[ -n "$REPLY" ]] || return 1
    local raw_path="$REPLY" root_status=0
    explicit_source_root_r "$raw_path" || root_status=$?
    [[ "$root_status" -ne 0 ]] || return 1
    [[ "$root_status" -eq 2 ]] && DOCTOR_SOURCE_REFUSED=true
    [[ "$root_status" -eq 3 ]] && DOCTOR_SOURCE_UNTRUSTED=true
    DOCTOR_SOURCE_RAW="$raw_path"
    source_abs_path_r "$raw_path"
    DOCTOR_SOURCE_ABS="$REPLY"
}

DOCTOR_WARNINGS=0
DOCTOR_ERRORS=0
DOCTOR_ADVISORIES=0

_doctor_ok()    { echo "    $(_green "✓") $1"; }
_doctor_warn()  { echo "    $(_yellow "⚠") $1"; DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)); }
_doctor_fail()  { echo "    $(_red "✗") $1"; DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1)); }
_doctor_info()  { echo "    $(_dim "·") $1"; }
# Soft warning — visually attention-grabbing but does NOT influence exit code.
# Use for techdebt detections (cross-project dupes, orphan output dirs, empty
# skills) that should be visible but must not fail CI in pre-commit hooks.
_doctor_advise() { echo "    $(_yellow "⚠") $1"; DOCTOR_ADVISORIES=$((DOCTOR_ADVISORIES + 1)); }

# ── Secret scanning ──────────────────────────────────────────────────────────
#
# Each entry: "label|regex". Regex is ERE-compatible (used by grep -E).
# Matches that look like common credential formats in MCP / settings files.
# Placeholders such as ${VAR} or <PLACEHOLDER> are excluded by the caller.
_DOCTOR_SECRET_PATTERNS=(
    "OpenAI/Anthropic key|sk-[A-Za-z0-9_-]{20,}"
    "GitHub PAT|ghp_[A-Za-z0-9]{30,}"
    "GitHub fine-grained PAT|github_pat_[A-Za-z0-9_]{30,}"
    "AWS access key|AKIA[0-9A-Z]{16}"
    "Slack token|xox[baprs]-[A-Za-z0-9-]{10,}"
    "Google API key|AIza[0-9A-Za-z_-]{35}"
    "JWT|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"
)

# Scan a single file for potential secrets. Prints one warning line per hit to
# stdout. Returns 0 on clean, 1 on any hit.
_doctor_scan_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local entry regex hits=0
    for entry in "${_DOCTOR_SECRET_PATTERNS[@]}"; do
        regex="${entry#*|}"
        # -E extended regex, -n line numbers, -I ignore binary.
        local matches
        matches=$(grep -EnI "$regex" "$file" 2>/dev/null || true)
        [[ -z "$matches" ]] && continue
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Skip lines that are clearly placeholders: ${VAR}, <VAR>, "..."
            [[ "$line" == *'${'*'}'* ]] && continue
            # Bare placeholder forms like <YOUR_KEY_HERE>.
            [[ "$line" == *'<'*'>'* ]] && [[ "$line" != *'sk-'* ]] && continue
            echo "$line"
            hits=$((hits + 1))
        done <<< "$matches"
        [[ $hits -gt 0 ]] && break  # one pattern is enough to fail the file
    done
    [[ $hits -eq 0 ]] && return 0 || return 1
}

# JSON syntax validator — uses python3 if available, node if not.
# Returns 0 on valid, 1 on invalid or missing tool.
_doctor_validate_json() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" >/dev/null 2>&1
        return $?
    elif command -v node >/dev/null 2>&1; then
        node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$file" >/dev/null 2>&1
        return $?
    fi
    # No validator available — treat as valid (noop) so doctor doesn't false-fail.
    return 0
}

# Run secret + JSON-syntax scan on a single payload file, updating hit/invalid
# counters by name-reference. Expects variables `hit_count` and `invalid_count`
# to exist in the caller's scope.
_doctor_scan_one_file() {
    local file="$1"
    local rel="${file#"$REPO_ROOT/"}"

    if [[ "$file" == *.json ]]; then
        if ! _doctor_validate_json "$file"; then
            _doctor_fail "$rel: invalid JSON syntax"
            invalid_count=$((invalid_count + 1))
            return 0
        fi
    fi

    local scan_output
    scan_output=$(_doctor_scan_file "$file") || true
    if [[ -n "$scan_output" ]]; then
        _doctor_fail "$rel: possible secret"
        local hit_line
        while IFS= read -r hit_line; do
            [[ -z "$hit_line" ]] && continue
            echo "        $(_dim "$hit_line")"
        done <<< "$scan_output"
        hit_count=$((hit_count + 1))
    fi
}

# Thin wrapper: print the checklist-style edit paths via the shared formatter.
_doctor_print_tool_edit_paths() {
    print_tool_edit_paths_checklist "$1"
}

# Compare each manifest entry to its current destination file.
# Reports clean/edited/missing per entry; warns on the latter two.
_doctor_check_drift() {
    local mfile
    mfile=$(manifest_path)
    if [[ ! -f "$mfile" ]]; then
        _doctor_info "No .sync-manifest yet — run $(_cyan "agentsync sync") to create it"
        return 0
    fi

    manifest_load

    if [[ ${#MANIFEST_KEYS[@]} -eq 0 ]]; then
        _doctor_info ".sync-manifest is empty"
        return 0
    fi

    local edited=0 missing=0 clean=0
    local i rel old_hash dest_abs cur_hash
    for ((i = 0; i < ${#MANIFEST_KEYS[@]}; i++)); do
        rel="${MANIFEST_KEYS[$i]}"
        old_hash="${MANIFEST_VALUES[$i]}"
        dest_abs="$REPO_ROOT/$rel"

        if [[ ! -f "$dest_abs" ]]; then
            _doctor_warn "$rel — missing (deleted manually)"
            missing=$((missing + 1))
            continue
        fi

        cur_hash=$(manifest_compute_hash "$dest_abs") || {
            _doctor_warn "$rel — could not hash"
            continue
        }

        if [[ "$cur_hash" != "$old_hash" ]]; then
            _doctor_warn "$rel — edited since last sync"
            edited=$((edited + 1))
        else
            clean=$((clean + 1))
        fi
    done

    if [[ $edited -eq 0 ]] && [[ $missing -eq 0 ]]; then
        _doctor_ok "All ${clean} tracked file(s) match the manifest"
    else
        echo ""
        local hint
        hint="    $(_dim "Re-run") $(_cyan "agentsync sync") $(_dim "to overwrite, or move edits into") $(_cyan ".ai/src/") $(_dim "first.")"
        echo "$hint"
    fi
}

_doctor_scan_overrides() {
    local overrides_root="$REPO_ROOT/.ai/src"
    local tools_root
    tools_root=$(tool_resolver_user_dir)
    local hit_count=0 invalid_count=0
    local legacy_count=0
    local resource file tool_dir

    # New per-tool layout (0.11+).
    if [[ -d "$tools_root" ]]; then
        for tool_dir in "$tools_root"/*/; do
            [[ -d "$tool_dir" ]] || continue
            for resource in mcp settings hooks; do
                for file in "$tool_dir${resource}".*; do
                    [[ -f "$file" ]] || continue
                    _doctor_scan_one_file "$file"
                done
            done
        done
    fi

    # Legacy flat layout (pre-0.11, deprecated).
    for resource in mcp settings hooks; do
        [[ -d "$overrides_root/$resource" ]] || continue
        for file in "$overrides_root/$resource"/*; do
            [[ -f "$file" ]] || continue
            legacy_count=$((legacy_count + 1))
            _doctor_scan_one_file "$file"
        done
    done

    if [[ $legacy_count -gt 0 ]]; then
        _doctor_warn "Legacy payload layout ($legacy_count file(s) under .ai/src/{hooks,mcp,settings}/). Run $(_cyan "agentsync migrate --apply") to move them to .ai/src/tools/<tool>/<resource>.<ext>."
    fi

    if [[ $hit_count -eq 0 ]] && [[ $invalid_count -eq 0 ]] && [[ $legacy_count -eq 0 ]]; then
        _doctor_info "No overrides to scan, or all clean."
    elif [[ $hit_count -gt 0 ]]; then
        echo ""
        _doctor_info "$(_yellow "Reminder"): use \${ENV_VAR} placeholders; never commit raw secrets."
    fi
}

# ── Per-tool config conflicts ────────────────────────────────────────────────
#
# `targets.commands.{dest, as_skills, inline_into_agents}` are mutually
# exclusive — sync picks dest first, then as_skills, then inline_into_agents.
# When the user mixes them, the lower-priority knob is silently ignored.
# Surface the conflict before it confuses the next sync.
_doctor_check_commands_config() {
    local tool="$1"
    local dest as_skills inline
    dest=$(get_tool_value "$tool" "targets.commands.dest")
    as_skills=$(get_tool_value "$tool" "targets.commands.as_skills")
    inline=$(get_tool_value "$tool" "targets.commands.inline_into_agents")

    if [[ -n "$dest" ]] && [[ "$as_skills" == "true" ]]; then
        _doctor_warn "$tool: targets.commands.dest and .as_skills both set — dest wins; remove one"
    fi
    if [[ -n "$dest" ]] && [[ "$inline" == "true" ]]; then
        _doctor_warn "$tool: targets.commands.dest and .inline_into_agents both set — dest wins; remove one"
    fi
    if [[ "$as_skills" == "true" ]] && [[ "$inline" == "true" ]]; then
        _doctor_warn "$tool: targets.commands.as_skills and .inline_into_agents both true — as_skills wins; remove one"
    fi

    if [[ "$as_skills" == "true" ]]; then
        local skills_dest
        skills_dest=$(get_tool_value "$tool" "targets.skills.dest")
        if [[ -z "$skills_dest" ]]; then
            _doctor_warn "$tool: targets.commands.as_skills requires targets.skills.dest — option will no-op"
        fi
    fi
    if [[ "$inline" == "true" ]]; then
        local agents_dest
        agents_dest=$(get_tool_value "$tool" "targets.agents.dest")
        if [[ -z "$agents_dest" ]]; then
            _doctor_warn "$tool: targets.commands.inline_into_agents requires targets.agents.dest — option will no-op"
        fi
    fi
}

# A guard script the tool never invokes is worse than none: it looks like
# protection. The base settings register it, so an override written before the
# guard shipped silently drops the registration.
_doctor_check_guard_wired() {
    local tool="$1"

    local guard_source
    guard_source=$(resolve_payload_source "$tool" "guard")
    [[ -n "$guard_source" ]] && [[ -f "$guard_source" ]] || return 0

    local guard_dest settings_dest
    get_tool_value_r "$tool" "targets.guard.dest"; guard_dest="$REPLY"
    get_tool_value_r "$tool" "targets.settings.dest"; settings_dest="$REPLY"
    [[ -n "$guard_dest" ]] && [[ -n "$settings_dest" ]] || return 0

    local settings_source
    settings_source=$(resolve_payload_source "$tool" "settings")
    [[ -n "$settings_source" ]] && [[ -f "$settings_source" ]] || return 0

    local guard_name="${guard_dest##*/}"
    if ! grep -qF "$guard_name" "$settings_source"; then
        _doctor_warn "$(tool_display_name "$tool"): $guard_dest is generated but ${settings_source#"$REPO_ROOT/"} never references it — the guard against edits to generated files is inert. Add the hooks block from the shipped base, or delete the override to inherit it."
    fi
}

_doctor_check_payload_ownership() {
    local tool="$1"
    if [[ "$tool" == "opencode" ]]; then
        local settings_source mcp_source rc
        settings_source=$(resolve_payload_source "$tool" "settings")
        mcp_source=$(resolve_payload_source "$tool" "mcp")
        if [[ -f "$settings_source" ]] && [[ -f "$mcp_source" ]]; then
            rc=0
            opencode_settings_has_mcp "$settings_source" || rc=$?
            if [[ $rc -eq 0 ]]; then
                _doctor_fail "OpenCode MCP ownership conflict: ${settings_source#"$REPO_ROOT/"} and ${mcp_source#"$REPO_ROOT/"} both define mcp. Move the canonical server map into one source."
            fi
        fi
    elif [[ "$tool" == "codex" ]]; then
        [[ "$(get_tool_bool "$tool" targets.mcp.enabled)" != false ]] || return 0
        local settings_source mcp_source
        settings_source=$(resolve_payload_source "$tool" settings)
        mcp_source=$(resolve_payload_source "$tool" mcp)
        if [[ -f "$mcp_source" ]] && ! codex_settings_allow_mcp "$settings_source"; then
            _doctor_fail "Codex MCP ownership conflict or ambiguous settings keys: keep MCP in one source."
        fi
    elif [[ "$tool" == "kimi" ]]; then
        local hook_source=""
        hook_source=$(_find_new_payload_override "$tool" "hooks")
        if [[ -z "$hook_source" ]]; then
            local candidate
            for candidate in "$REPO_ROOT/.ai/src/hooks/kimi".*; do
                [[ -f "$candidate" ]] || continue
                hook_source="$candidate"
                break
            done
        fi
        if [[ -n "$hook_source" ]]; then
            _doctor_advise "Kimi hooks are global-only in \$KIMI_CODE_HOME/config.toml; AgentSync leaves it untouched. Remove ${hook_source#"$REPO_ROOT/"} from project sources."
        fi
    fi
}

# ── Empty skill detection ────────────────────────────────────────────────────
#
# A skill is a directory under .ai/src/skills/<name>/ with a SKILL.md inside.
# A dir without SKILL.md is a no-op artefact — it lists nowhere, dispatches
# nothing, and clutters tree views. Warn so the user can either populate it
# or delete it.
_doctor_check_empty_skills() {
    local skills_dir="$REPO_ROOT/.ai/src/skills"
    if [[ ! -d "$skills_dir" ]]; then
        _doctor_info "No .ai/src/skills/ — nothing to scan."
        return 0
    fi

    local found=0
    local dir name
    for dir in "$skills_dir"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        if [[ ! -f "$dir/SKILL.md" ]]; then
            _doctor_advise "skills/$name/ — missing SKILL.md $(_dim "(empty skill — populate or remove)")"
            found=$((found + 1))
        fi
    done

    if [[ $found -eq 0 ]]; then
        _doctor_ok "All skill directories contain SKILL.md"
    else
        _doctor_info "$(_dim "Tip:") $(_cyan "agentsync simplify") $(_dim "can prune empty skill dirs.")"
    fi
}

# ── Always-on rule bloat (context dilution) ──────────────────────────────────
#
# Rules without `paths:` frontmatter load on every task. A large always-on set
# dilutes attention — agents start ignoring individual instructions. Advise
# scoping domain rules with `paths:` once the always-on set grows past ~5k tokens.
_doctor_check_always_on_rules() {
    local rules_dir="$REPO_ROOT/.ai/src/rules"
    if [[ ! -d "$rules_dir" ]]; then
        _doctor_info "No .ai/src/rules/ — nothing to scan."
        return 0
    fi

    local count=0 bytes=0 file first
    for file in "$rules_dir"/*.md; do
        [[ -f "$file" ]] || continue
        IFS= read -r first < "$file" || true
        if [[ "$first" == "---" ]] && sed -n '2,/^---$/p' "$file" | grep -q '^paths:[[:space:]]*$'; then
            continue
        fi
        count=$((count + 1))
        bytes=$((bytes + $(wc -c < "$file")))
    done

    if [[ $count -eq 0 ]]; then
        _doctor_ok "No always-on rules (every rule is paths:-scoped)"
    elif [[ $bytes -ge 20000 ]]; then
        _doctor_advise "$count always-on rule(s) load on every task (~$((bytes / 1024)) KB, ~$((bytes / 4)) tokens). Add $(_cyan "paths:") frontmatter to domain rules so they load only when matching files are touched — a large always-on set dilutes attention."
    else
        _doctor_ok "Always-on rule context is lean ($count file(s), ~$((bytes / 1024)) KB)"
    fi
}

# ── Orphan tool-output detection ─────────────────────────────────────────────
#
# Known output dir basenames mapped to their owning tool slug. AgentSync's
# cleanup only sweeps paths it wrote in the current sync; legacy directories
# from older versions, or output dirs left behind after a tool was disabled,
# survive indefinitely. Doctor surfaces them so the user can decide whether
# to keep, remove, or re-enable the tool.
#
_DOCTOR_OUTPUT_DIR_MAP=(
    ".claude|claude"
    ".cursor|cursor"
    ".codex|codex"
    ".kimi-code|kimi"
    ".opencode|opencode"
    ".windsurf|windsurf"
    ".gemini|gemini"
    ".junie|junie"
    ".cline|cline"
    ".amazonq|amazonq"
    ".zed|zed"
    ".agents|codex"
)

_doctor_check_orphan_outputs() {
    local enabled=""
    # NB: capture-then-|| pattern; never `enabled=$(cmd) || enabled=""`,
    # since the OR branch clobbers stdout the substitution already captured
    # when `cmd` exits non-zero (list_enabled_tools tail-returns the last
    # test's exit code under set -e).
    enabled=$(list_enabled_tools) || true

    local _enabled_set="|"
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        _enabled_set="${_enabled_set}${t}|"
    done <<< "$enabled"

    local found=0

    if [[ -d "$REPO_ROOT/.agent" ]]; then
        _doctor_advise ".agent/ — legacy pre-v0.6 layout (run $(_cyan "agentsync migrate --legacy") to preview cleanup)"
        found=$((found + 1))
    fi

    local entry dir tool
    for entry in "${_DOCTOR_OUTPUT_DIR_MAP[@]}"; do
        dir="${entry%%|*}"
        tool="${entry#*|}"
        [[ -d "$REPO_ROOT/$dir" ]] || continue
        # `.agents/` is shared by multiple tools (codex skills, Antigravity output);
        # only flag it if NO tool that uses it is enabled.
        if [[ "$dir" == ".agents" ]]; then
            [[ "$_enabled_set" == *"|codex|"* ]] && continue
            [[ "$_enabled_set" == *"|antigravity|"* ]] && continue
        fi
        if [[ "$_enabled_set" != *"|${tool}|"* ]]; then
            _doctor_advise "$dir/ — orphan (tool '$tool' not enabled; output left from prior run)"
            found=$((found + 1))
        fi
    done

    if [[ $found -eq 0 ]]; then
        _doctor_ok "No orphan tool-output directories"
    fi
}

# ── Cross-project duplicate detection ────────────────────────────────────────
#
# When this project is nested under another AgentSync project, source files
# duplicated between parent and child waste tokens (Claude Code loads both)
# and drift independently. Doctor compares file hashes for shared paths under
# rules/, skills/, commands/, agents/ and flags identical copies as dupes
# (review and remove from child) and divergent copies as "intentional" (worth
# eyeballing once to confirm).
#
# Parent resolution: an explicit `shared.path` in agent_sync.yaml wins over
# walk-up. Walk-up is git-boundary-bounded so auto-detection never compares
# unrelated repos; `shared.path` is the user saying "this *is* my parent" and
# must work the same way the overlay does at sync time — across repos.
# Walk-up stops at the first parent .ai/src/ found or the git boundary,
# whichever comes first — see find_parent_ai_src in paths.sh.
_doctor_check_cross_project() {
    local child_src="$REPO_ROOT/.ai/src"
    if [[ ! -d "$child_src" ]]; then
        _doctor_info "No .ai/src/ in this project — skipping cross-project scan."
        return 0
    fi

    local parent_src=""
    local parent_origin=""
    parent_src=$(shared_parent_src 2>/dev/null) || parent_src=""
    if [[ -n "$parent_src" ]]; then
        parent_origin="shared"
    else
        parent_src=$(find_parent_ai_src "$REPO_ROOT" 2>/dev/null) || parent_src=""
        [[ -n "$parent_src" ]] && parent_origin="walk"
    fi
    if [[ -z "$parent_src" ]]; then
        _doctor_info "No parent .ai/src/ found within git boundary."
        return 0
    fi

    local origin_hint=""
    [[ "$parent_origin" == "shared" ]] && origin_hint=" $(_dim "(from shared.path)")"
    _doctor_info "Parent source: $(_dim "${parent_src}")${origin_hint}"
    echo ""

    local dupe_count=0 divergent_count=0
    local rel child_file parent_file ch ph

    local cat
    for cat in rules commands agents; do
        local pdir="$parent_src/$cat"
        [[ -d "$pdir" ]] || continue
        local f
        for f in "$pdir"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            child_file="$child_src/$rel"
            [[ -f "$child_file" ]] || continue
            parent_file="$f"
            ch=$(template_manifest_hash "$child_file") || continue
            ph=$(template_manifest_hash "$parent_file") || continue
            if [[ "$ch" == "$ph" ]]; then
                local hint=""
                if shared_inherits_category "$cat"; then
                    hint=" $(_dim "(inherited via shared: — safe to delete)")"
                fi
                _doctor_advise "$rel — duplicate of parent's $(_dim "${parent_file#"$(dirname "$parent_src")/"}")$hint"
                dupe_count=$((dupe_count + 1))
            else
                local pcat
                pcat=$(read_frontmatter_field "$parent_file" "category")
                if [[ "$pcat" == "governance" ]]; then
                    _doctor_advise "$rel — $(_yellow "governance file diverges from parent") $(_dim "(category: governance — likely a mistake, not an override)")"
                else
                    _doctor_info "$rel — diverges from parent $(_dim "(review intent)")"
                fi
                divergent_count=$((divergent_count + 1))
            fi
        done
    done

    # Skills: nested layout, walk recursively.
    if [[ -d "$parent_src/skills" ]]; then
        local fpath
        while IFS= read -r -d '' fpath; do
            rel="${fpath#"$parent_src/"}"
            child_file="$child_src/$rel"
            [[ -f "$child_file" ]] || continue
            ch=$(template_manifest_hash "$child_file") || continue
            ph=$(template_manifest_hash "$fpath") || continue
            if [[ "$ch" == "$ph" ]]; then
                local hint=""
                if shared_inherits_category "skills"; then
                    hint=" $(_dim "(inherited via shared: — safe to delete)")"
                fi
                _doctor_advise "$rel — duplicate of parent's $(_dim "${fpath#"$(dirname "$parent_src")/"}")$hint"
                dupe_count=$((dupe_count + 1))
            else
                local pcat
                pcat=$(read_frontmatter_field "$fpath" "category")
                if [[ "$pcat" == "governance" ]]; then
                    _doctor_advise "$rel — $(_yellow "governance file diverges from parent") $(_dim "(category: governance — likely a mistake, not an override)")"
                else
                    _doctor_info "$rel — diverges from parent $(_dim "(review intent)")"
                fi
                divergent_count=$((divergent_count + 1))
            fi
        done < <(find "$parent_src/skills" -type f ! -name '.*' -print0 2>/dev/null | LC_ALL=C sort -z)
    fi

    if [[ $dupe_count -eq 0 ]] && [[ $divergent_count -eq 0 ]]; then
        _doctor_ok "No source files shared with parent."
    elif [[ $dupe_count -gt 0 ]]; then
        echo ""
        _doctor_info "$(_dim "Run") $(_cyan "agentsync dedupe") $(_dim "to remove duplicates interactively.")"
    fi
}

cmd_doctor() {
    _doctor_prepare_context

    DOCTOR_WARNINGS=0
    DOCTOR_ERRORS=0
    DOCTOR_ADVISORIES=0

    echo ""
    _bold "  AgentSync Doctor"; echo ""
    _dim "  $REPO_ROOT"; echo ""
    echo ""

    # ── Section 1: project layout ────────────────────────────────────────────
    _bold "  Project layout"; echo ""
    if [[ -d "$REPO_ROOT/.ai" ]]; then
        _doctor_ok ".ai/ directory present"
    else
        _doctor_fail ".ai/ directory missing — run 'agentsync init'"
        echo ""
        return 2
    fi

    local agents_found=false
    if _doctor_external_source agents; then
        [[ -f "$DOCTOR_SOURCE_ABS" ]] && agents_found=true
    elif [[ -f "$REPO_ROOT/.ai/src/AGENTS.md" ]] || [[ -f "$REPO_ROOT/.ai/AGENTS.md" ]]; then
        agents_found=true
    fi
    if [[ "$agents_found" == "true" ]]; then
        _doctor_ok "AGENTS.md source file found"
    else
        _doctor_fail "No AGENTS.md in .ai/src/ or .ai/ — sync will fail"
    fi

    if [[ -n "$PROJECT_CONFIG_PATH" ]]; then
        _doctor_ok "Project config: $(_dim "${PROJECT_CONFIG_PATH#"$REPO_ROOT/"}")"

        # Version pinning: warn if the config was scaffolded with a different CLI.
        local pinned_version
        pinned_version=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "agentsync_version" 2>/dev/null || true)
        pinned_version="${pinned_version//\"/}"
        if [[ -n "$pinned_version" ]] && [[ -n "${VERSION:-}" ]] && [[ "$pinned_version" != "$VERSION" ]]; then
            _doctor_warn "CLI version $(_dim "v$VERSION") differs from pinned $(_dim "v$pinned_version") — run $(_cyan "agentsync upgrade-config") to align"
        fi

        # Project format: a pending migration means the engine ships content or
        # layout this project has not adopted yet.
        if declare -F engine_format >/dev/null 2>&1; then
            local engine_rev project_rev
            engine_rev=$(engine_format "$DEFAULT_REPO_ROOT/lib")
            project_rev=$(project_format "$PROJECT_CONFIG_PATH")
            if [[ "$project_rev" -lt "$engine_rev" ]]; then
                _doctor_warn "Project format $(_dim "r$project_rev") is behind the engine $(_dim "r$engine_rev") — run $(_cyan "agentsync migrate") to preview"
            else
                _doctor_ok "Project format: $(_dim "r$project_rev")"
            fi
        fi
    else
        _doctor_warn "No agent_sync.yaml — using defaults only"
    fi
    echo ""

    # ── Section 2: enabled tools ─────────────────────────────────────────────
    _bold "  Enabled tools"; echo ""

    local enabled=""
    enabled=$(list_enabled_tools) || true

    if [[ -z "$enabled" ]]; then
        _doctor_info "No tools enabled — run $(_cyan "agentsync enable <slug>")"
    else
        local tool base_file user_file
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            base_file=$(tool_resolver_base_file "$tool")
            user_file=$(tool_resolver_user_file "$tool")

            if [[ -f "$base_file" ]]; then
                if [[ -f "$user_file" ]]; then
                    _doctor_ok "$(tool_display_name "$tool") $(_dim "(customized)")"
                else
                    _doctor_ok "$(tool_display_name "$tool")"
                fi
            elif [[ -f "$user_file" ]]; then
                _doctor_warn "$tool: custom tool (no base) — ensure override defines full config"
            else
                _doctor_fail "$tool: unknown — no base template and no override"
            fi
            _doctor_check_commands_config "$tool"
            _doctor_check_payload_ownership "$tool"
            _doctor_check_guard_wired "$tool"
        done <<< "$enabled"
    fi
    echo ""

    # ── Section 2b: edit paths for enabled tools ─────────────────────────────
    if [[ -n "$enabled" ]]; then
        _bold "  Edit paths"; echo ""
        local any_edit=false
        local edit_tool
        while IFS= read -r edit_tool; do
            [[ -z "$edit_tool" ]] && continue
            # Skip tools we already flagged as unknown — nothing actionable.
            if ! tool_exists "$edit_tool"; then
                continue
            fi
            _doctor_print_tool_edit_paths "$edit_tool"
            any_edit=true
        done <<< "$enabled"
        [[ "$any_edit" == "false" ]] && _doctor_info "No tools with editable payloads."
        echo ""
    fi

    # ── Section 3: user overrides ────────────────────────────────────────────
    _bold "  User overrides"; echo ""
    local overrides=""
    overrides=$(list_user_override_tools) || true

    if [[ -z "$overrides" ]]; then
        _doctor_info "No customizations — all tools inherit fully from base"
    else
        local tool user_file legacy_enabled
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            user_file=$(tool_resolver_user_file "$tool")
            legacy_enabled=$(parse_yaml_value "$user_file" "enabled")

            if [[ "$legacy_enabled" == "true" ]] && ! grep -qxF "$tool" <<<"$(list_configured_enabled_tools)"; then
                _doctor_warn "$tool: uses legacy 'enabled: true' — migrate with $(_cyan "agentsync enable $tool")"
            elif [[ -f "$(tool_resolver_base_file "$tool")" ]]; then
                _doctor_info "$(tool_display_name "$tool") — see $(_cyan "agentsync diff $tool")"
            else
                _doctor_info "$tool (custom tool, no base)"
            fi
        done <<< "$overrides"
    fi
    echo ""

    # ── Section 4: source directories ────────────────────────────────────────
    _bold "  Source directories"; echo ""
    local missing=0
    local src source_key display source_abs
    for src in AGENTS.md rules skills commands agents; do
        case "$src" in
            AGENTS.md) source_key="agents" ;;
            agents)    source_key="subagents" ;;
            *)         source_key="$src" ;;
        esac
        if _doctor_external_source "$source_key"; then
            display="$DOCTOR_SOURCE_RAW"
            source_abs="$DOCTOR_SOURCE_ABS"
            if [[ "$DOCTOR_SOURCE_REFUSED" == "true" ]]; then
                _doctor_fail "source.$source_key must not be the filesystem root, the home directory, or the project root or its ancestor: $display"
                continue
            fi
            if [[ "$DOCTOR_SOURCE_UNTRUSTED" == "true" ]]; then
                _doctor_fail "source.$source_key points outside the project and AGENTSYNC_EXTERNAL_SOURCE_ROOTS does not list it: $display"
                continue
            fi
        else
            display=".ai/src/$src"
            source_abs="$REPO_ROOT/.ai/src/$src"
        fi
        if [[ -e "$source_abs" ]]; then
            _doctor_ok "$display"
        else
            case "$src" in
                AGENTS.md) _doctor_fail "$display missing (required)"; missing=$((missing+1)) ;;
                *)         _doctor_info "$display not present (optional)" ;;
            esac
        fi
    done
    echo ""

    # ── Section 5: drift ─────────────────────────────────────────────────────
    _bold "  Drift"; echo ""
    _doctor_check_drift
    echo ""

    # ── Section 6: security scan ─────────────────────────────────────────────
    _bold "  Security"; echo ""
    _doctor_scan_overrides
    echo ""

    # ── Section 7: empty skills ──────────────────────────────────────────────
    _bold "  Skills"; echo ""
    _doctor_check_empty_skills
    echo ""

    # ── Section 7b: always-on rule context ───────────────────────────────────
    _bold "  Rules"; echo ""
    _doctor_check_always_on_rules
    echo ""

    # ── Section 8: orphan tool outputs ───────────────────────────────────────
    _bold "  Tool outputs"; echo ""
    _doctor_check_orphan_outputs
    echo ""

    # ── Section 9: cross-project duplicates ──────────────────────────────────
    _bold "  Cross-project"; echo ""
    _doctor_check_cross_project
    echo ""

    # ── Summary ──────────────────────────────────────────────────────────────
    # Exit codes: errors fail (2), real warnings fail (1), advisories never
    # affect exit code — they are techdebt nudges and must not break CI for
    # users who run `doctor` in pre-commit / pipeline contexts.
    log_separator_doctor
    local adv_label=""
    if [[ $DOCTOR_ADVISORIES -gt 0 ]]; then
        adv_label=", $(_dim "$DOCTOR_ADVISORIES advisory(ies)")"
    fi
    if [[ $DOCTOR_ERRORS -gt 0 ]]; then
        echo "  $(_red "$DOCTOR_ERRORS error(s)"), $(_yellow "$DOCTOR_WARNINGS warning(s)")$adv_label"
        echo ""
        return 2
    elif [[ $DOCTOR_WARNINGS -gt 0 ]]; then
        echo "  $(_green "OK") with $(_yellow "$DOCTOR_WARNINGS warning(s)")$adv_label"
        echo ""
        return 1
    elif [[ $DOCTOR_ADVISORIES -gt 0 ]]; then
        echo "  $(_green "OK") with $(_dim "$DOCTOR_ADVISORIES advisory(ies)")"
        echo ""
        return 0
    else
        echo "  $(_green "All checks passed.")"
        echo ""
        return 0
    fi
}

log_separator_doctor() {
    # GNU tr maps single bytes, so `tr ' ' '─'` garbles the rule on Linux.
    local rule
    printf -v rule '─%.0s' {1..60}
    echo "  $rule"
}
