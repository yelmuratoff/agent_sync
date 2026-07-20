#!/usr/bin/env bash

OPENCODE_JSON_DIAGNOSTIC=""

_opencode_compose_json() {
    local settings_src="$1"
    local mcp_src="$2"
    local output="$3"
    local mode="${4:-compose}"
    local diagnostic_file
    diagnostic_file=$(mktemp "${TMPDIR:-/tmp}/agentsync_opencode_diag.XXXXXX") || return 1

    local rc=0
    awk -v settings_path="$settings_src" -v mcp_path="$mcp_src" -v diagnostic_path="$diagnostic_file" -v mode="$mode" '
function fail(code, message) {
    if (error_code == 0) {
        error_code = code
        error_message = message
    }
    return 0
}

function read_file(path,    line, content, status) {
    content = ""
    while ((status = getline line < path) > 0) {
        content = content line "\n"
    }
    close(path)
    if (status < 0) {
        fail(1, "cannot read " path)
    }
    return content
}

function skip_space() {
    while (position <= length(json) && substr(json, position, 1) ~ /[[:space:]]/) {
        position++
    }
}

function decode_unicode_escape(hex,    digits, value, i, digit) {
    digits = "0123456789abcdef"
    value = 0
    for (i = 1; i <= 4; i++) {
        digit = index(digits, tolower(substr(hex, i, 1))) - 1
        value = value * 16 + digit
    }
    if (value <= 127) return sprintf("%c", value)
    return "\\u" hex
}

function parse_string(    start, char, escape, hex, decoded) {
    if (substr(json, position, 1) != "\"") return fail(active_error, "expected a JSON string")
    start = position++
    decoded = ""
    while (position <= length(json)) {
        char = substr(json, position, 1)
        if (char == "\"") {
            position++
            last_raw = substr(json, start, position - start)
            last_string = decoded
            return 1
        }
        if (char == "\\") {
            position++
            if (position > length(json)) return fail(active_error, "unterminated JSON escape")
            escape = substr(json, position, 1)
            if (escape == "u") {
                hex = substr(json, position + 1, 4)
                if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f]{4}$/) return fail(active_error, "invalid Unicode escape")
                decoded = decoded decode_unicode_escape(hex)
                position += 5
                continue
            }
            if (escape !~ /^["\\\/bfnrt]$/) return fail(active_error, "invalid JSON escape")
            if (escape == "b") decoded = decoded "\b"
            else if (escape == "f") decoded = decoded "\f"
            else if (escape == "n") decoded = decoded "\n"
            else if (escape == "r") decoded = decoded "\r"
            else if (escape == "t") decoded = decoded "\t"
            else decoded = decoded escape
            position++
            continue
        }
        if (char ~ /[[:cntrl:]]/) return fail(active_error, "control character in JSON string")
        decoded = decoded char
        position++
    }
    return fail(active_error, "unterminated JSON string")
}

function parse_array(    char) {
    position++
    skip_space()
    if (substr(json, position, 1) == "]") {
        position++
        return 1
    }
    while (position <= length(json)) {
        if (!parse_value()) return 0
        skip_space()
        char = substr(json, position, 1)
        if (char == "]") {
            position++
            return 1
        }
        if (char != ",") return fail(active_error, "expected comma in JSON array")
        position++
        skip_space()
    }
    return fail(active_error, "unterminated JSON array")
}

function parse_object(    char) {
    position++
    skip_space()
    if (substr(json, position, 1) == "}") {
        position++
        return 1
    }
    while (position <= length(json)) {
        if (!parse_string()) return 0
        skip_space()
        if (substr(json, position, 1) != ":") return fail(active_error, "expected colon in JSON object")
        position++
        skip_space()
        if (!parse_value()) return 0
        skip_space()
        char = substr(json, position, 1)
        if (char == "}") {
            position++
            return 1
        }
        if (char != ",") return fail(active_error, "expected comma in JSON object")
        position++
        skip_space()
    }
    return fail(active_error, "unterminated JSON object")
}

function parse_value(    rest, char) {
    skip_space()
    char = substr(json, position, 1)
    if (char == "\"") return parse_string()
    if (char == "{") return parse_object()
    if (char == "[") return parse_array()
    rest = substr(json, position)
    if (substr(rest, 1, 4) == "true" && substr(rest, 5, 1) !~ /[[:alnum:]_]/) {
        position += 4
        return 1
    }
    if (substr(rest, 1, 5) == "false" && substr(rest, 6, 1) !~ /[[:alnum:]_]/) {
        position += 5
        return 1
    }
    if (substr(rest, 1, 4) == "null" && substr(rest, 5, 1) !~ /[[:alnum:]_]/) {
        position += 4
        return 1
    }
    if (match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
        position += RLENGTH
        return 1
    }
    return fail(active_error, "invalid JSON value")
}

function store_member(mode, key, raw_key, raw_value,    i) {
    if (mode == "settings") {
        for (i = 1; i <= settings_count; i++) {
            if (settings_key[i] == key) return fail(20, "duplicate settings field \047" key "\047")
        }
        settings_count++
        settings_key[settings_count] = key
        settings_raw_key[settings_count] = raw_key
        settings_value[settings_count] = raw_value
    } else if (mode == "canonical") {
        for (i = 1; i <= canonical_count; i++) {
            if (canonical_key[i] == key) return fail(active_error, "duplicate canonical MCP field \047" key "\047")
        }
        canonical_count++
        canonical_key[canonical_count] = key
        canonical_raw_key[canonical_count] = raw_key
        canonical_value[canonical_count] = raw_value
    } else if (mode == "server") {
        for (i = 1; i <= server_field_count; i++) {
            if (server_field_key[i] == key) return fail(23, "duplicate server field \047" key "\047")
        }
        server_field_count++
        server_field_key[server_field_count] = key
        server_field_value[server_field_count] = raw_value
    }
}

function walk_root(text, mode, code,    char, key_start, key, raw_key, value_start, raw_value) {
    json = text
    position = 1
    active_error = code
    skip_space()
    if (substr(json, position, 1) != "{") return fail(code, "root value must be an object")
    position++
    skip_space()
    if (substr(json, position, 1) == "}") {
        position++
        skip_space()
        return position > length(json)
    }
    while (position <= length(json)) {
        key_start = position
        if (!parse_string()) return 0
        key = last_string
        raw_key = substr(json, key_start, position - key_start)
        skip_space()
        if (substr(json, position, 1) != ":") return fail(code, "expected colon after object key")
        position++
        skip_space()
        value_start = position
        if (!parse_value()) return 0
        raw_value = substr(json, value_start, position - value_start)
        store_member(mode, key, raw_key, raw_value)
        skip_space()
        char = substr(json, position, 1)
        if (char == "}") {
            position++
            skip_space()
            if (position <= length(json)) return fail(code, "trailing content after JSON object")
            return 1
        }
        if (char != ",") return fail(code, "expected comma in JSON object")
        position++
        skip_space()
    }
    return fail(code, "unterminated JSON object")
}

function json_kind(raw,    first) {
    sub(/^[[:space:]]+/, "", raw)
    first = substr(raw, 1, 1)
    if (first == "\"") return "string"
    if (first == "{") return "object"
    if (first == "[") return "array"
    if (raw ~ /^(true|false)[[:space:]]*$/) return "boolean"
    if (raw ~ /^null[[:space:]]*$/) return "null"
    return "number"
}

function decode_string(raw, saved_json, saved_position, saved_error, result) {
    saved_json = json
    saved_position = position
    saved_error = active_error
    json = raw
    position = 1
    active_error = 23
    if (!parse_string()) return ""
    result = last_string
    json = saved_json
    position = saved_position
    active_error = saved_error
    return result
}

function validate_string_array(raw, server_name, field_name,    char, start, item) {
    json = raw
    position = 2
    active_error = 23
    skip_space()
    if (substr(json, position, 1) == "]") return 1
    while (position <= length(json)) {
        start = position
        if (!parse_value()) return 0
        item = substr(json, start, position - start)
        if (json_kind(item) != "string") return fail(23, "server \047" server_name "\047 field \047" field_name "\047 must contain only strings")
        skip_space()
        char = substr(json, position, 1)
        if (char == "]") return 1
        if (char != ",") return fail(23, "server \047" server_name "\047 field \047" field_name "\047 is invalid")
        position++
        skip_space()
    }
    return fail(23, "server \047" server_name "\047 field \047" field_name "\047 is invalid")
}

function validate_string_map(raw, server_name, field_name,    char, value_start, value) {
    json = raw
    position = 2
    active_error = 23
    skip_space()
    if (substr(json, position, 1) == "}") return 1
    while (position <= length(json)) {
        if (!parse_string()) return 0
        skip_space()
        if (substr(json, position, 1) != ":") return fail(23, "server \047" server_name "\047 field \047" field_name "\047 is invalid")
        position++
        skip_space()
        value_start = position
        if (!parse_value()) return 0
        value = substr(json, value_start, position - value_start)
        if (json_kind(value) != "string") return fail(23, "server \047" server_name "\047 field \047" field_name "\047 values must be strings")
        skip_space()
        char = substr(json, position, 1)
        if (char == "}") return 1
        if (char != ",") return fail(23, "server \047" server_name "\047 field \047" field_name "\047 is invalid")
        position++
        skip_space()
    }
    return fail(23, "server \047" server_name "\047 field \047" field_name "\047 is invalid")
}

function array_inner(raw,    value) {
    value = raw
    sub(/^[[:space:]]*\[[[:space:]]*/, "", value)
    sub(/[[:space:]]*\][[:space:]]*$/, "", value)
    return value
}

function append_property(output, name, value) {
    if (output != "") output = output ", "
    return output "\"" name "\": " value
}

function convert_server(raw_key, raw_value,    i, field, value, kind, command, url, type, args, env, headers, enabled, timeout, oauth, output, inner, clear_index) {
    for (clear_index in server_field_key) delete server_field_key[clear_index]
    for (clear_index in server_field_value) delete server_field_value[clear_index]
    server_field_count = 0
    if (!walk_root(raw_value, "server", 23)) return ""
    for (i = 1; i <= server_field_count; i++) {
        field = server_field_key[i]
        value = server_field_value[i]
        kind = json_kind(value)
        if (field == "command") {
            if (kind != "string") return fail(23, "server \047" raw_key "\047 field \047command\047 must be a string")
            command = value
        } else if (field == "url") {
            if (kind != "string") return fail(23, "server \047" raw_key "\047 field \047url\047 must be a string")
            url = value
        } else if (field == "args") {
            if (kind != "array") return fail(23, "server \047" raw_key "\047 field \047args\047 must be an array")
            if (!validate_string_array(value, raw_key, "args")) return ""
            args = value
        } else if (field == "env") {
            if (kind != "object") return fail(23, "server \047" raw_key "\047 field \047env\047 must be an object")
            if (!validate_string_map(value, raw_key, "env")) return ""
            env = value
        } else if (field == "headers") {
            if (kind != "object") return fail(23, "server \047" raw_key "\047 field \047headers\047 must be an object")
            if (!validate_string_map(value, raw_key, "headers")) return ""
            headers = value
        } else if (field == "type") {
            if (kind != "string") return fail(23, "server \047" raw_key "\047 field \047type\047 must be a string")
            type = decode_string(value)
        } else if (field == "enabled") {
            if (kind != "boolean") return fail(23, "server \047" raw_key "\047 field \047enabled\047 must be a boolean")
            enabled = value
        } else if (field == "timeout") {
            if (kind != "number" || value !~ /^[[:space:]]*[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?[[:space:]]*$/) return fail(23, "server \047" raw_key "\047 field \047timeout\047 must be a non-negative number")
            timeout = value
        } else if (field == "oauth") {
            if (kind != "boolean" && kind != "object") return fail(23, "server \047" raw_key "\047 field \047oauth\047 must be a boolean or object")
            oauth = value
        } else {
            return fail(25, "server \047" raw_key "\047 has unsupported field \047" field "\047")
        }
    }
    if ((command != "") == (url != "")) return fail(26, "server \047" raw_key "\047 must define exactly one transport: command or url")
    if (command != "") {
        if (url != "" || headers != "" || oauth != "") return fail(25, "server \047" raw_key "\047 contains remote-only fields")
        if (type != "" && type != "stdio") return fail(23, "server \047" raw_key "\047 field \047type\047 must be stdio for a local server")
        output = append_property(output, "type", "\"local\"")
        inner = array_inner(args)
        value = "[" command
        if (inner != "") value = value ", " inner
        value = value "]"
        output = append_property(output, "command", value)
        if (env != "") output = append_property(output, "environment", env)
    } else {
        if (args != "" || env != "") return fail(25, "server \047" raw_key "\047 contains local-only fields")
        if (type != "" && type != "http" && type != "sse" && type != "streamable-http") return fail(23, "server \047" raw_key "\047 field \047type\047 is not a supported remote transport")
        output = append_property(output, "type", "\"remote\"")
        output = append_property(output, "url", url)
        if (headers != "") output = append_property(output, "headers", headers)
        if (oauth != "") output = append_property(output, "oauth", oauth)
    }
    if (enabled != "") output = append_property(output, "enabled", enabled)
    if (timeout != "") output = append_property(output, "timeout", timeout)
    return "{" output "}"
}

BEGIN {
    error_code = 0
    settings_text = read_file(settings_path)
    if (error_code == 0 && !walk_root(settings_text, "settings", 20) && error_message == "") fail(20, "malformed settings JSON")
    if (error_code != 0) {
        print error_message > diagnostic_path
        exit error_code
    }

    settings_has_mcp = 0
    for (i = 1; i <= settings_count; i++) {
        if (settings_key[i] == "mcp") settings_has_mcp = 1
    }
    if (mode == "inspect-settings") exit(settings_has_mcp ? 0 : 1)

    mcp_text = read_file(mcp_path)
    if (error_code == 0 && !walk_root(mcp_text, "canonical", 21) && error_message == "") fail(21, "malformed canonical MCP JSON")
    if (error_code != 0) {
        print error_message > diagnostic_path
        exit error_code
    }

    if (settings_has_mcp) {
        print "settings and canonical source both define OpenCode MCP ownership" > diagnostic_path
        exit 24
    }

    mcp_servers = ""
    for (i = 1; i <= canonical_count; i++) {
        if (canonical_key[i] == "mcpServers") mcp_servers = canonical_value[i]
        else {
            print "canonical MCP has unsupported top-level field \047" canonical_key[i] "\047" > diagnostic_path
            exit 25
        }
    }
    if (mcp_servers == "" || json_kind(mcp_servers) != "object") {
        print "mcpServers must be an object" > diagnostic_path
        exit 22
    }

    for (clear_index in canonical_key) delete canonical_key[clear_index]
    for (clear_index in canonical_raw_key) delete canonical_raw_key[clear_index]
    for (clear_index in canonical_value) delete canonical_value[clear_index]
    canonical_count = 0
    if (!walk_root(mcp_servers, "canonical", 23)) {
        print error_message > diagnostic_path
        exit error_code
    }
    for (i = 1; i <= canonical_count; i++) {
        if (json_kind(canonical_value[i]) != "object") {
            print "server \047" canonical_key[i] "\047 must be an object" > diagnostic_path
            exit 23
        }
        converted[i] = convert_server(canonical_key[i], canonical_value[i])
        if (error_code != 0) {
            print error_message > diagnostic_path
            exit error_code
        }
    }

    print "{"
    for (i = 1; i <= settings_count; i++) {
        printf "  %s: %s,\n", settings_raw_key[i], settings_value[i]
    }
    print "  \"mcp\": {"
    for (i = 1; i <= canonical_count; i++) {
        printf "    %s: %s%s\n", canonical_raw_key[i], converted[i], (i < canonical_count ? "," : "")
    }
    print "  }"
    print "}"
}
' > "$output" || rc=$?

    IFS= read -r OPENCODE_JSON_DIAGNOSTIC < "$diagnostic_file" || true
    rm -f "$diagnostic_file"
    return "$rc"
}

opencode_settings_has_mcp() {
    local settings_src="$1"
    local output
    output=$(mktemp "${TMPDIR:-/tmp}/agentsync_opencode_inspect.XXXXXX") || return 2
    local rc=0
    _opencode_compose_json "$settings_src" "" "$output" "inspect-settings" || rc=$?
    rm -f "$output"
    return "$rc"
}

sync_opencode_config() {
    local settings_src="$1"
    local mcp_src="$2"
    local dest="$3"
    local dry_run="${4:-false}"
    local rendered
    rendered=$(mktemp "${TMPDIR:-/tmp}/agentsync_opencode.XXXXXX") || return 1

    local rc=0
    _opencode_compose_json "$settings_src" "$mcp_src" "$rendered" || rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$rendered"
        log_error "Cannot compose OpenCode config from $(display_path "$settings_src") and $(display_path "$mcp_src"): $OPENCODE_JSON_DIAGNOSTIC"
        return "$rc"
    fi
    if [[ "$dry_run" == "true" ]]; then
        rm -f "$rendered"
        log_step "Would compose OpenCode settings and MCP → $(display_path "$dest") (dry-run)"
        return 0
    fi

    ensure_dir "${dest%/*}"
    local destination_tmp
    destination_tmp=$(mktemp "${dest%/*}/.agentsync_opencode.XXXXXX") || {
        rm -f "$rendered"
        return 1
    }
    if ! cp "$rendered" "$destination_tmp"; then
        rm -f "$rendered" "$destination_tmp"
        return 1
    fi
    rm -f "$rendered"
    if ! mv "$destination_tmp" "$dest"; then
        rm -f "$destination_tmp"
        return 1
    fi
    declare -f manifest_record_write >/dev/null 2>&1 && manifest_record_write "$dest"
    log_step "$(display_path "$settings_src") + $(display_path "$mcp_src") → $(display_path "$dest")"
}
