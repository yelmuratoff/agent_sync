#!/usr/bin/env bash
# agentsync init — scaffolds the .ai/ directory in a project.
#
# Model (new):
#   - Tool configs are NOT copied to .ai/src/tools/. They live in the install-dir
#     base and are referenced via tools.enabled list in agent_sync.yaml. Users
#     create per-tool override files only when they want to customize.
#   - init auto-detects common tool markers in the repo and pre-fills tools.enabled.
#   - Source content (AGENTS.md, rules, skills, commands, agents) is still scaffolded.

# ── Private helpers ───────────────────────────────────────────────────────────

_init_create_directories() {
    local ai_dir="$1"
    mkdir -p "$ai_dir/src/rules"
    mkdir -p "$ai_dir/src/skills"
    mkdir -p "$ai_dir/src/commands"
    mkdir -p "$ai_dir/src/agents"
    mkdir -p "$ai_dir/src/settings"
    mkdir -p "$ai_dir/src/mcp"
    mkdir -p "$ai_dir/src/hooks"
    # tools/ is intentionally NOT created — created on demand by `customize`.
}

_init_copy_source_templates() {
    local ai_dir="$1"
    local templates_dir="$2"

    if [[ -n "$templates_dir" ]]; then
        [[ -f "$templates_dir/AGENTS.md" ]] && cp "$templates_dir/AGENTS.md" "$ai_dir/src/AGENTS.md"

        for rule_file in "$templates_dir/rules/"*.md; do
            [[ -f "$rule_file" ]] || continue
            cp "$rule_file" "$ai_dir/src/rules/"
        done

        for skill_dir in "$templates_dir/skills/"*/; do
            [[ -d "$skill_dir" ]] || continue
            local skill_name
            skill_name=$(basename "$skill_dir")
            mkdir -p "$ai_dir/src/skills/$skill_name"
            cp "$skill_dir"* "$ai_dir/src/skills/$skill_name/" 2>/dev/null || true
        done

        if [[ -d "$templates_dir/commands" ]]; then
            for cmd_file in "$templates_dir/commands/"*.md; do
                [[ -f "$cmd_file" ]] || continue
                cp "$cmd_file" "$ai_dir/src/commands/"
            done
        fi

        if [[ -d "$templates_dir/agents" ]]; then
            for agent_file in "$templates_dir/agents/"*.md; do
                [[ -f "$agent_file" ]] || continue
                cp "$agent_file" "$ai_dir/src/agents/"
            done
        fi

        if [[ -d "$templates_dir/settings" ]]; then
            for settings_file in "$templates_dir/settings/"*; do
                [[ -f "$settings_file" ]] || continue
                cp "$settings_file" "$ai_dir/src/settings/"
            done
        fi

        if [[ -d "$templates_dir/mcp" ]]; then
            for mcp_file in "$templates_dir/mcp/"*; do
                [[ -f "$mcp_file" ]] || continue
                cp "$mcp_file" "$ai_dir/src/mcp/"
            done
        fi

        if [[ -d "$templates_dir/hooks" ]]; then
            for hooks_file in "$templates_dir/hooks/"*; do
                [[ -f "$hooks_file" ]] || continue
                cp "$hooks_file" "$ai_dir/src/hooks/"
            done
        fi
    else
        cat > "$ai_dir/src/AGENTS.md" << 'AGENTS_EOF'
# Project Agent

You are a senior software engineer working on this project. You write clean, correct, and maintainable code.

## Approach

1. **Understand** — Read existing code. Ask questions on ambiguities.
2. **Plan** — Break work into concrete steps.
3. **Implement** — Follow established project patterns. Handle errors explicitly.
4. **Verify** — Run tests, linter, and formatter.

## Principles

- Readability over cleverness. Explicit over implicit.
- Change what's needed, nothing more.
- Test what matters. No hardcoded secrets.
AGENTS_EOF

        cat > "$ai_dir/src/rules/core.md" << 'RULE_EOF'
# Core Rules

- Follow the project's established conventions and patterns.
- Prefer readability over cleverness.
- Handle errors explicitly. Don't swallow exceptions.
- Write tests for business logic and error paths.
- Never hardcode secrets, API keys, or credentials.
RULE_EOF
    fi
}

