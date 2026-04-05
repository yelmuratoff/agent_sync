#!/usr/bin/env bash
# agentsync init — scaffolds the .ai/ directory in a project.

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
    mkdir -p "$ai_dir/src/tools"
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
        # Fallback: minimal inline templates when engine is unavailable
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

_init_create_project_config() {
    local target_dir="$1"
    local config_file="$target_dir/.ai/agent_sync.yaml"

    # Skip if already exists (either new or legacy location)
    if [[ -f "$config_file" ]] || [[ -f "$target_dir/agent_sync.yaml" ]]; then
        return 0
    fi

    cat > "$config_file" << 'EOF'
# AgentSync — Project Configuration
# All keys are optional — remove any that you leave at the default.

# Source paths (override if you use a custom layout)
source:
  agents: ".ai/src/AGENTS.md"   # agent identity file
  rules: ".ai/src/rules"        # directory with *.md rule files
  skills: ".ai/src/skills"      # directory with skill subdirectories
  commands: ".ai/src/commands"  # directory with slash-command *.md files
  subagents: ".ai/src/agents"   # directory with sub-agent *.md files
  tools: ".ai/src/tools"        # directory with tool *.yaml configs

# mcp, hooks, and settings sources are configured per-tool
# inside each .ai/src/tools/<tool>.yaml under targets.mcp.source,
# targets.hooks.source, and targets.settings.source.

# Global defaults applied to all tools
defaults:
  enabled: true   # default enabled state for tools that omit the 'enabled' key
  cleanup: true   # remove generated files when a tool is disabled

# Post-sync hook execution (also controllable via env vars)
# AGENTSYNC_ALLOW_POST_SYNC and AGENTSYNC_SKIP_POST_SYNC take precedence.
post_sync:
  allow: false    # set to true to allow post-sync hooks defined in tool configs
  skip: false     # set to true to skip post-sync hooks even when allow is true

# .gitignore management
gitignore:
  update: true    # set to false to disable automatic .gitignore updates
EOF
}

_init_copy_tool_configs() {
    local ai_dir="$1"
    local templates_dir="$2"

    local copied=false
    if [[ -n "$templates_dir" ]] && [[ -d "$templates_dir/tools" ]]; then
        for tool_file in "$templates_dir/tools/"*.yaml; do
            [[ -f "$tool_file" ]] || continue
            local basename
            basename=$(basename "$tool_file")
            [[ "$basename" == _* ]] && continue
            cp "$tool_file" "$ai_dir/src/tools/$basename"
        done
        if [[ -f "$templates_dir/tools/_TEMPLATE.yaml" ]]; then
            cp "$templates_dir/tools/_TEMPLATE.yaml" "$ai_dir/src/tools/_TEMPLATE.yaml"
        fi
        copied=true
    fi

    if [[ "$copied" != "true" ]]; then
        _init_fallback_tools "$ai_dir"
    fi
}

_init_print_summary() {
    local ai_dir="$1"

    echo ""
    echo "   Created $(_cyan ".ai/agent_sync.yaml")     — project config (source paths)"
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

    local tool_count=0
    for f in "$ai_dir/src/tools/"*.yaml; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == _* ]] && continue
        tool_count=$((tool_count + 1))
    done
    echo "   Created $(_cyan ".ai/src/tools/")          — $tool_count tool(s)"

    local enabled_tools=""
    local enabled_count=0
    for f in "$ai_dir/src/tools/"*.yaml; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == _* ]] && continue

        local tool_enabled=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^enabled:[[:space:]]*(true|false) ]]; then
                tool_enabled="${BASH_REMATCH[1]}"
                break
            fi
        done < "$f"

        if [[ "$tool_enabled" == "true" ]]; then
            local tool_label=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^name:[[:space:]]*[\"\']?([^\"\']+)[\"\']? ]]; then
                    tool_label="${BASH_REMATCH[1]}"
                    break
                fi
            done < "$f"
            [[ -z "$tool_label" ]] && tool_label="$(basename "$f" .yaml)"
            if [[ -n "$enabled_tools" ]]; then
                enabled_tools="$enabled_tools, $tool_label"
            else
                enabled_tools="$tool_label"
            fi
            enabled_count=$((enabled_count + 1))
        fi
    done

    echo ""
    echo "$(_green "Done!")"
    if [[ $enabled_count -gt 0 ]]; then
        echo ""
        echo "   Enabled tools ($enabled_count): $(_cyan "$enabled_tools")"
        echo "   $(_dim "Enable more in .ai/src/tools/<name>.yaml → enabled: true")"
    fi
    echo ""
    echo "Next steps:"
    echo "  1. Edit $(_cyan ".ai/src/AGENTS.md") — customize your agent's identity"
    echo "  2. Edit rules in $(_cyan ".ai/src/rules/") — add project-specific constraints"
    echo "  3. Run $(_cyan "agentsync generate | pbcopy") — generate project-specific config via AI"
    echo "  4. Run $(_cyan "agentsync sync") — distribute to all enabled tools"
    echo "  5. Run $(_cyan "agentsync help") — see all available commands"
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
    _init_create_project_config "$target_dir"

    local templates_dir=""
    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || true
    if [[ -n "$system_dir" ]] && [[ -d "$system_dir/templates" ]]; then
        templates_dir="$system_dir/templates"
    fi

    _init_copy_source_templates "$ai_dir" "$templates_dir"
    _init_copy_tool_configs "$ai_dir" "$templates_dir"
    _init_print_summary "$ai_dir"
}

