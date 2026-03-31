#!/usr/bin/env bash
# agentsync list — shows configured tools and their status.

cmd_list() {
    local project_dir="${AGENTSYNC_REPO_ROOT:-.}"
    project_dir="$(cd "$project_dir" && pwd)"

    local tools_dir=""
    if [[ -d "$project_dir/.ai/src/tools" ]]; then
        tools_dir="$project_dir/.ai/src/tools"
    elif [[ -d "$project_dir/.ai/tools" ]]; then
        tools_dir="$project_dir/.ai/tools"
    fi

    if [[ -z "$tools_dir" ]] || [[ ! -d "$tools_dir" ]]; then
        echo "$(_red "Error"): No tools directory found."
        echo "Run $(_cyan "agentsync init") first."
        exit 1
    fi

    echo ""
    _bold "  AgentSync Tools"; echo ""
    echo ""

    local count=0
    for tool_file in "$tools_dir"/*.yaml; do
        [[ -f "$tool_file" ]] || continue
        local basename
        basename=$(basename "$tool_file" .yaml)
        [[ "$basename" == _* ]] && continue

        local name="" enabled=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^name:[[:space:]]*[\"\']?([^\"\']+)[\"\']? ]]; then
                name="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ ^enabled:[[:space:]]*(true|false) ]]; then
                enabled="${BASH_REMATCH[1]}"
            fi
        done < "$tool_file"

        [[ -z "$name" ]] && name="$basename"
        [[ -z "$enabled" ]] && enabled="true"

        if [[ "$enabled" == "true" ]]; then
            echo "    $(_green "●") $name $(_dim "($basename.yaml)")"
        else
            echo "    $(_dim "○") $(_dim "$name") $(_dim "($basename.yaml) — disabled")"
        fi
        count=$((count + 1))
    done

    echo ""
    echo "  $count tool(s) configured in $(_dim "$tools_dir")"
    echo ""
}
