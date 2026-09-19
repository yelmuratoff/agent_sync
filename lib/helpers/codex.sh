#!/usr/bin/env bash
# Compose a bounded MCP source with otherwise opaque Codex settings.
CODEX_MCP_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Conservative ownership guard, NOT a TOML parser. Ignore full-line comments;
# refuse mentions anywhere else and ambiguous escaped quoted/table keys.
# False positives are intentional: move MCP ownership to a single source.
codex_settings_allow_mcp() {
    local settings="$1"
    [[ -n "$settings" && -f "$settings" ]] || return 0
    LC_ALL=C awk '
        /^[ \t]*#/ { next }
        index($0, "mcp_servers") { refused=1 }
        /^[ \t]*["\047\[]/ && index($0, "\\") { refused=1 }
        END { exit refused ? 1 : 0 }
    ' "$settings"
}

sync_codex_config() {
    local settings="$1" mcp="$2" dest="$3" dry_run="${4:-false}"
    if ! codex_settings_allow_mcp "$settings"; then
        log_error "Codex MCP ownership conflict or ambiguous settings keys. Keep MCP in one source; settings must not mention mcp_servers or use escaped quoted/table keys."
        return 1
    fi
    local rendered size staging nonnul_size
    rendered=$(tmp_file agentsync_codex) || return 1
    size=$(LC_ALL=C wc -c < "$mcp") || { rm -f "$rendered"; return 1; }
    if (( size <= 33554432 )); then
        nonnul_size=$(set -o pipefail; LC_ALL=C tr -d '\000' < "$mcp" | wc -c) || { rm -f "$rendered"; return 1; }
        if (( nonnul_size != size )); then
            rm -f "$rendered"
            log_error "Codex MCP source contains a raw NUL byte."
            return 1
        fi
    fi
    if (( size > 33554432 )) || ! LC_ALL=C awk -v output_mode=codex-source \
        -v max_bytes=33554432 -v max_depth=16 \
        -f "$CODEX_MCP_HELPER_DIR/mcp_library_parser.awk" "$mcp" > "$rendered"; then
        rm -f "$rendered"
        log_error "Cannot convert Codex MCP source: only bounded command/args or HTTP url entries are supported."
        return 1
    fi
    # A root inline assignment leaves the following settings in root scope.
    # Preserve settings bytes; do not parse/reformat arbitrary TOML.
    if [[ -n "$settings" && -f "$settings" ]] && ! cat "$settings" >> "$rendered"; then
        rm -f "$rendered"
        return 1
    fi
    if [[ "$dry_run" == true ]]; then
        rm -f "$rendered"
        log_step "Would compose Codex settings and MCP → $(display_path "$dest") (dry-run)"
        return 0
    fi
    ensure_dir "${dest%/*}"
    staging=$(tmp_sibling "${dest%/*}/.agentsync_codex") || { rm -f "$rendered"; return 1; }
    if ! cp "$rendered" "$staging" || ! mv "$staging" "$dest"; then
        rm -f "$rendered" "$staging"
        return 1
    fi
    rm -f "$rendered"
    declare -f manifest_record_write >/dev/null 2>&1 && manifest_record_write "$dest"
    log_step "Codex settings + MCP → $(display_path "$dest")"
}
