#!/usr/bin/env bash
# agentsync doctor — validate project setup and surface actionable warnings.
#
# Exit codes:
#   0 — no problems (may still print info-level notes)
#   1 — warnings found (enabled tools without base, legacy flags, etc.)
#   2 — fatal setup problem (no .ai/, no config)

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

    PROJECT_CONFIG_PATH=""
    if [[ -f "$project_dir/.ai/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/.ai/agent_sync.yaml"
    elif [[ -f "$project_dir/agent_sync.yaml" ]]; then
        PROJECT_CONFIG_PATH="$project_dir/agent_sync.yaml"
    fi

    export REPO_ROOT REPO_ROOT_CANONICAL DEFAULT_REPO_ROOT PROJECT_CONFIG_PATH
}

DOCTOR_WARNINGS=0
DOCTOR_ERRORS=0

_doctor_ok()    { echo "    $(_green "✓") $1"; }
_doctor_warn()  { echo "    $(_yellow "⚠") $1"; DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)); }
_doctor_fail()  { echo "    $(_red "✗") $1"; DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1)); }
_doctor_info()  { echo "    $(_dim "·") $1"; }

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

    local entry label regex hits=0
    for entry in "${_DOCTOR_SECRET_PATTERNS[@]}"; do
        label="${entry%%|*}"
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

_doctor_scan_overrides() {
    local overrides_root="$REPO_ROOT/.ai/src"
    local hit_count=0 invalid_count=0
    local legacy_count=0
    local resource file tool_dir

    # New per-tool layout (0.11+).
    if [[ -d "$overrides_root/tools" ]]; then
        for tool_dir in "$overrides_root/tools"/*/; do
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
        _doctor_warn "Legacy payload layout ($legacy_count file(s) under .ai/src/{hooks,mcp,settings}/) — canonical path is .ai/src/tools/<tool>/<resource>.<ext>. Re-run $(_cyan "agentsync customize <tool> <resource>") per file to migrate inline."
    fi

    if [[ $hit_count -eq 0 ]] && [[ $invalid_count -eq 0 ]] && [[ $legacy_count -eq 0 ]]; then
        _doctor_info "No overrides to scan, or all clean."
    elif [[ $hit_count -gt 0 ]]; then
        echo ""
        _doctor_info "$(_yellow "Reminder"): use \${ENV_VAR} placeholders; never commit raw secrets."
    fi
}

cmd_doctor() {
    _doctor_prepare_context

    DOCTOR_WARNINGS=0
    DOCTOR_ERRORS=0

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

    if [[ -f "$REPO_ROOT/.ai/src/AGENTS.md" ]] || [[ -f "$REPO_ROOT/.ai/AGENTS.md" ]]; then
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
        done <<< "$enabled"
    fi
    echo ""

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
    local src
    for src in AGENTS.md rules skills commands agents; do
        if [[ -e "$REPO_ROOT/.ai/src/$src" ]]; then
            _doctor_ok ".ai/src/$src"
        else
            case "$src" in
                AGENTS.md) _doctor_fail ".ai/src/$src missing (required)"; missing=$((missing+1)) ;;
                *)         _doctor_info ".ai/src/$src not present (optional)" ;;
            esac
        fi
    done
    echo ""

    # ── Section 5: security scan ─────────────────────────────────────────────
    _bold "  Security"; echo ""
    _doctor_scan_overrides
    echo ""

    # ── Summary ──────────────────────────────────────────────────────────────
    log_separator_doctor
    if [[ $DOCTOR_ERRORS -gt 0 ]]; then
        echo "  $(_red "$DOCTOR_ERRORS error(s)"), $(_yellow "$DOCTOR_WARNINGS warning(s)")"
        echo ""
        return 2
    elif [[ $DOCTOR_WARNINGS -gt 0 ]]; then
        echo "  $(_green "OK") with $(_yellow "$DOCTOR_WARNINGS warning(s)")"
        echo ""
        return 1
    else
        echo "  $(_green "All checks passed.")"
        echo ""
        return 0
    fi
}

log_separator_doctor() {
    local width=60
    printf '  %*s\n' "$width" '' | tr ' ' '─'
}
