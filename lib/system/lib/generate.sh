#!/usr/bin/env bash
# agentsync generate — prints a prompt for AI-assisted project configuration.

cmd_generate() {
    local context="$*"
    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || true

    local prompt_file=""
    if [[ -n "$system_dir" ]] && [[ -f "$system_dir/prompts/generate.md" ]]; then
        prompt_file="$system_dir/prompts/generate.md"
    fi

    if [[ -z "$prompt_file" ]]; then
        echo "Error: Prompt file not found." >&2
        echo "Expected at: <engine>/lib/system/prompts/generate.md" >&2
        exit 1
    fi

    # Print usage hint to stderr (doesn't pollute the prompt if piped)
    if [[ -t 1 ]]; then
        echo "$(_dim "# Copy the prompt below and paste it into any AI assistant.")" >&2
        echo "$(_dim "# Tip: agentsync generate | pbcopy  — copies to clipboard on macOS.")" >&2
        echo "" >&2
    fi

    # Print context block if provided
    if [[ -n "$context" ]]; then
        echo "## My Project Context"
        echo ""
        echo "$context"
        echo ""
        echo "---"
        echo ""
    fi

    cat "$prompt_file"
}