# ── Fallback tool configs ─────────────────────────────────────────────────────

# Fallback tool configs when engine templates are unavailable
_init_fallback_tools() {
    local ai_dir="$1"

    cat > "$ai_dir/src/tools/claude.yaml" << 'EOF'
name: "Claude Code"
enabled: true
targets:
  agents: { dest: ".claude/CLAUDE.md" }
  rules: { dest: ".claude/rules", append_imports: true }
  skills: { dest: ".claude/skills" }
  commands: { dest: ".claude/commands" }
  subagents: { dest: ".claude/agents" }
EOF

    cat > "$ai_dir/src/tools/copilot.yaml" << 'EOF'
name: "GitHub Copilot"
enabled: true
targets:
  agents: { dest: ".github/copilot-instructions.md" }
  rules: { dest: ".github/instructions", extension: ".instructions.md", header: "---\napplyTo: '**'\n---" }
  skills: { dest: ".github/skills" }
  commands: { dest: ".github/prompts", extension: ".prompt.md" }
  subagents: { dest: ".github/agents", extension: ".agent.md" }
EOF

    cat > "$ai_dir/src/tools/cursor.yaml" << 'EOF'
name: "Cursor"
enabled: true
targets:
  agents: { dest: ".cursor/AGENTS.md" }
  rules: { dest: ".cursor/rules", extension: ".mdc", header: "---\nglobs: '**/*'\nalwaysApply: true\n---" }
  skills: { dest: ".cursor/skills" }
  subagents: { dest: ".cursor/agents" }
  mcp: { source: ".ai/src/mcp/cursor.json", dest: ".cursor/mcp.json" }
  hooks: { source: ".ai/src/hooks/cursor.json", dest: ".cursor/hooks.json" }
EOF

    cat > "$ai_dir/src/tools/gemini.yaml" << 'EOF'
name: "Gemini CLI"
enabled: true
targets:
  agents: { dest: ".gemini/GEMINI.md" }
  rules: { inline_into_agents: true }
  skills: { dest: ".gemini/skills" }
  commands: { dest: ".gemini/commands", format: toml }
  subagents: { dest: ".gemini/agents" }
EOF

    cat > "$ai_dir/src/tools/codex.yaml" << 'EOF'
name: "OpenAI Codex"
enabled: true
targets:
  agents: { dest: "AGENTS.md" }
  rules: { inline_into_agents: true }
  skills: { dest: ".agents/skills" }
  subagents: { dest: ".codex/agents", format: toml }
  hooks: { source: ".ai/src/hooks/codex.json", dest: ".codex/hooks.json" }
EOF

    cat > "$ai_dir/src/tools/windsurf.yaml" << 'EOF'
name: "Windsurf"
enabled: true
targets:
  agents: { dest: ".windsurf/AGENTS.md" }
  rules: { dest: ".windsurf/rules", header: "---\ntrigger: always_on\n---" }
  skills: { dest: ".windsurf/skills" }
EOF

    cat > "$ai_dir/src/tools/junie.yaml" << 'EOF'
name: "JetBrains Junie"
enabled: true
targets:
  agents: { dest: ".junie/guidelines.md" }
  rules: { dest: ".junie/guidelines" }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/amp.yaml" << 'EOF'
name: "Amp"
enabled: true
targets:
  agents: { dest: "AGENTS.md" }
  rules: { inline_into_agents: true }
  skills: { dest: ".agents/skills" }
EOF

    cat > "$ai_dir/src/tools/aider.yaml" << 'EOF'
name: "Aider"
enabled: true
targets:
  rules: { dest: "CONVENTIONS.md", merge_to_file: true, prepend_agents: true }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/cline.yaml" << 'EOF'
name: "Cline"
enabled: true
targets:
  agents: { dest: ".clinerules/00-context.md" }
  rules: { dest: ".clinerules" }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/amazonq.yaml" << 'EOF'
name: "Amazon Q Developer"
enabled: true
targets:
  agents: { dest: ".amazonq/rules/00-context.md" }
  rules: { dest: ".amazonq/rules" }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/augment.yaml" << 'EOF'
name: "Augment Code"
enabled: true
targets:
  agents: { dest: ".augment/rules/00-context.md" }
  rules: { dest: ".augment/rules" }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/devin.yaml" << 'EOF'
name: "Devin"
enabled: true
targets:
  agents: { dest: "AGENTS.md" }
  rules: { inline_into_agents: true }
  skills: { dest: ".devin/skills" }
EOF

    cat > "$ai_dir/src/tools/tabnine.yaml" << 'EOF'
name: "Tabnine"
enabled: true
targets:
  agents: { dest: ".tabnine/guidelines/00-context.md" }
  rules: { dest: ".tabnine/guidelines" }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/zed.yaml" << 'EOF'
name: "Zed"
enabled: true
targets:
  rules: { dest: ".rules", merge_to_file: true, prepend_agents: true }
  skills: { inline_into_agents: true }
EOF

    cat > "$ai_dir/src/tools/continue.yaml" << 'EOF'
name: "Continue"
enabled: true
targets:
  rules: { dest: ".continuerules", merge_to_file: true, prepend_agents: true }
  skills: { inline_into_agents: true }
EOF
}