# Detect which tools are already used in the current project by looking
# for well-known filesystem markers. Prints one tool name per line.
_init_detect_enabled_tools() {
    local root="$1"

    # Each entry: "tool_name|check1|check2|..."
    # Presence of ANY listed marker triggers detection.
    local -a detectors=(
        "claude|$root/.claude|$root/CLAUDE.md"
        "cursor|$root/.cursor|$root/.cursorrules"
        "copilot|$root/.github/copilot-instructions.md|$root/.github/instructions|$root/.github/prompts"
        "gemini|$root/.gemini|$root/GEMINI.md"
        "codex|$root/.codex|$root/AGENTS.md"
        "windsurf|$root/.windsurf|$root/.windsurfrules"
        "junie|$root/.junie"
        "aider|$root/CONVENTIONS.md|$root/.aider.conf.yml"
        "cline|$root/.clinerules"
        "amazonq|$root/.amazonq"
        "augment|$root/.augment"
        "zed|$root/.zed|$root/.rules"
        "continue|$root/.continue|$root/.continuerules"
        "antigravity|$root/.antigravity"
    )

    local entry tool marker IFS_BAK="$IFS"
    for entry in "${detectors[@]}"; do
        IFS='|' read -ra parts <<< "$entry"
        tool="${parts[0]}"
        local i=1
        while [[ $i -lt ${#parts[@]} ]]; do
            marker="${parts[$i]}"
            if [[ -e "$marker" ]]; then
                echo "$tool"
                break
            fi
            i=$((i + 1))
        done
    done
    IFS="$IFS_BAK"
}

_init_create_project_config() {
    local target_dir="$1"
    local enabled_list="$2"  # newline-separated tool names (may be empty)
    local config_file="$target_dir/.ai/agent_sync.yaml"

    if [[ -f "$config_file" ]] || [[ -f "$target_dir/agent_sync.yaml" ]]; then
        return 0
    fi

    {
        cat << 'HEAD'
# AgentSync — Project Configuration
# All keys are optional — remove any that you leave at the default.

# Tools: which ones to sync for this project.
# Each name must match a base tool (see `agentsync list`) or a custom override
# file under .ai/src/tools/<name>.yaml.
tools:
HEAD
        if [[ -z "$enabled_list" ]]; then
            echo "  enabled: []"
        else
            echo "  enabled:"
            while IFS= read -r t; do
                [[ -z "$t" ]] && continue
                echo "    - $t"
            done <<< "$enabled_list"
        fi
        cat << 'TAIL'

# Source paths (override if you use a custom layout).
source:
  agents: ".ai/src/AGENTS.md"
  rules: ".ai/src/rules"
  skills: ".ai/src/skills"
  commands: ".ai/src/commands"
  subagents: ".ai/src/agents"
  tools: ".ai/src/tools"

# Global defaults applied to all tools.
defaults:
  enabled: false
  cleanup: true

# Post-sync hook execution (also controllable via env vars).
post_sync:
  allow: false
  skip: false

# .gitignore management.
gitignore:
  update: true
TAIL
    } > "$config_file"
}

_init_print_summary() {
    local ai_dir="$1"
    local enabled_list="$2"

    echo ""
    echo "   Created $(_cyan ".ai/agent_sync.yaml")     — project config"
    echo "   Created $(_cyan ".ai/src/AGENTS.md")      — agent identity"

    local rule_count=0
    for f in "$ai_dir/src/rules/"*.md; do [[ -f "$f" ]] && rule_count=$((rule_count + 1)); done
    echo "   Created $(_cyan ".ai/src/rules/")          — $rule_count rule(s)"

    local skill_count=0
    for d in "$ai_dir/src/skills/"*/; do [[ -d "$d" ]] && skill_count=$((skill_count + 1)); done
    echo "   Created $(_cyan ".ai/src/skills/")         — $skill_count skill(s)"

    local cmd_count=0
    for f in "$ai_dir/src/commands/"*.md; do [[ -f "$f" ]] && cmd_count=$((cmd_count + 1)); done
    if [[ $cmd_count -gt 0 ]]; then
        echo "   Created $(_cyan ".ai/src/commands/")       — $cmd_count command(s)"
    fi

    local agent_count=0
    for f in "$ai_dir/src/agents/"*.md; do [[ -f "$f" ]] && agent_count=$((agent_count + 1)); done
    if [[ $agent_count -gt 0 ]]; then
        echo "   Created $(_cyan ".ai/src/agents/")         — $agent_count agent(s)"
    fi

    echo ""
    if [[ -n "$enabled_list" ]]; then
        local count
        count=$(echo "$enabled_list" | grep -c .)
        local joined
        joined=$(echo "$enabled_list" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        echo "   $(_green "Auto-detected $count tool(s):") $joined"
    else
        echo "   $(_dim "No tools auto-detected.")"
    fi

    echo ""
    echo "$(_green "Done!")"
    echo ""
    echo "Next steps:"
    echo "  1. Edit $(_cyan ".ai/src/AGENTS.md") — customize your agent's identity"
    echo "  2. Run $(_cyan "agentsync list")        — browse all available tools"
    if [[ -z "$enabled_list" ]]; then
        echo "  3. Run $(_cyan "agentsync enable <tool>") — opt in to tools you use"
    else
        echo "  3. Run $(_cyan "agentsync enable <tool>") — add more tools"
    fi
    echo "  4. Run $(_cyan "agentsync sync")        — distribute to enabled tools"
    echo ""
}

# ── Public command ────────────────────────────────────────────────────────────

cmd_init() {
    local target_dir="${1:-.}"
    target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
        echo "$(_red "Error"): Directory not found: $1" >&2
        exit 1
    }

    local ai_dir="$target_dir/.ai"

    if [[ -d "$ai_dir/src" ]]; then
        echo "$(_yellow "Warning"): .ai/src/ already exists in $target_dir"
        echo "Skipping init to avoid overwriting your content."
        echo ""
        echo "Run $(_cyan "agentsync sync") to synchronize."
        return 0
    fi

    echo ""
    echo "$(_bold "Initializing AgentSync") in $(_cyan "$target_dir")"
    echo ""

    _init_create_directories "$ai_dir"

    local templates_dir=""
    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || true
    if [[ -n "$system_dir" ]] && [[ -d "$system_dir/templates" ]]; then
        templates_dir="$system_dir/templates"
    fi

    _init_copy_source_templates "$ai_dir" "$templates_dir"

    local detected
    detected=$(_init_detect_enabled_tools "$target_dir")

    _init_create_project_config "$target_dir" "$detected"
    _init_print_summary "$ai_dir" "$detected"
}
