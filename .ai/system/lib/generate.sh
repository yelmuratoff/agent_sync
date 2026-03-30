#!/usr/bin/env bash
# agentsync generate — prints a prompt for AI-assisted project configuration.

cmd_generate() {
    # Find the prompt file relative to the system directory
    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || true

    local prompt_file=""
    if [[ -n "$system_dir" ]] && [[ -f "$system_dir/prompts/generate.md" ]]; then
        prompt_file="$system_dir/prompts/generate.md"
    fi

    if [[ -n "$prompt_file" ]]; then
        cat "$prompt_file"
    else
        echo "Error: Prompt file not found." >&2
        echo "Expected at: <engine>/.ai/system/prompts/generate.md" >&2
        exit 1
    fi
}
