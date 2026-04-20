#!/usr/bin/env bash
# agentsync init — scaffolds the .ai/ directory in a project.
#
# Model:
#   - Tool configs are NOT copied to .ai/src/tools/. They live in the install-dir
#     base and are referenced via tools.enabled list in agent_sync.yaml. Users
#     create per-tool override files only when they want to customize.
#   - Per-tool payloads (hooks, mcp, settings) are NOT eagerly copied either.
#     They are scaffolded only for tools the user has opted into (auto-detected
#     from filesystem markers, passed via --tools, or explicitly enabled later).
#     Missing overrides fall back to base templates at sync time.
#   - Source content (AGENTS.md, rules, skills, commands, agents) is selectable
#     via --content; default is "agents,rules".

# Default set of starter content sections created by init. Users can narrow
# this with --content.
_INIT_CONTENT_DEFAULT="agents,rules,skills,commands,subagents"

# Valid content sections accepted by --content.
_INIT_CONTENT_VALID="agents rules skills commands subagents"

# ── Private helpers ───────────────────────────────────────────────────────────

# Does $1 appear in whitespace-separated list $2? Returns 0/1.
_init_list_contains() {
    local needle="$1"
    local haystack=" $2 "
    [[ "$haystack" == *" $needle "* ]]
}

# Normalize a CSV string into space-separated unique tokens (preserves order).
_init_normalize_csv() {
    local csv="$1"
    local out="" token
    IFS=',' read -ra parts <<< "$csv"
    for token in "${parts[@]}"; do
        token="${token// /}"
        [[ -z "$token" ]] && continue
        _init_list_contains "$token" "$out" && continue
        out="${out:+$out }$token"
    done
    echo "$out"
}

# Merge two space-separated lists, deduping while preserving first-seen order.
_init_merge_lists() {
    local a="$1" b="$2" out="" token
    for token in $a $b; do
        [[ -z "$token" ]] && continue
        _init_list_contains "$token" "$out" && continue
        out="${out:+$out }$token"
    done
    echo "$out"
}

# Create only the directories that will actually hold files. Payload dirs
# (settings/mcp/hooks) are created lazily when `_init_copy_tool_payloads`
# copies a file into them.
_init_create_directories() {
    local ai_dir="$1"
    local content_list="$2"
    mkdir -p "$ai_dir/src"
    _init_list_contains "rules"     "$content_list" && mkdir -p "$ai_dir/src/rules"
    _init_list_contains "skills"    "$content_list" && mkdir -p "$ai_dir/src/skills"
    _init_list_contains "commands"  "$content_list" && mkdir -p "$ai_dir/src/commands"
    _init_list_contains "subagents" "$content_list" && mkdir -p "$ai_dir/src/agents"
    # tools/ intentionally NOT created — created on demand by `customize`.
    # settings/, mcp/, hooks/ are created on demand by `_init_copy_tool_payloads`
    # only for tools that are enabled.
    return 0
}

_init_copy_source_templates() {
    local ai_dir="$1"
    local templates_dir="$2"
    local content_list="$3"

    if [[ -n "$templates_dir" ]]; then
        if _init_list_contains "agents" "$content_list"; then
            [[ -f "$templates_dir/AGENTS.md" ]] && cp "$templates_dir/AGENTS.md" "$ai_dir/src/AGENTS.md"
        fi

        if _init_list_contains "rules" "$content_list"; then
            for rule_file in "$templates_dir/rules/"*.md; do
                [[ -f "$rule_file" ]] || continue
                cp "$rule_file" "$ai_dir/src/rules/"
            done
        fi

        if _init_list_contains "skills" "$content_list"; then
            for skill_dir in "$templates_dir/skills/"*/; do
                [[ -d "$skill_dir" ]] || continue
                local skill_name
                skill_name=$(basename "$skill_dir")
                mkdir -p "$ai_dir/src/skills/$skill_name"
                cp "$skill_dir"* "$ai_dir/src/skills/$skill_name/" 2>/dev/null || true
            done
        fi

        if _init_list_contains "commands" "$content_list" && [[ -d "$templates_dir/commands" ]]; then
            for cmd_file in "$templates_dir/commands/"*.md; do
                [[ -f "$cmd_file" ]] || continue
                cp "$cmd_file" "$ai_dir/src/commands/"
            done
        fi

        if _init_list_contains "subagents" "$content_list" && [[ -d "$templates_dir/agents" ]]; then
            for agent_file in "$templates_dir/agents/"*.md; do
                [[ -f "$agent_file" ]] || continue
                cp "$agent_file" "$ai_dir/src/agents/"
            done
        fi
    else
        if _init_list_contains "agents" "$content_list"; then
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
        fi

        if _init_list_contains "rules" "$content_list"; then
            cat > "$ai_dir/src/rules/core.md" << 'RULE_EOF'
# Core Rules

- Follow the project's established conventions and patterns.
- Prefer readability over cleverness.
- Handle errors explicitly. Don't swallow exceptions.
- Write tests for business logic and error paths.
- Never hardcode secrets, API keys, or credentials.
RULE_EOF
        fi
    fi
}

