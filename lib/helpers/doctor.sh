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
    else
        _doctor_warn "No agent_sync.yaml — using defaults only"
    fi
    echo ""

    # ── Section 2: enabled tools ─────────────────────────────────────────────
    _bold "  Enabled tools"; echo ""

    local enabled=""
    enabled=$(list_enabled_tools) || true

    if [[ -z "$enabled" ]]; then
        _doctor_info "No tools enabled — run $(_cyan "agentsync enable <tool>")"
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
