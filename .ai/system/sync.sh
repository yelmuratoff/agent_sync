#!/usr/bin/env bash
# chmod +x .ai/sync/sync.sh
# Cross-platform AgentSync Config Sync Script
# Works in Git Bash on Windows and Unix/macOS

set -euo pipefail

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
REPO_ROOT_CANONICAL="$(cd -P "$REPO_ROOT" && pwd)"

# Source helper libraries
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=lib/files.sh
source "$SCRIPT_DIR/lib/files.sh"
# shellcheck source=lib/yaml.sh
source "$SCRIPT_DIR/lib/yaml.sh"
# shellcheck source=lib/gitignore.sh
source "$SCRIPT_DIR/lib/gitignore.sh"

# Global variables
DRY_RUN="false"
ONLY_TOOLS=""
SKIP_TOOLS=""
SKIP_POST_SYNC="${AGENTSYNC_SKIP_POST_SYNC:-false}"
ALLOW_POST_SYNC="${AGENTSYNC_ALLOW_POST_SYNC:-false}"
SYNCED_COUNT=0
SKIPPED_COUNT=0
TOTAL_COUNT=0
PROJECT_CONFIG_PATH=""
SOURCE_AGENTS=""
SOURCE_RULES=""
SOURCE_SKILLS=""
SOURCE_TOOLS=""
DETECTED_SOURCE_AGENTS=""
DETECTED_SOURCE_RULES=""
DETECTED_SOURCE_SKILLS=""
DETECTED_SOURCE_TOOLS=""

# Usage information
usage() {
    cat << EOF
AgentSync Config Sync Script

Usage: $(basename "$0") [OPTIONS]

Options:
  --only <tools>    Sync only specified tools (comma-separated)
                    Example: --only copilot,cursor
  --skip <tools>    Skip specified tools (comma-separated)
                    Example: --skip gemini,codex
  --dry-run         Show what would be copied without making changes
  --help            Show this help message

Examples:
  $(basename "$0")                       # Sync all enabled tools
  $(basename "$0") --only copilot,cursor # Sync only Copilot and Cursor
  $(basename "$0") --skip gemini         # Sync all except Gemini
  $(basename "$0") --dry-run             # Preview changes without applying
EOF
}

