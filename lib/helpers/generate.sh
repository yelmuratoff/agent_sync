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
        echo "Expected at: <engine>/lib/prompts/generate.md" >&2
        exit 1
    fi

    # If context was passed as argument, skip interactive mode
    if [[ -n "$context" ]]; then
        _output_prompt "$prompt_file" "$context"
        return 0
    fi

    # If piped (not interactive terminal), output raw prompt
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        _output_prompt "$prompt_file" ""
        return 0
    fi

    # ── Interactive mode ──
    echo "" >&2
    _bold "  AgentSync Generate" >&2; echo "" >&2
    echo "" >&2
    echo "  Choose what to generate:" >&2
    echo "" >&2
    echo "    $(_cyan "1)") Base prompt only" >&2
    echo "       Ready-to-paste prompt without project details." >&2
    echo "" >&2
    echo "    $(_cyan "2)") Prompt + project description" >&2
    echo "       You describe your stack, and it gets included in the prompt." >&2
    echo "" >&2

    local choice=""
    while [[ "$choice" != "1" ]] && [[ "$choice" != "2" ]]; do
        printf "  %s " "$(_green "▸") Choice [1/2]:" >&2
        read -r choice
        if [[ -z "$choice" ]]; then
            choice="1"
        fi
    done

    if [[ "$choice" == "1" ]]; then
        echo "" >&2
        _output_prompt "$prompt_file" ""
        return 0
    fi

    # ── Collect project description ──
    echo "" >&2
    echo "  ╭─────────────────────────────────────────────────────────╮" >&2
    echo "  │  Describe your project: stack, frameworks, conventions  │" >&2
    echo "  │  Type as many lines as you want.                        │" >&2
    echo "  │  Press $(_cyan "Enter") twice (empty line) when done.              │" >&2
    echo "  ╰─────────────────────────────────────────────────────────╯" >&2
    echo "" >&2

    local lines=""
    local prev_empty=false
    while true; do
        printf "  %s " "$(_dim "│")" >&2
        IFS= read -r line
        if [[ -z "$line" ]]; then
            if [[ "$prev_empty" == "true" ]]; then
                break
            fi
            prev_empty=true
            lines+=$'\n'
        else
            prev_empty=false
            if [[ -n "$lines" ]]; then
                lines+=$'\n'
            fi
            lines+="$line"
        fi
    done

    # Trim trailing newlines
    while [[ "$lines" == *$'\n' ]]; do
        lines="${lines%$'\n'}"
    done

    echo "" >&2
    _output_prompt "$prompt_file" "$lines"
}

_output_prompt() {
    local prompt_file="$1"
    local context="$2"

    # Build the full prompt
    local output=""

    if [[ -n "$context" ]]; then
        output+="## My Project"
        output+=$'\n\n'
        output+="$context"
        output+=$'\n\n'
        output+="---"
        output+=$'\n\n'
    fi

    output+="$(cat "$prompt_file")"

    # If stdout is a terminal, show with visual separator
    if [[ -t 1 ]]; then
        echo "" >&2
        echo "  $(_dim "─── prompt below ───────────────────────────────────────────")" >&2
        echo "" >&2
        echo "$output"
        echo "" >&2
        echo "  $(_dim "─── end of prompt ──────────────────────────────────────────")" >&2
        echo "" >&2

        local clipboard_cmd=""
        if command -v pbcopy >/dev/null 2>&1; then
            clipboard_cmd="pbcopy"
        elif command -v wl-copy >/dev/null 2>&1; then
            clipboard_cmd="wl-copy"
        elif command -v xclip >/dev/null 2>&1; then
            clipboard_cmd="xclip -selection clipboard"
        elif command -v xsel >/dev/null 2>&1; then
            clipboard_cmd="xsel --clipboard --input"
        fi

        if [[ -n "$clipboard_cmd" ]]; then
            echo "  $(_dim "Tip: run") $(_cyan "agentsync generate | $clipboard_cmd") $(_dim "to copy to clipboard.")" >&2
            echo "" >&2
        fi
    else
        # Piped — raw output, no decoration
        echo "$output"
    fi
}
