#!/usr/bin/env bash
# agentsync add — scaffold new source content.
#
# Usage:
#   agentsync add <kind> <name> [--force]   kinds: rule, skill, command, subagent
#   agentsync add mcp <server>   [--url URL | --command CMD] [--args "a b c"]
#                                [--env KEY=VAL,...]  [--force]
#
# Content kinds use templates in <engine>/lib/templates/content/ with {{NAME}}
# substitution. `add mcp` edits the shared .ai/src/mcp.json, creating it on
# first use.

# ── Private helpers ───────────────────────────────────────────────────────────

_add_print_usage() {
    echo "$(_red "Error"): agentsync add <kind> <name> [options]" >&2
    echo "" >&2
    echo "Kinds: rule, skill, command, subagent, mcp" >&2
    echo "" >&2
    echo "MCP: agentsync add mcp <server> (--url URL | --command CMD [--args 'a b'] [--env K=V,...])" >&2
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
    # `add mcp …` has its own flag set — dispatch before generic parsing.
    if [[ "${1:-}" == "mcp" ]]; then
        shift
        cmd_add_mcp "$@"
        return $?
    fi

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

# ── agentsync add mcp ─────────────────────────────────────────────────────────

_add_mcp_print_usage() {
    echo "Usage: agentsync add mcp <server> (--url URL | --command CMD)" >&2
    echo "                                  [--args \"a b c\"] [--env K=V[,K=V...]]" >&2
    echo "                                  [--force]" >&2
}

cmd_add_mcp() {
    local server=""
    local url=""
    local command_str=""
    local args_str=""
    local env_str=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)     url="${2:-}";         shift 2 ;;
            --command) command_str="${2:-}"; shift 2 ;;
            --args)    args_str="${2:-}";    shift 2 ;;
            --env)     env_str="${2:-}";     shift 2 ;;
            --force|-f) force=true;          shift ;;
            -h|--help) _add_mcp_print_usage; return 0 ;;
            -*)
                echo "$(_red "Error"): Unknown flag: $1" >&2
                _add_mcp_print_usage
                exit 1
                ;;
            *)
                if [[ -z "$server" ]]; then
                    server="$1"
                    shift
                else
                    echo "$(_red "Error"): Unexpected argument: $1" >&2
                    _add_mcp_print_usage
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$server" ]]; then
        _add_mcp_print_usage
        exit 1
    fi
    _add_validate_name "$server" || exit 1

    if [[ -z "$url" ]] && [[ -z "$command_str" ]]; then
        echo "$(_red "Error"): one of --url or --command is required." >&2
        _add_mcp_print_usage
        exit 1
    fi
    if [[ -n "$url" ]] && [[ -n "$command_str" ]]; then
        echo "$(_red "Error"): --url and --command are mutually exclusive." >&2
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "$(_red "Error"): python3 is required to edit mcp.json safely." >&2
        exit 1
    fi

    local project_dir
    project_dir="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    project_dir="$(cd "$project_dir" && pwd)"

    local mcp_file="$project_dir/.ai/src/mcp.json"
    local created=false
    if [[ ! -f "$mcp_file" ]]; then
        mkdir -p "$(dirname "$mcp_file")"
        printf '{\n  "mcpServers": {}\n}\n' > "$mcp_file"
        created=true
    fi

    # Merge via python3 — safer than string concat for JSON.
    # Pass all inputs via env vars to avoid quoting pitfalls.
    local force_flag="0"
    [[ "$force" == "true" ]] && force_flag="1"

    if ! AS_MCP_FILE="$mcp_file" \
         AS_SERVER="$server" \
         AS_URL="$url" \
         AS_COMMAND="$command_str" \
         AS_ARGS="$args_str" \
         AS_ENV="$env_str" \
         AS_FORCE="$force_flag" \
         python3 - <<'PY'
import json, os, sys

path = os.environ["AS_MCP_FILE"]
server = os.environ["AS_SERVER"]
url = os.environ.get("AS_URL", "")
cmd = os.environ.get("AS_COMMAND", "")
args_str = os.environ.get("AS_ARGS", "")
env_str = os.environ.get("AS_ENV", "")
force = os.environ.get("AS_FORCE", "0") == "1"

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as exc:
    print(f"Error: {path} is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print(f"Error: {path} must be a JSON object.", file=sys.stderr)
    sys.exit(2)

servers = data.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    print("Error: 'mcpServers' must be a JSON object.", file=sys.stderr)
    sys.exit(2)

if server in servers and not force:
    print(f"Error: server '{server}' already exists. Pass --force to overwrite.", file=sys.stderr)
    sys.exit(3)

entry = {}
if url:
    entry["type"] = "http"
    entry["url"] = url
else:
    entry["command"] = cmd
    if args_str:
        entry["args"] = args_str.split()

if env_str:
    env_map = {}
    for pair in env_str.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            print(f"Error: --env entry '{pair}' must be KEY=VALUE.", file=sys.stderr)
            sys.exit(2)
        k, v = pair.split("=", 1)
        env_map[k.strip()] = v
    if env_map:
        entry["env"] = env_map

servers[server] = entry
data["mcpServers"] = servers

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    then
        exit 1
    fi

    local rel="${mcp_file#"$project_dir/"}"
    echo ""
    if [[ "$created" == "true" ]]; then
        _green "Created shared MCP source:"; echo " $rel"
    else
        _green "Updated shared MCP source:"; echo " $rel"
    fi
    _green "Added server:"; echo " $server"
    echo ""
    echo "This MCP source applies to every enabled tool on next $(_cyan "agentsync sync")."
    echo "Add a per-tool override with $(_cyan "agentsync customize <tool> mcp") if needed."
    echo ""
}
