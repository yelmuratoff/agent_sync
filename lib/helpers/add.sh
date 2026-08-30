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
# first use — the merge is pure Bash + awk, no python/jq required.

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
            --help|-h)
                cat <<'USAGE'
Usage: agentsync add <kind> <name> [--force]
       agentsync add mcp <server> (--url URL | --command CMD [--args 'a b'] [--env K=V,...])

  Scaffold a new entry under .ai/src/:
    rule       Create .ai/src/rules/<name>.md
    skill      Create .ai/src/skills/<name>/SKILL.md
    command    Create .ai/src/commands/<name>.md
    subagent   Create .ai/src/agents/<name>.md
    mcp        Add an MCP server entry to .ai/src/mcp.json

  --force, -f   Overwrite an existing file.

  Edit the scaffold, then run `agentsync sync` to propagate.
USAGE
                return 0
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

    # {{TITLE}} is the human-readable form of the name used in markdown
    # headings: hyphens become spaces and each word is capitalized
    # (`code-reviewer` → `Code Reviewer`). Without it, generated headings
    # would be lowercase kebab-case, mismatching the convention used by every
    # built-in skill (`# Commit`, `# Code Review`).
    local title
    title=$(printf '%s' "$name" | awk '{
        n = split($0, parts, "-")
        out = ""
        for (i = 1; i <= n; i++) {
            out = out (i > 1 ? " " : "") toupper(substr(parts[i], 1, 1)) substr(parts[i], 2)
        }
        print out
    }')

    # Substitute template placeholders. Name is validated to be safe shell
    # and regex input ([A-Za-z0-9_-]+), so sed substitution is safe here.
    # YAML frontmatter uses valid sentinel names so diagnostics can parse the
    # template files before substitution. The skill template lives under the
    # `content` folder, so its sentinel name matches that parent directory.
    sed \
        -e "s|{{TITLE}}|$title|g" \
        -e "s|{{NAME}}|$name|g" \
        -e "s|^name: \"content\"$|name: \"$name\"|" \
        -e "s|^name: \"template-agent\"$|name: \"$name\"|" \
        "$template_file" > "$dest"

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

_add_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Escape a raw string for embedding inside a JSON string literal.
_add_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Build a compact JSON object for one MCP server from the parsed flags.
# Echoes the JSON on stdout. Returns 1 on a malformed --env pair.
_add_mcp_build_entry() {
    local url="$1" command_str="$2" args_str="$3" env_str="$4"
    local fields=""

    if [[ -n "$url" ]]; then
        fields="\"type\": \"http\", \"url\": \"$(_add_json_escape "$url")\""
    else
        fields="\"command\": \"$(_add_json_escape "$command_str")\""
        if [[ -n "$args_str" ]]; then
            local -a argv=()
            read -ra argv <<< "$args_str"
            local arr="" a
            for a in "${argv[@]}"; do
                arr="$arr${arr:+, }\"$(_add_json_escape "$a")\""
            done
            fields="$fields, \"args\": [$arr]"
        fi
    fi

    if [[ -n "$env_str" ]]; then
        local -a pairs=()
        IFS=',' read -ra pairs <<< "$env_str"
        local envobj="" pair k v
        for pair in "${pairs[@]}"; do
            pair="$(_add_trim "$pair")"
            [[ -z "$pair" ]] && continue
            if [[ "$pair" != *"="* ]]; then
                echo "$(_red "Error"): --env entry '$pair' must be KEY=VALUE." >&2
                return 1
            fi
            k="$(_add_trim "${pair%%=*}")"
            v="${pair#*=}"
            envobj="$envobj${envobj:+, }\"$(_add_json_escape "$k")\": \"$(_add_json_escape "$v")\""
        done
        [[ -n "$envobj" ]] && fields="$fields, \"env\": {$envobj}"
    fi

    printf '{%s}' "$fields"
}

