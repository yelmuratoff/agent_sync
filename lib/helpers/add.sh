#!/usr/bin/env bash
# agentsync add — scaffold new source content (rule / skill / command / subagent).
#
# Usage: agentsync add <kind> <name> [--force]
#   kinds: rule, skill, command, subagent
#
# Templates live in <engine>/lib/templates/content/ and use the placeholder
# {{NAME}} which is substituted with the provided name.

# ── Private helpers ───────────────────────────────────────────────────────────

_add_print_usage() {
    echo "$(_red "Error"): agentsync add <kind> <name> [--force]" >&2
    echo "" >&2
    echo "Kinds: rule, skill, command, subagent" >&2
}

_add_validate_kind() {
    local kind="$1"
    case "$kind" in
        rule|skill|command|subagent) return 0 ;;
        *)
            echo "$(_red "Error"): Unknown kind '$kind'." >&2
            echo "Valid kinds: rule, skill, command, subagent" >&2
            return 1
            ;;
    esac
}

# Reject empty, path separators, '..', leading dot/hyphen, and anything outside
# [A-Za-z0-9_-]. Matches the safety posture of lib/helpers/paths.sh — we never
# let user input escape the .ai/src/ subtree.
_add_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "$(_red "Error"): Name is empty." >&2
        return 1
    fi
    if [[ "$name" == */* ]] || [[ "$name" == *\\* ]]; then
        echo "$(_red "Error"): Name cannot contain path separators: $name" >&2
        return 1
    fi
    if [[ "$name" == *..* ]]; then
        echo "$(_red "Error"): Name cannot contain '..': $name" >&2
        return 1
    fi
    if [[ "$name" == .* ]] || [[ "$name" == -* ]]; then
        echo "$(_red "Error"): Name cannot start with '.' or '-': $name" >&2
        return 1
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "$(_red "Error"): Name may only contain letters, digits, hyphens, and underscores: $name" >&2
        return 1
    fi
    return 0
}

# Resolve destination path for the given kind + name, relative to project_dir.
# Echoes the absolute path on stdout.
_add_resolve_dest() {
    local kind="$1"
    local name="$2"
    local project_dir="$3"

    case "$kind" in
        rule)     echo "$project_dir/.ai/src/rules/$name.md" ;;
        skill)    echo "$project_dir/.ai/src/skills/$name/SKILL.md" ;;
        command)  echo "$project_dir/.ai/src/commands/$name.md" ;;
        subagent) echo "$project_dir/.ai/src/agents/$name.md" ;;
    esac
}

# Resolve the template source path for the given kind. Echoes absolute path.
_add_resolve_template() {
    local kind="$1"
    local templates_dir="$2"
    echo "$templates_dir/${kind}.md"
}

# ── Public command ────────────────────────────────────────────────────────────

cmd_add() {
    local force=false
    local kind=""
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                exit 1
                ;;
            *)
                if [[ -z "$kind" ]]; then
                    kind="$1"
                elif [[ -z "$name" ]]; then
                    name="$1"
                else
                    echo "$(_red "Error"): Unexpected argument: $1" >&2
                    _add_print_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$kind" ]] || [[ -z "$name" ]]; then
        _add_print_usage
        exit 1
    fi

    _add_validate_kind "$kind" || exit 1
    _add_validate_name "$name" || exit 1

    local project_dir
    project_dir="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    project_dir="$(cd "$project_dir" && pwd)"

    local system_dir=""
    system_dir=$(resolve_system_dir 2>/dev/null) || {
        echo "$(_red "Error"): AgentSync engine not found." >&2
        exit 1
    }

    local templates_dir="$system_dir/templates/content"
    if [[ ! -d "$templates_dir" ]]; then
        echo "$(_red "Error"): Content templates not found at $templates_dir" >&2
        exit 1
    fi

    local template_file dest
    template_file=$(_add_resolve_template "$kind" "$templates_dir")
    dest=$(_add_resolve_dest "$kind" "$name" "$project_dir")

    if [[ ! -f "$template_file" ]]; then
        echo "$(_red "Error"): Template missing: $template_file" >&2
        exit 1
    fi

    if [[ -e "$dest" ]] && [[ "$force" != "true" ]]; then
        echo "$(_red "Error"): Already exists: $dest" >&2
        echo "" >&2
        echo "Pass $(_cyan "--force") to overwrite, or pick a different name." >&2
        exit 1
    fi

    mkdir -p "$(dirname "$dest")"

    # Substitute {{NAME}} placeholder. Name is validated to be safe shell
    # and regex input ([A-Za-z0-9_-]+), so sed substitution is safe here.
    # Using | as delimiter avoids any future path-containing placeholders.
    sed "s|{{NAME}}|$name|g" "$template_file" > "$dest"

    local rel="$dest"
    if [[ "$dest" == "$project_dir/"* ]]; then
        rel="${dest#"$project_dir/"}"
    fi

    echo ""
    _green "Created $kind:"; echo " $rel"
    echo ""
    echo "Edit the file, then run $(_cyan "agentsync sync") to propagate."
    echo ""
}