# Copy per-tool payload files (settings, hooks) ONLY for tools in the list.
# MCP is intentionally excluded: in 0.11+ every tool gets MCP from the shared
# .ai/src/mcp.json (or base template). Scaffolding empty per-tool MCP files
# would shadow that shared source. Use `agentsync add mcp <server>` to create
# a shared source, or `agentsync customize <tool> mcp` for a per-tool override.
#
# Creates destination directories lazily (only when a file is actually copied).
# Returns 0 always. Prints one "<resource>/<file>" path per scaffold to stdout.
_init_copy_tool_payloads() {
    local ai_dir="$1"
    local templates_dir="$2"
    local tool_list="$3"   # space-separated tool names

    [[ -z "$templates_dir" ]] && return 0
    [[ -z "$tool_list" ]] && return 0

    local resource tool src_file dest_dir
    for resource in settings hooks; do
        [[ -d "$templates_dir/$resource" ]] || continue
        for tool in $tool_list; do
            for src_file in "$templates_dir/$resource/$tool".*; do
                [[ -f "$src_file" ]] || continue
                dest_dir="$ai_dir/src/$resource"
                mkdir -p "$dest_dir"
                cp "$src_file" "$dest_dir/"
                echo "$resource/$(basename "$src_file")"
            done
        done
    done
    return 0
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

HEAD
        # Pin the CLI version that scaffolded this file. `doctor` warns on
        # mismatches so teams can catch drifting toolchains early.
        echo "agentsync_version: \"${VERSION:-unknown}\""
        cat << 'HEAD'

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
    local enabled_list="$2"       # space-separated (or empty)
    local payload_lines="$3"      # newline-separated "resource/file.ext" (or empty)
    local detect_source="$4"      # "detect" | "flag" | "mixed" | "none"

    echo ""
    echo "   Created $(_cyan ".ai/agent_sync.yaml")     — project config"

    [[ -f "$ai_dir/src/AGENTS.md" ]] && \
        echo "   Created $(_cyan ".ai/src/AGENTS.md")      — agent identity"

    local rule_count=0
    if [[ -d "$ai_dir/src/rules" ]]; then
        for f in "$ai_dir/src/rules/"*.md; do [[ -f "$f" ]] && rule_count=$((rule_count + 1)); done
        [[ $rule_count -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src/rules/")          — $rule_count rule(s)"
    fi

    local skill_count=0
    if [[ -d "$ai_dir/src/skills" ]]; then
        for d in "$ai_dir/src/skills/"*/; do [[ -d "$d" ]] && skill_count=$((skill_count + 1)); done
        [[ $skill_count -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src/skills/")         — $skill_count skill(s)"
    fi

    local cmd_count=0
    if [[ -d "$ai_dir/src/commands" ]]; then
        for f in "$ai_dir/src/commands/"*.md; do [[ -f "$f" ]] && cmd_count=$((cmd_count + 1)); done
        [[ $cmd_count -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src/commands/")       — $cmd_count command(s)"
    fi

    local agent_count=0
    if [[ -d "$ai_dir/src/agents" ]]; then
        for f in "$ai_dir/src/agents/"*.md; do [[ -f "$f" ]] && agent_count=$((agent_count + 1)); done
        [[ $agent_count -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src/agents/")         — $agent_count subagent(s)"
    fi

    if [[ -n "$payload_lines" ]]; then
        local resource count_settings=0 count_mcp=0 count_hooks=0 line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            resource="${line%%/*}"
            case "$resource" in
                settings) count_settings=$((count_settings + 1)) ;;
                mcp)      count_mcp=$((count_mcp + 1)) ;;
                hooks)    count_hooks=$((count_hooks + 1)) ;;
            esac
        done <<< "$payload_lines"

        local settings_path="/settings/" mcp_path="/mcp/" hooks_path="/hooks/"
        [[ $count_settings -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src${settings_path}")      — $count_settings tool settings file(s)"
        [[ $count_mcp -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src${mcp_path}")           — $count_mcp tool MCP file(s)"
        [[ $count_hooks -gt 0 ]] && \
            echo "   Created $(_cyan ".ai/src${hooks_path}")         — $count_hooks tool hooks file(s)"
    fi

    echo ""
    if [[ -n "$enabled_list" ]]; then
        local count=0 joined=""
        local t
        for t in $enabled_list; do
            count=$((count + 1))
            joined="${joined:+$joined, }$t"
        done
        case "$detect_source" in
            detect)      echo "   $(_green "Auto-detected $count tool(s):") $joined" ;;
            flag)        echo "   $(_green "Enabled $count tool(s):") $joined $(_dim "(from --tools)")" ;;
            mixed)       echo "   $(_green "Enabled $count tool(s):") $joined $(_dim "(auto-detect + --tools)")" ;;
            interactive) echo "   $(_green "Enabled $count tool(s):") $joined $(_dim "(selected)")" ;;
            *)           echo "   $(_green "Enabled $count tool(s):") $joined" ;;
        esac
    else
        echo "   $(_dim "No tools enabled. Run 'agentsync enable <slug>' to opt in.")"
    fi

    echo ""
    echo "$(_green "Done!")"
    echo ""
    echo "Next steps:"
    local step=1
    if [[ -f "$ai_dir/src/AGENTS.md" ]]; then
        echo "  $step. Edit $(_cyan ".ai/src/AGENTS.md") — customize your agent's identity"
        step=$((step + 1))
    fi
    echo "  $step. Run $(_cyan "agentsync list")        — browse all available tools"
    step=$((step + 1))
    if [[ -z "$enabled_list" ]]; then
        echo "  $step. Run $(_cyan "agentsync enable <slug>") — opt in to tools you use"
    else
        echo "  $step. Run $(_cyan "agentsync enable <slug>") — add more tools"
    fi
    step=$((step + 1))
    echo "  $step. Run $(_cyan "agentsync sync")        — distribute to enabled tools"
    echo ""
}

# Validate --content tokens against the allowed set. Prints error + exits on
# unknown token.
_init_validate_content() {
    local content_list="$1"
    local token
    for token in $content_list; do
        _init_list_contains "$token" "$_INIT_CONTENT_VALID" || {
            echo "$(_red "Error"): Unknown --content section: $token" >&2
            echo "Valid sections: $_INIT_CONTENT_VALID" >&2
            exit 1
        }
    done
}

# List all base tools available in the shipped templates. Prints one per line.
_init_list_available_tools() {
    local templates_dir="$1"
    [[ -z "$templates_dir" ]] && return 0
    local tools_dir="$templates_dir/tools"
    [[ -d "$tools_dir" ]] || return 0
    local f name
    for f in "$tools_dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .yaml)
        [[ "$name" == _* ]] && continue
        echo "$name"
    done | sort
}

# Render the plan (what init would create) — used by --dry-run and before
# the final TTY confirmation.
_init_print_plan() {
    local target_dir="$1"
    local tool_list="$2"
    local content_list="$3"
    local templates_dir="$4"
    local detect_source="$5"

    echo "$(_bold "Plan:")"
    echo "  Target:   $(_cyan "$target_dir/.ai/")"
    if [[ -n "$content_list" ]]; then
        local content_joined="" tok
        for tok in $content_list; do content_joined="${content_joined:+$content_joined, }$tok"; done
        echo "  Content:  $content_joined"
    else
        echo "  Content:  $(_dim "(none)")"
    fi
    if [[ -n "$tool_list" ]]; then
        local tools_joined="" tok
        for tok in $tool_list; do tools_joined="${tools_joined:+$tools_joined, }$tok"; done
        echo "  Tools:    $tools_joined $(_dim "($detect_source)")"
    else
        echo "  Tools:    $(_dim "(none — opt in later via 'agentsync enable')")"
    fi

    # Preview payload scaffolds. MCP is intentionally excluded — it resolves
    # via the shared .ai/src/mcp.json (or base) in 0.11+.
    if [[ -n "$tool_list" ]] && [[ -n "$templates_dir" ]]; then
        local resource tool src_file any_payload=0
        for resource in settings hooks; do
            [[ -d "$templates_dir/$resource" ]] || continue
            local per_resource=""
            for tool in $tool_list; do
                for src_file in "$templates_dir/$resource/$tool".*; do
                    [[ -f "$src_file" ]] || continue
                    per_resource="${per_resource:+$per_resource, }$(basename "$src_file")"
                    any_payload=1
                done
            done
            if [[ -n "$per_resource" ]]; then
                printf '  %-9s %s\n' "$resource:" "$per_resource"
            fi
        done
        [[ $any_payload -eq 0 ]] && echo "  $(_dim "No payloads to scaffold — tools will use base templates at sync time.")"
    fi
    echo ""
}

# ── agentsync upgrade-config ──────────────────────────────────────────────────

# Update the agentsync_version pin in agent_sync.yaml to the current CLI
# version. Creates the key if missing.
cmd_upgrade_config() {
    local project_dir
    project_dir="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    project_dir="$(cd "$project_dir" && pwd)"

    local config=""
    if [[ -f "$project_dir/.ai/agent_sync.yaml" ]]; then
        config="$project_dir/.ai/agent_sync.yaml"
    elif [[ -f "$project_dir/agent_sync.yaml" ]]; then
        config="$project_dir/agent_sync.yaml"
    else
        echo "$(_red "Error"): No agent_sync.yaml found in $project_dir" >&2
        echo "Run $(_cyan "agentsync init") first." >&2
        exit 1
    fi

    local current="${VERSION:-unknown}"
    local existing
    existing=$(grep -E '^agentsync_version:' "$config" | head -1 || true)

    if [[ -z "$existing" ]]; then
        # Insert at the top of file (after leading comments if any).
        local tmp
        tmp=$(mktemp)
        {
            # Emit leading comment block as-is, then the version line, then rest.
            awk -v ver="$current" '
                BEGIN { inserted=0 }
                /^[[:space:]]*(#|$)/ && !inserted { print; next }
                !inserted { printf "agentsync_version: \"%s\"\n\n", ver; inserted=1 }
                { print }
                END { if (!inserted) printf "agentsync_version: \"%s\"\n", ver }
            ' "$config"
        } > "$tmp"
        mv "$tmp" "$config"
        echo "$(_green "Added"): agentsync_version: $current → $(_dim "$config")"
    else
        # Replace the existing line.
        local escaped="${current//\//\\/}"
        # Use sed in-place with a backup suffix that we delete, for mac/linux parity.
        sed -i.agentsync_bak -E "s|^agentsync_version:.*|agentsync_version: \"$escaped\"|" "$config"
        rm -f "$config.agentsync_bak"
        echo "$(_green "Updated"): agentsync_version → $current $(_dim "$config")"
    fi
}

# ── Public command ────────────────────────────────────────────────────────────

cmd_init() {
    local target_dir=""
    local tools_flag=""
    local content_flag=""
    local no_detect=false
    local assume_yes=false
    local dry_run=false
    local tools_flag_set=false
    local content_flag_set=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --tools requires a value" >&2; exit 1; }
                tools_flag="$2"
                tools_flag_set=true
                shift 2
                ;;
            --tools=*)
                tools_flag="${1#--tools=}"
                tools_flag_set=true
                shift
                ;;
            --content)
                [[ $# -lt 2 ]] && { echo "$(_red "Error"): --content requires a value" >&2; exit 1; }
                content_flag="$2"
                content_flag_set=true
                shift 2
                ;;
            --content=*)
                content_flag="${1#--content=}"
                content_flag_set=true
                shift
                ;;
            --no-detect)
                no_detect=true
                shift
                ;;
            --yes|-y)
                assume_yes=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help|-h)
                cat << 'HELP'
Usage: agentsync init [<dir>] [OPTIONS]

Scaffold .ai/ in a project. Minimal by default — only tools you opt in to
get per-tool payload scaffolding (settings/mcp/hooks).

In a terminal, `init` opens an interactive wizard that lets you pick tools
and content sections. In non-TTY environments (CI, scripts), it runs silently
with auto-detected defaults. Pass --yes or any of --tools/--content/--no-detect
to skip the wizard.

Options:
  --tools <csv>        Enable these tools (e.g. claude,cursor). Unions with
                       auto-detection unless --no-detect is passed.
  --content <csv>      Which source sections to scaffold. Valid tokens:
                       agents, rules, skills, commands, subagents.
                       Default: all of them.
  --no-detect          Skip filesystem marker auto-detection.
  -y, --yes            Skip all prompts, accept defaults.
  --dry-run            Show what would be created; don't write anything.
  -h, --help           Show this help.

Examples:
  agentsync init                           # interactive wizard (TTY)
  agentsync init --yes                     # auto-detect + defaults, no prompt
  agentsync init --tools claude            # Claude only, no detection union
  agentsync init --tools claude,cursor --content agents,rules
  agentsync init --no-detect               # blank slate, pick tools later
  agentsync init --dry-run                 # preview without writing
HELP
                return 0
                ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                echo "Run $(_cyan "agentsync init --help") for usage." >&2
                exit 1
                ;;
            *)
                if [[ -z "$target_dir" ]]; then
                    target_dir="$1"
                    shift
                else
                    echo "$(_red "Error"): Unexpected argument: $1" >&2
                    exit 1
                fi
                ;;
        esac
    done

    target_dir="${target_dir:-.}"
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

    # Resolve content list.
    local content_list
    if [[ -n "$content_flag" ]]; then
        content_list=$(_init_normalize_csv "$content_flag")
    else
        content_list=$(_init_normalize_csv "$_INIT_CONTENT_DEFAULT")
    fi
    _init_validate_content "$content_list"

    # Resolve tool list: flag ∪ auto-detect (unless --no-detect).
    local tools_from_flag="" tools_from_detect="" tool_list detect_source="none"
    if [[ -n "$tools_flag" ]]; then
        tools_from_flag=$(_init_normalize_csv "$tools_flag")
    fi
    if [[ "$no_detect" != "true" ]]; then
        # _init_detect_enabled_tools prints one per line — flatten to spaces.
        tools_from_detect=$(_init_detect_enabled_tools "$target_dir" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
    fi
    tool_list=$(_init_merge_lists "$tools_from_flag" "$tools_from_detect")
    if [[ -n "$tools_from_flag" && -n "$tools_from_detect" ]]; then
        detect_source="mixed"
    elif [[ -n "$tools_from_flag" ]]; then
        detect_source="flag"
    elif [[ -n "$tools_from_detect" ]]; then
        detect_source="detect"
    fi

    # Templates directory — resolved early so the wizard can show available tools.
    local templates_dir=""
    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || true
    if [[ -n "$system_dir" ]] && [[ -d "$system_dir/templates" ]]; then
        templates_dir="$system_dir/templates"
    fi

    # Interactive wizard triggers when:
    #   - stdin+stdout are a TTY
    #   - no --yes, no --tools, no --content (those are explicit automation)
    #   - --dry-run still opens the wizard; we just don't write at the end.
    local interactive=false
    if is_tty \
        && [[ "$assume_yes" != "true" ]] \
        && [[ "$tools_flag_set" != "true" ]] \
        && [[ "$content_flag_set" != "true" ]]; then
        interactive=true
    fi

    if [[ "$interactive" == "true" ]]; then
        echo ""
        echo "$(_bold "AgentSync init") — $(_dim "$target_dir")"
        echo ""

        # Step 1: pick tools.
        local available_tools
        available_tools=$(_init_list_available_tools "$templates_dir" | tr '\n' ' ' | sed 's/ $//')
        if [[ -n "$available_tools" ]]; then
            local title
            if [[ -n "$tool_list" ]]; then
                title="Tools to enable $(_dim "(detected: $(echo "$tool_list" | tr ' ' ',')):")"
            else
                title="Tools to enable $(_dim "(none auto-detected):")"
            fi
            local picked
            picked=$(prompt_multiselect "$title" "$available_tools" "$tool_list") || {
                echo "$(_yellow "Cancelled.")" >&2
                return 130
            }
            tool_list="$picked"
            detect_source="interactive"
            echo ""
        fi

        # Step 2: pick content sections.
        local picked_content
        picked_content=$(prompt_multiselect \
            "Content sections:" \
            "$_INIT_CONTENT_VALID" \
            "$content_list") || {
            echo "$(_yellow "Cancelled.")" >&2
            return 130
        }
        content_list="$picked_content"
        echo ""
    fi

    # Render plan. For dry-run this is the only output; interactive asks to
    # confirm; explicit-flag non-interactive just proceeds.
    _init_print_plan "$target_dir" "$tool_list" "$content_list" "$templates_dir" "$detect_source"

    if [[ "$dry_run" == "true" ]]; then
        echo "$(_dim "Dry run — nothing was written.")"
        return 0
    fi

    if [[ "$interactive" == "true" ]]; then
        prompt_confirm "Proceed?" "y" || {
            echo "$(_yellow "Cancelled.")"
            return 130
        }
        echo ""
    fi

    echo "$(_bold "Initializing AgentSync") in $(_cyan "$target_dir")"
    echo ""

    _init_create_directories "$ai_dir" "$content_list"
    _init_copy_source_templates "$ai_dir" "$templates_dir" "$content_list"

    local payload_lines
    payload_lines=$(_init_copy_tool_payloads "$ai_dir" "$templates_dir" "$tool_list")

    # Project config: one tool per line (newline-separated), as expected by writer.
    local enabled_newline
    enabled_newline=$(echo "$tool_list" | tr ' ' '\n' | sed '/^$/d')

    _init_create_project_config "$target_dir" "$enabled_newline"
    _init_print_summary "$ai_dir" "$tool_list" "$payload_lines" "$detect_source"
}