# Resolve project config path
# Priority:
# 1) AGENTSYNC_CONFIG_PATH env var (absolute or relative to REPO_ROOT)
# 2) REPO_ROOT/agent_sync.yaml
resolve_project_config_path() {
    local config_env="${AGENTSYNC_CONFIG_PATH:-}"
    if [[ -n "$config_env" ]]; then
        local env_path="$config_env"
        if [[ "$env_path" != /* ]]; then
            env_path="$REPO_ROOT/$env_path"
        fi

        if [[ -f "$env_path" ]]; then
            PROJECT_CONFIG_PATH="$env_path"
            return 0
        fi

        log_warning "AGENTSYNC_CONFIG_PATH is set but file not found: $env_path"
    fi

    local project_config="$REPO_ROOT/agent_sync.yaml"
    if [[ -f "$project_config" ]]; then
        PROJECT_CONFIG_PATH="$project_config"
    fi
}

# Auto-detect source layout inside target project
detect_source_layout() {
    # Legacy/default layout
    if [[ -f "$REPO_ROOT/.ai/src/AGENTS.md" ]]; then
        DETECTED_SOURCE_AGENTS=".ai/src/AGENTS.md"
        DETECTED_SOURCE_RULES=".ai/src/rules"
        DETECTED_SOURCE_SKILLS=".ai/src/skills"
        DETECTED_SOURCE_TOOLS=".ai/src/tools"
        return 0
    fi

    # Flat layout
    local flat_agents=""
    local candidates=(
        ".ai/AGENTS.md"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$REPO_ROOT/$candidate" ]]; then
            flat_agents="$candidate"
            break
        fi
    done

    if [[ -n "$flat_agents" ]] && [[ -d "$REPO_ROOT/.ai/tools" ]]; then
        DETECTED_SOURCE_AGENTS="$flat_agents"
        DETECTED_SOURCE_RULES=".ai/rules"
        DETECTED_SOURCE_SKILLS=".ai/skills"
        DETECTED_SOURCE_TOOLS=".ai/tools"
        return 0
    fi

    return 1
}

# Resolve source path from project config (supports both root keys and source.* keys)
resolve_source_override() {
    local key="$1"

    if [[ -z "$PROJECT_CONFIG_PATH" ]]; then
        echo ""
        return 0
    fi

    local nested direct
    nested=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "source.$key") || true
    if [[ -n "$nested" ]]; then
        echo "$nested"
        return 0
    fi

    direct=$(parse_yaml_value "$PROJECT_CONFIG_PATH" "$key") || true
    echo "$direct"
}

# Normalize a path lexically into an absolute path.
# Works even if the target does not exist yet.
normalize_absolute_path() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        path="$REPO_ROOT/$path"
    fi

    local -a segments normalized_segments
    IFS='/' read -r -a segments <<< "$path"
    normalized_segments=()

    local segment
    for segment in "${segments[@]}"; do
        case "$segment" in
            ""|".")
                continue
                ;;
            "..")
                if [[ ${#normalized_segments[@]} -gt 0 ]]; then
                    unset 'normalized_segments[${#normalized_segments[@]}-1]'
                fi
                ;;
            *)
                normalized_segments+=("$segment")
                ;;
        esac
    done

    local normalized="/"
    if [[ ${#normalized_segments[@]} -gt 0 ]]; then
        normalized="/${normalized_segments[0]}"
        local index
        for ((index = 1; index < ${#normalized_segments[@]}; index++)); do
            normalized="$normalized/${normalized_segments[$index]}"
        done
    fi

    echo "$normalized"
}

is_path_within_repo_root() {
    local candidate_path="$1"
    [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]
}

resolve_existing_ancestor() {
    local path="$1"
    local current="$path"
    while [[ ! -e "$current" ]]; do
        local parent
        parent=$(dirname "$current")
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
    done

    echo "$current"
}

canonicalize_with_existing_ancestor() {
    local path="$1"
    local existing_ancestor
    existing_ancestor=$(resolve_existing_ancestor "$path")

    local existing_ancestor_canonical
    if [[ -d "$existing_ancestor" ]]; then
        existing_ancestor_canonical=$(cd -P "$existing_ancestor" 2>/dev/null && pwd) || return 1
    else
        local ancestor_parent
        ancestor_parent=$(dirname "$existing_ancestor")
        local ancestor_parent_canonical
        ancestor_parent_canonical=$(cd -P "$ancestor_parent" 2>/dev/null && pwd) || return 1
        existing_ancestor_canonical="$ancestor_parent_canonical/$(basename "$existing_ancestor")"
    fi

    if [[ "$path" == "$existing_ancestor" ]]; then
        echo "$existing_ancestor_canonical"
        return 0
    fi

    local suffix="${path#"$existing_ancestor"}"
    if [[ -n "$suffix" ]] && [[ "$suffix" != /* ]]; then
        suffix="/$suffix"
    fi

    normalize_absolute_path "$existing_ancestor_canonical$suffix"
}

resolve_dest_path() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    local abs_path
    abs_path=$(normalize_absolute_path "$raw_path")
    local canonical_path
    canonical_path=$(canonicalize_with_existing_ancestor "$abs_path") || {
        log_error "Failed to canonicalize $label path: $raw_path"
        return 1
    }

    if ! is_path_within_repo_root "$canonical_path"; then
        log_error "$label resolves outside repository root: $raw_path -> $canonical_path"
        return 1
    fi

    echo "$abs_path"
}

is_path_safe_source() {
    local candidate_path="$1"
    if [[ "$candidate_path" == "$REPO_ROOT_CANONICAL" || "$candidate_path" == "$REPO_ROOT_CANONICAL/"* ]]; then
        return 0
    fi
    if [[ "$candidate_path" == "$DEFAULT_REPO_ROOT" || "$candidate_path" == "$DEFAULT_REPO_ROOT/"* ]]; then
        return 0
    fi
    return 1
}

resolve_source_path() {
    local raw_path="$1"
    local label="$2"

    if [[ -z "$raw_path" ]]; then
        log_error "$label is empty"
        return 1
    fi

    # First try resolving relative to REPO_ROOT (the user project)
    local abs_path_target
    abs_path_target=$(normalize_absolute_path "$raw_path")
    local canonical_path_target
    canonical_path_target=$(canonicalize_with_existing_ancestor "$abs_path_target") 2>/dev/null || true

    if [[ -n "$canonical_path_target" ]] && [[ -e "$canonical_path_target" ]] && is_path_safe_source "$canonical_path_target"; then
        echo "$abs_path_target"
        return 0
    fi

    # Fallback to DEFAULT_REPO_ROOT (the shipped package templates)
    local abs_path_fallback
    if [[ "$raw_path" == /* ]]; then
        abs_path_fallback="$raw_path"
    else
        abs_path_fallback="$DEFAULT_REPO_ROOT/$raw_path"
    fi
    
    local canonical_path_fallback
    canonical_path_fallback=$(canonicalize_with_existing_ancestor "$abs_path_fallback") 2>/dev/null || true
    
    if [[ -n "$canonical_path_fallback" ]] && is_path_safe_source "$canonical_path_fallback"; then
        echo "$abs_path_fallback"
        return 0
    fi

    # If neither exists/valid, log error based on the primary target
    if [[ -n "$canonical_path_target" ]]; then
        if ! is_path_safe_source "$canonical_path_target"; then
            log_error "$label resolves outside safe source roots: $raw_path -> $canonical_path_target"
            return 1
        fi
    fi

    echo "$abs_path_target"
    return 0
}

to_repo_relative_path() {
    local abs_path="$1"
    if [[ "$abs_path" == "$REPO_ROOT" ]]; then
        echo "."
        return 0
    fi

    if [[ "$abs_path" == "$REPO_ROOT/"* ]]; then
        echo "${abs_path#$REPO_ROOT/}"
        return 0
    fi

    log_error "Path is outside repository root: $abs_path"
    return 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)
                if [[ $# -lt 2 ]] || [[ "${2:-}" == --* ]]; then
                    log_error "Option --only requires a comma-separated value"
                    usage
                    exit 1
                fi
                ONLY_TOOLS="$2"
                shift 2
                ;;
            --skip)
                if [[ $# -lt 2 ]] || [[ "${2:-}" == --* ]]; then
                    log_error "Option --skip requires a comma-separated value"
                    usage
                    exit 1
                fi
                SKIP_TOOLS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Check if tool should be synced based on CLI filters
should_sync_tool() {
    local tool_name="$1"
    
    # Check --only filter
    if [[ -n "$ONLY_TOOLS" ]]; then
        if [[ ! ",$ONLY_TOOLS," == *",$tool_name,"* ]]; then
            return 1
        fi
    fi
    
    # Check --skip filter
    if [[ -n "$SKIP_TOOLS" ]]; then
        if [[ ",$SKIP_TOOLS," == *",$tool_name,"* ]]; then
            return 1
        fi
    fi
    
    return 0
}

read_tool_enabled_flag() {
    local tool_config="$1"
    local tool_name="$2"

    local enabled_value=""
    enabled_value=$(parse_yaml_bool_strict "$tool_config" "enabled")
    local parse_status=$?
    if [[ $parse_status -ne 0 ]]; then
        case "$parse_status" in
            2)
                log_error "Tool config is missing required boolean 'enabled': $tool_config ($tool_name)"
                ;;
            3)
                local raw_value
                raw_value=$(parse_yaml_value "$tool_config" "enabled")
                log_error "Invalid boolean for 'enabled' in $tool_config ($tool_name): '$raw_value'"
                ;;
            *)
                log_error "Failed to parse 'enabled' from $tool_config ($tool_name)"
                ;;
        esac
        return 1
    fi

    echo "$enabled_value"
}

run_post_sync_hook() {
    local tool_name="$1"
    local post_sync_cmd="$2"

    if [[ -z "$post_sync_cmd" ]]; then
        return 0
    fi

    if [[ "$SKIP_POST_SYNC" == "true" ]]; then
        log_info "Skipping post-sync hook for $tool_name (AGENTSYNC_SKIP_POST_SYNC=true)"
        return 0
    fi

    if [[ "$ALLOW_POST_SYNC" != "true" ]]; then
        log_warning "Skipping post-sync hook for $tool_name (set AGENTSYNC_ALLOW_POST_SYNC=true to enable)"
        return 0
    fi

    log_info "Running post-sync hook: $post_sync_cmd"
    # Execute once through bash without eval to avoid re-parsing command input.
    if ! (cd "$REPO_ROOT" && bash -lc "$post_sync_cmd"); then
        log_warning "Post-sync hook failed"
        return 1
    fi

    return 0
}

# Sync a single tool based on its YAML config
sync_tool() {
    local tool_config="$1"
    local tool_basename
    tool_basename=$(basename "$tool_config" .yaml)
    
    # Read tool configuration
    local tool_name
    tool_name=$(parse_yaml_value "$tool_config" "name")
    [[ -z "$tool_name" ]] && tool_name="$tool_basename"
    
    # Read target destinations (once, reused for both cleanup and sync)
    local dest_agents dest_rules dest_skills
    dest_agents=$(parse_yaml_value "$tool_config" "targets.agents.dest")
    dest_rules=$(parse_yaml_value "$tool_config" "targets.rules.dest")
    dest_skills=$(parse_yaml_value "$tool_config" "targets.skills.dest")

    local dest_agents_abs="" dest_rules_abs="" dest_skills_abs=""
    [[ -n "$dest_agents" ]] && dest_agents_abs=$(resolve_dest_path "$dest_agents" "targets.agents.dest for $tool_name")
    [[ -n "$dest_rules" ]] && dest_rules_abs=$(resolve_dest_path "$dest_rules" "targets.rules.dest for $tool_name")
    [[ -n "$dest_skills" ]] && dest_skills_abs=$(resolve_dest_path "$dest_skills" "targets.skills.dest for $tool_name")

    local enabled_value
    enabled_value=$(read_tool_enabled_flag "$tool_config" "$tool_name") || return 1

    # Check if tool is enabled in config
    if [[ "$enabled_value" == "false" ]]; then
        # Cleanup disabled tool directories
        local cleaned=false
        [[ -n "$dest_agents_abs" ]] && cleanup_path "$dest_agents_abs" "$DRY_RUN" && cleaned=true
        [[ -n "$dest_rules_abs" ]] && cleanup_path "$dest_rules_abs" "$DRY_RUN" && cleaned=true
        [[ -n "$dest_skills_abs" ]] && cleanup_path "$dest_skills_abs" "$DRY_RUN" && cleaned=true
        
        if [[ "$cleaned" == "true" ]]; then
            log_info "Cleaned up $tool_name (disabled)"
        else
            log_info "Skipping $tool_name (disabled in config)"
        fi
        ((SKIPPED_COUNT++)) || true
        return 0
    fi
    
    # Check CLI filters
    if ! should_sync_tool "$tool_basename"; then
        log_info "Skipping $tool_name (filtered by CLI)"
        ((SKIPPED_COUNT++)) || true
        return 0
    fi
    
    log_info "Syncing $tool_name..."
    
    # 1. AGENTS
    # Check for override
    local override_agents src_agents
    override_agents=$(parse_yaml_value "$tool_config" "targets.agents.source")
    src_agents="${override_agents:-$SOURCE_AGENTS}"
    local src_agents_abs
    src_agents_abs=$(resolve_source_path "$src_agents" "targets.agents.source for $tool_name")
    
    # Sync AGENTS.md
    if [[ -n "$dest_agents_abs" ]]; then
        copy_file "$src_agents_abs" "$dest_agents_abs" "$DRY_RUN"
    fi
    
    # 2. RULES
    # Check for override
    local override_rules src_rules
    override_rules=$(parse_yaml_value "$tool_config" "targets.rules.source")
    src_rules="${override_rules:-$SOURCE_RULES}"
    local src_rules_abs
    src_rules_abs=$(resolve_source_path "$src_rules" "targets.rules.source for $tool_name")
    
    # Read optional rule transformations and filters
    local rule_ext rule_header append_imports rule_include rule_exclude
    rule_ext=$(parse_yaml_value "$tool_config" "targets.rules.extension") || true
    rule_header=$(parse_yaml_value "$tool_config" "targets.rules.header") || true
    append_imports=$(parse_yaml_value "$tool_config" "targets.rules.append_imports") || true
    rule_include=$(parse_yaml_value "$tool_config" "targets.rules.include") || true
    rule_exclude=$(parse_yaml_value "$tool_config" "targets.rules.exclude") || true
    
    # Sync rules
    if [[ -n "$dest_rules_abs" ]]; then
        sync_rules "$src_rules_abs" "$dest_rules_abs" "$rule_ext" "$rule_header" "$DRY_RUN" "$rule_include" "$rule_exclude"
        
        # Handle Claude's import appending
        if [[ "$append_imports" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
            if [[ -n "$dest_agents_abs" ]]; then
                # Note: Imports should technically only include filtered rules, but append_imports scans the DEST dir
                # so it naturally picks up only what was copied. Correct.
                append_imports "$dest_agents_abs" "$dest_rules_abs"
                log_step "Appended @rules imports to $dest_agents"
            else
                log_warning "Skipping append_imports for $tool_name because targets.agents.dest is missing"
            fi
        fi
    fi
    
    # 3. SKILLS
    # Check for override
    local override_skills src_skills
    override_skills=$(parse_yaml_value "$tool_config" "targets.skills.source")
    src_skills="${override_skills:-$SOURCE_SKILLS}"
    local src_skills_abs
    src_skills_abs=$(resolve_source_path "$src_skills" "targets.skills.source for $tool_name")
    
    # Read skill filters
    local skills_include skills_exclude
    skills_include=$(parse_yaml_value "$tool_config" "targets.skills.include") || true
    skills_exclude=$(parse_yaml_value "$tool_config" "targets.skills.exclude") || true
    
    # Sync skills directory
    if [[ -n "$dest_skills_abs" ]]; then
        sync_dir "$src_skills_abs" "$dest_skills_abs" "$DRY_RUN" "$skills_include" "$skills_exclude"
    fi
    
    # 4. POST_SYNC
    local post_sync_cmd
    post_sync_cmd=$(parse_yaml_value "$tool_config" "post_sync") || true
    
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! run_post_sync_hook "$tool_name" "$post_sync_cmd"; then
            log_error "Sync failed because post-sync hook failed for $tool_name"
            return 1
        fi
    fi
     
    log_success "$tool_name complete"
    ((SYNCED_COUNT++)) || true
}

# Main entry point
main() {
    parse_args "$@"
    
    log_separator
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Starting AgentSync Config Sync (DRY RUN)..."
    else
        log_info "Starting AgentSync Config Sync..."
    fi
    log_separator
    echo ""
    
    # Verify base config exists
    local global_config="$SCRIPT_DIR/config.yaml"
    if [[ ! -f "$global_config" ]]; then
        log_error "Global config not found: $global_config"
        exit 1
    fi

    # Resolve project config and detect source layout
    resolve_project_config_path
    if detect_source_layout; then
        SOURCE_AGENTS="$DETECTED_SOURCE_AGENTS"
        SOURCE_RULES="$DETECTED_SOURCE_RULES"
        SOURCE_SKILLS="$DETECTED_SOURCE_SKILLS"
        SOURCE_TOOLS="$DETECTED_SOURCE_TOOLS"
    else
        SOURCE_AGENTS=$(parse_yaml_value "$global_config" "source.agents")
        SOURCE_RULES=$(parse_yaml_value "$global_config" "source.rules")
        SOURCE_SKILLS=$(parse_yaml_value "$global_config" "source.skills")
        SOURCE_TOOLS=$(parse_yaml_value "$global_config" "source.tools")
    fi

    # Apply optional project-level overrides from agent_sync.yaml
    local override_agents override_rules override_skills override_tools
    override_agents=$(resolve_source_override "agents")
    override_rules=$(resolve_source_override "rules")
    override_skills=$(resolve_source_override "skills")
    override_tools=$(resolve_source_override "tools")

    [[ -n "$override_agents" ]] && SOURCE_AGENTS="$override_agents"
    [[ -n "$override_rules" ]] && SOURCE_RULES="$override_rules"
    [[ -n "$override_skills" ]] && SOURCE_SKILLS="$override_skills"
    [[ -n "$override_tools" ]] && SOURCE_TOOLS="$override_tools"

    if [[ -z "$SOURCE_TOOLS" ]]; then
        SOURCE_TOOLS=".ai/system/tools"
        log_warning "source.tools is not set, falling back to $SOURCE_TOOLS"
    fi

    local source_agents_abs source_tools_abs
    source_agents_abs=$(resolve_source_path "$SOURCE_AGENTS" "source.agents")
    source_tools_abs=$(resolve_source_path "$SOURCE_TOOLS" "source.tools")

    if [[ ! -f "$source_agents_abs" ]]; then
        log_error "Source agents file not found: $source_agents_abs"
        log_error "Expected either .ai/src layout, .ai layout, or agent_sync.yaml overrides"
        exit 1
    fi

    local tools_dir_abs="$source_tools_abs"
    if [[ ! -d "$tools_dir_abs" ]]; then
        log_error "Tool config directory not found: $source_tools_abs"
        log_error "Set source.tools in agent_sync.yaml if your layout is custom"
        exit 1
    fi

    # Process each tool config
    local -a generated_paths=()
    for tool_config in "$tools_dir_abs"/*.yaml; do
        [[ -f "$tool_config" ]] || continue
        local tool_file_basename
        tool_file_basename=$(basename "$tool_config")
        if [[ "$tool_file_basename" == _* ]]; then
            continue
        fi
        ((TOTAL_COUNT++)) || true
        
        # Check enabled status for gitignore collection even if skipping sync (for dry-run accuracy we might need to think, 
        # but here we follow config truth)
        local enabled_value
        enabled_value=$(read_tool_enabled_flag "$tool_config" "$tool_file_basename") || exit 1
        if [[ "$enabled_value" == "true" ]]; then
             # Collect paths for gitignore
             local d_agents d_rules d_skills d_agents_abs d_rules_abs d_skills_abs
             local d_agents_rel d_rules_rel d_skills_rel
             d_agents=$(parse_yaml_value "$tool_config" "targets.agents.dest")
             d_rules=$(parse_yaml_value "$tool_config" "targets.rules.dest")
             d_skills=$(parse_yaml_value "$tool_config" "targets.skills.dest")

             if [[ -n "$d_agents" ]]; then
                 d_agents_abs=$(resolve_dest_path "$d_agents" "targets.agents.dest in $tool_file_basename")
                 d_agents_rel=$(to_repo_relative_path "$d_agents_abs")
                 generated_paths+=("$d_agents_rel")
             fi
             if [[ -n "$d_rules" ]]; then
                 d_rules_abs=$(resolve_dest_path "$d_rules" "targets.rules.dest in $tool_file_basename")
                 d_rules_rel=$(to_repo_relative_path "$d_rules_abs")
                 generated_paths+=("$d_rules_rel/")
             fi
             if [[ -n "$d_skills" ]]; then
                 d_skills_abs=$(resolve_dest_path "$d_skills" "targets.skills.dest in $tool_file_basename")
                 d_skills_rel=$(to_repo_relative_path "$d_skills_abs")
                 generated_paths+=("$d_skills_rel/")
             fi
        fi

        sync_tool "$tool_config"
        echo ""
    done
    
    # Update .gitignore if not dry-run
    if [[ "$DRY_RUN" != "true" ]]; then
        log_separator
        log_info "Updating .gitignore..."
        local generated_paths_payload=""
        if [[ ${#generated_paths[@]} -gt 0 ]]; then
            generated_paths_payload=$(printf '%s\n' "${generated_paths[@]}")
        fi
        update_gitignore "$REPO_ROOT/.gitignore" "$generated_paths_payload"
    fi
    
    # Print summary
    log_separator
    local summary="Synced $SYNCED_COUNT/$TOTAL_COUNT tools"
    if [[ $SKIPPED_COUNT -gt 0 ]]; then
        summary="$summary ($SKIPPED_COUNT skipped)"
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        summary="$summary (dry-run)"
    fi
    log_done "$summary"
    log_separator
}

main "$@"