# Splice one server ENTRY (a compact JSON value) into the mcpServers object of
# $mcp_file, preserving every other server. The awk pass is string-, escape-,
# and brace-depth-aware, so it survives arbitrary sibling nesting. Output is
# re-emitted canonically (one server per line, value compacted).
# Returns 0 on success, 3 if the server exists and force is off, 1 otherwise.
_add_mcp_merge() {
    local mcp_file="$1" server="$2" entry="$3" force_flag="$4"
    local tmp rc=0
    tmp=$(tmp_sibling "$mcp_file") || return 1

    AS_SERVER="$server" AS_ENTRY="$entry" AS_FORCE="$force_flag" \
        awk '
        function is_ws(c){ return (c==" "||c=="\t"||c=="\n"||c=="\r") }
        function skip_string(s,i,   c,esc){
            i++; esc=0
            while(i<=length(s)){
                c=substr(s,i,1)
                if(esc){esc=0}
                else if(c=="\\"){esc=1}
                else if(c=="\""){return i+1}
                i++
            }
            return i
        }
        function skip_value(s,i,   c,depth,instr,esc){
            while(i<=length(s)&&is_ws(substr(s,i,1))) i++
            c=substr(s,i,1)
            if(c=="\""){ return skip_string(s,i) }
            if(c=="{"||c=="["){
                depth=0; instr=0; esc=0
                while(i<=length(s)){
                    c=substr(s,i,1)
                    if(instr){
                        if(esc){esc=0}
                        else if(c=="\\"){esc=1}
                        else if(c=="\""){instr=0}
                    } else if(c=="\""){instr=1}
                    else if(c=="{"||c=="["){depth++}
                    else if(c=="}"||c=="]"){depth--; if(depth==0) return i+1}
                    i++
                }
                return i
            }
            while(i<=length(s)){
                c=substr(s,i,1)
                if(c==","||c=="}"||c=="]"||is_ws(c)) break
                i++
            }
            return i
        }
        function compact(v,   out,i,c,instr,esc,L){
            out=""; instr=0; esc=0; L=length(v)
            for(i=1;i<=L;i++){
                c=substr(v,i,1)
                if(instr){
                    out=out c
                    if(esc){esc=0}
                    else if(c=="\\"){esc=1}
                    else if(c=="\""){instr=0}
                } else if(c=="\""){ instr=1; out=out c }
                else if(!is_ws(c)){ out=out c }
            }
            return out
        }
        BEGIN{
            SERVER=ENVIRON["AS_SERVER"]
            ENTRY=ENVIRON["AS_ENTRY"]
            FORCE=(ENVIRON["AS_FORCE"]=="1")
            s=""
        }
        { s = s $0 "\n" }
        END{
            k=index(s,"\"mcpServers\"")
            if(k==0){
                printf("{\n  \"mcpServers\": {\n    \"%s\": %s\n  }\n}\n", SERVER, compact(ENTRY))
                exit 0
            }
            j=k+length("\"mcpServers\"")
            while(is_ws(substr(s,j,1))) j++
            if(substr(s,j,1)==":") j++
            while(is_ws(substr(s,j,1))) j++
            if(substr(s,j,1)!="{"){ exit 2 }
            objStart=j
            objEnd=skip_value(s,j)
            n=0
            p=objStart+1
            while(p<objEnd-1){
                c=substr(s,p,1)
                if(is_ws(c)||c==","){ p++; continue }
                if(c!="\"") break
                keyStart=p
                keyEndPast=skip_string(s,p)
                q=keyEndPast
                while(is_ws(substr(s,q,1))) q++
                if(substr(s,q,1)==":") q++
                while(is_ws(substr(s,q,1))) q++
                valStart=q
                valEndPast=skip_value(s,q)
                n++
                names[n]=substr(s,keyStart+1,keyEndPast-keyStart-2)
                vals[n]=substr(s,valStart,valEndPast-valStart)
                p=valEndPast
            }
            found=0
            for(i=1;i<=n;i++){ if(names[i]==SERVER){ found=i; break } }
            if(found>0 && !FORCE) exit 3
            if(found>0){ vals[found]=ENTRY }
            else { n++; names[n]=SERVER; vals[n]=ENTRY }
            printf("{\n  \"mcpServers\": {")
            for(i=1;i<=n;i++){
                printf("\n    \"%s\": %s%s", names[i], compact(vals[i]), (i<n?",":""))
            }
            printf("\n  }\n}\n")
            exit 0
        }
        ' "$mcp_file" > "$tmp" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        mv "$tmp" "$mcp_file"
        return 0
    fi
    rm -f "$tmp"
    return "$rc"
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

    local entry
    entry=$(_add_mcp_build_entry "$url" "$command_str" "$args_str" "$env_str") || exit 1

    local force_flag="0"
    [[ "$force" == "true" ]] && force_flag="1"

    local rc=0
    _add_mcp_merge "$mcp_file" "$server" "$entry" "$force_flag" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 3 ]]; then
            echo "$(_red "Error"): server '$server' already exists. Pass --force to overwrite." >&2
        else
            echo "$(_red "Error"): failed to update $mcp_file" >&2
        fi
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
