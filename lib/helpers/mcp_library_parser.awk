# Strict, bounded JSON parser for the read-only MCP library schema v1.
# Invoked with LC_ALL=C so JSON strings are scanned byte-for-byte and escaped
# Unicode keys can be compared with literal UTF-8 keys without locale surprises.

function fail(message) {
    if (error == "") error = message
    return 0
}

function init_bytes(    i) {
    for (i = 0; i < 256; i++) byte_value[sprintf("%c", i)] = i
}

function byte_at(at) { return byte_value[substr(json, at, 1)] }
function hex_byte(value) { return sprintf("%02x", value) }
function hex_pair_value(pair) { return hex_value(pair) }

function utf8(codepoint,    output) {
    if (codepoint <= 127) return sprintf("%c", codepoint)
    if (codepoint <= 2047) return sprintf("%c%c", 192 + int(codepoint / 64), 128 + (codepoint % 64))
    if (codepoint <= 65535) return sprintf("%c%c%c", 224 + int(codepoint / 4096), 128 + (int(codepoint / 64) % 64), 128 + (codepoint % 64))
    return sprintf("%c%c%c%c", 240 + int(codepoint / 262144), 128 + (int(codepoint / 4096) % 64), 128 + (int(codepoint / 64) % 64), 128 + (codepoint % 64))
}

function bytes_hex(value,    i, output) {
    output = ""
    for (i = 1; i <= length(value); i++) output = output hex_byte(byte_value[substr(value, i, 1)])
    return output
}

function display_text(value,    i, byte, output) {
    output = ""
    for (i = 1; i <= length(value); i++) {
        byte = byte_value[substr(value, i, 1)]
        if (byte == 9) output = output "\\t"
        else if (byte == 10) output = output "\\n"
        else if (byte == 13) output = output "\\r"
        else if (byte < 32 || byte == 127) output = output sprintf("\\u%04x", byte)
        else if (byte == 194 && i < length(value) && byte_value[substr(value, i + 1, 1)] >= 128 && byte_value[substr(value, i + 1, 1)] <= 159) {
            i++
            output = output sprintf("\\u00%02x", byte_value[substr(value, i, 1)])
        }
        else output = output substr(value, i, 1)
    }
    return output
}

# JSON output for the selected connection. This preserves valid Unicode bytes
# while escaping JSON syntax and control bytes; it is never shell-quoted.
function json_text(value,    i, byte, output) {
    output = "\""
    for (i = 1; i <= length(value); i++) {
        byte = byte_value[substr(value, i, 1)]
        if (byte == 34) output = output "\\\""
        else if (byte == 92) output = output "\\\\"
        else if (byte == 8) output = output "\\b"
        else if (byte == 12) output = output "\\f"
        else if (byte == 10) output = output "\\n"
        else if (byte == 13) output = output "\\r"
        else if (byte == 9) output = output "\\t"
        else if (byte < 32 || byte == 127) output = output sprintf("\\u%04x", byte)
        else if (byte == 194 && i < length(value) && byte_value[substr(value, i + 1, 1)] >= 128 && byte_value[substr(value, i + 1, 1)] <= 159) {
            i++
            output = output sprintf("\\u00%02x", byte_value[substr(value, i, 1)])
        }
        else output = output substr(value, i, 1)
    }
    return output "\""
}

# String nodes retain a canonical byte sequence so escaped NUL never has to
# survive in an awk string before being serialized back to JSON or TOML.
function json_text_canonical(canonical,    i, byte, output) {
    output = "\""
    for (i = 1; i <= length(canonical); i += 2) {
        byte = hex_pair_value(substr(canonical, i, 2))
        if (byte == 34) output = output "\\\""
        else if (byte == 92) output = output "\\\\"
        else if (byte == 8) output = output "\\b"
        else if (byte == 12) output = output "\\f"
        else if (byte == 10) output = output "\\n"
        else if (byte == 13) output = output "\\r"
        else if (byte == 9) output = output "\\t"
        else if (byte < 32 || byte == 127) output = output sprintf("\\u%04x", byte)
        else if (byte == 194 && i < length(canonical) && hex_pair_value(substr(canonical, i + 2, 2)) >= 128 && hex_pair_value(substr(canonical, i + 2, 2)) <= 159) {
            i += 2
            output = output sprintf("\\u00%02x", hex_pair_value(substr(canonical, i, 2)))
        }
        else output = output sprintf("%c", byte)
    }
    return output "\""
}

function display_canonical(canonical,    i, byte, next_byte, output) {
    output = ""
    for (i = 1; i <= length(canonical); i += 2) {
        byte = hex_pair_value(substr(canonical, i, 2))
        next_byte = hex_pair_value(substr(canonical, i + 2, 2))
        if (byte == 9) output = output "\\t"
        else if (byte == 10) output = output "\\n"
        else if (byte == 13) output = output "\\r"
        else if (byte < 32 || byte == 127) output = output sprintf("\\u%04x", byte)
        else if (byte == 194 && next_byte >= 128 && next_byte <= 159) {
            i += 2
            output = output sprintf("\\u00%02x", next_byte)
        } else output = output sprintf("%c", byte)
    }
    return output
}

function has_control(value,    i, byte) {
    for (i = 1; i <= length(value); i++) {
        byte = byte_value[substr(value, i, 1)]
        if (byte < 32 || byte == 127) return 1
        if (byte == 194 && i < length(value) && byte_value[substr(value, i + 1, 1)] >= 128 && byte_value[substr(value, i + 1, 1)] <= 159) return 1
    }
    return 0
}

function hex_value(value,    i, digit, output) {
    output = 0
    for (i = 1; i <= length(value); i++) {
        digit = index("0123456789abcdef", tolower(substr(value, i, 1))) - 1
        output = output * 16 + digit
    }
    return output
}

function skip_space() {
    while (position <= length(json) && substr(json, position, 1) ~ /[ \t\r\n]/) position++
}

function append_codepoint(codepoint, raw_hex,    value) {
    if (codepoint >= 55296 && codepoint <= 57343) {
        return fail("unpaired Unicode surrogate escape")
    }
    if (codepoint == 0) {
        # A nonempty control sentinel keeps ASCII schema/ID checks fail-closed
        # even in awk implementations which cannot retain NUL in strings.
        # Identity, serialization and display must use canonical bytes instead.
        string_value = string_value sprintf("%c", 1)
        string_canonical = string_canonical "00"
        return 1
    }
    value = utf8(codepoint)
    string_value = string_value value
    string_canonical = string_canonical bytes_hex(value)
    return 1
}

function append_literal_utf8(    first, second, third, fourth, bytes) {
    first = byte_at(position)
    if (first < 128) {
        string_value = string_value substr(json, position, 1)
        string_canonical = string_canonical hex_byte(first)
        position++
        return 1
    }
    if (first >= 194 && first <= 223) {
        second = byte_at(position + 1)
        if (second < 128 || second > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 2)
        position += 2
    } else if (first == 224) {
        second = byte_at(position + 1); third = byte_at(position + 2)
        if (second < 160 || second > 191 || third < 128 || third > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 3)
        position += 3
    } else if (first >= 225 && first <= 236) {
        second = byte_at(position + 1); third = byte_at(position + 2)
        if (second < 128 || second > 191 || third < 128 || third > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 3)
        position += 3
    } else if (first == 237) {
        second = byte_at(position + 1); third = byte_at(position + 2)
        if (second < 128 || second > 159 || third < 128 || third > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 3)
        position += 3
    } else if (first >= 238 && first <= 239) {
        second = byte_at(position + 1); third = byte_at(position + 2)
        if (second < 128 || second > 191 || third < 128 || third > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 3)
        position += 3
    } else if (first == 240) {
        second = byte_at(position + 1); third = byte_at(position + 2); fourth = byte_at(position + 3)
        if (second < 144 || second > 191 || third < 128 || third > 191 || fourth < 128 || fourth > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 4)
        position += 4
    } else if (first >= 241 && first <= 243) {
        second = byte_at(position + 1); third = byte_at(position + 2); fourth = byte_at(position + 3)
        if (second < 128 || second > 191 || third < 128 || third > 191 || fourth < 128 || fourth > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 4)
        position += 4
    } else if (first == 244) {
        second = byte_at(position + 1); third = byte_at(position + 2); fourth = byte_at(position + 3)
        if (second < 128 || second > 143 || third < 128 || third > 191 || fourth < 128 || fourth > 191) return fail("invalid UTF-8 in JSON string")
        bytes = substr(json, position, 4)
        position += 4
    } else return fail("invalid UTF-8 in JSON string")
    string_value = string_value bytes
    string_canonical = string_canonical bytes_hex(bytes)
    return 1
}

function parse_string(    escape, hex, codepoint, low_hex, low) {
    if (substr(json, position, 1) != "\"") return fail("expected JSON string")
    position++
    string_value = ""
    string_canonical = ""
    while (position <= length(json)) {
        if (substr(json, position, 1) == "\"") {
            position++
            return 1
        }
        if (substr(json, position, 1) == "\\") {
            position++
            if (position > length(json)) return fail("unterminated JSON escape")
            escape = substr(json, position, 1)
            if (escape == "u") {
                hex = substr(json, position + 1, 4)
                if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return fail("invalid Unicode escape")
                codepoint = hex_value(hex)
                position += 5
                if (codepoint >= 55296 && codepoint <= 56319 && substr(json, position, 2) == "\\u") {
                    low_hex = substr(json, position + 2, 4)
                    if (low_hex ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
                        low = hex_value(low_hex)
                        if (low >= 56320 && low <= 57343) {
                            codepoint = 65536 + (codepoint - 55296) * 1024 + low - 56320
                            position += 6
                        }
                    }
                }
                if (!append_codepoint(codepoint, hex)) return 0
                continue
            }
            if (escape == "\"" || escape == "\\" || escape == "/") {
                string_value = string_value escape
                string_canonical = string_canonical hex_byte(byte_value[escape])
            } else if (escape == "b") {
                string_value = string_value sprintf("%c", 8); string_canonical = string_canonical "08"
            } else if (escape == "f") {
                string_value = string_value sprintf("%c", 12); string_canonical = string_canonical "0c"
            } else if (escape == "n") {
                string_value = string_value sprintf("%c", 10); string_canonical = string_canonical "0a"
            } else if (escape == "r") {
                string_value = string_value sprintf("%c", 13); string_canonical = string_canonical "0d"
            } else if (escape == "t") {
                string_value = string_value sprintf("%c", 9); string_canonical = string_canonical "09"
            } else return fail("invalid JSON escape")
            position++
            continue
        }
        if (byte_at(position) < 32) return fail("control character in JSON string")
        if (!append_literal_utf8()) return 0
    }
    return fail("unterminated JSON string")
}

function new_node(kind, raw,    node) {
    node = ++node_count
    node_kind[node] = kind
    node_raw[node] = raw
    return node
}

function parse_array(depth,    node, item, char) {
    node = new_node("array", "")
    position++
    skip_space()
    if (substr(json, position, 1) == "]") { position++; last_node = node; return 1 }
    while (position <= length(json)) {
        if (!parse_value(depth + 1)) return 0
        item = last_node
        array_count[node]++
        array_item[node SUBSEP array_count[node]] = item
        skip_space()
        char = substr(json, position, 1)
        if (char == "]") { position++; last_node = node; return 1 }
        if (char != ",") return fail("expected comma in JSON array")
        position++
        skip_space()
    }
    return fail("unterminated JSON array")
}

function parse_object(depth,    node, key, canonical, value, char) {
    node = new_node("object", "")
    position++
    skip_space()
    if (substr(json, position, 1) == "}") { position++; last_node = node; return 1 }
    while (position <= length(json)) {
        if (!parse_string()) return 0
        key = string_value
        canonical = string_canonical
        if ((node SUBSEP canonical) in object_seen) return fail("duplicate JSON key '" display_text(key) "'")
        object_seen[node SUBSEP canonical] = 1
        skip_space()
        if (substr(json, position, 1) != ":") return fail("expected colon after JSON object key")
        position++
        if (!parse_value(depth + 1)) return 0
        value = last_node
        object_count[node]++
        object_key[node SUBSEP object_count[node]] = key
        object_key_canonical[node SUBSEP object_count[node]] = canonical
        object_value[node SUBSEP object_count[node]] = value
        skip_space()
        char = substr(json, position, 1)
        if (char == "}") { position++; last_node = node; return 1 }
        if (char != ",") return fail("expected comma in JSON object")
        position++
        skip_space()
    }
    return fail("unterminated JSON object")
}

function parse_value(depth,    char, rest, raw, node) {
    if (depth > max_depth) return fail("JSON nesting exceeds depth limit " max_depth)
    skip_space()
    char = substr(json, position, 1)
    if (char == "\"") {
        if (!parse_string()) return 0
        node = new_node("string", string_value)
        node_canonical[node] = string_canonical
        last_node = node
        return 1
    }
    if (char == "{") return parse_object(depth)
    if (char == "[") return parse_array(depth)
    rest = substr(json, position)
    if (substr(rest, 1, 4) == "true" && substr(rest, 5, 1) !~ /[[:alnum:]_]/) { position += 4; last_node = new_node("boolean", "true"); return 1 }
    if (substr(rest, 1, 5) == "false" && substr(rest, 6, 1) !~ /[[:alnum:]_]/) { position += 5; last_node = new_node("boolean", "false"); return 1 }
    if (substr(rest, 1, 4) == "null" && substr(rest, 5, 1) !~ /[[:alnum:]_]/) { position += 4; last_node = new_node("null", "null"); return 1 }
    if (match(rest, /^-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][+-]?[0-9]+)?/)) {
        raw = substr(rest, 1, RLENGTH)
        position += RLENGTH
        last_node = new_node("number", raw)
        return 1
    }
    return fail("invalid JSON value")
}

function object_field_canonical(object, canonical,    i) {
    for (i = 1; i <= object_count[object]; i++) if (object_key_canonical[object SUBSEP i] == canonical) return object_value[object SUBSEP i]
    return 0
}

function object_field(object, wanted) { return object_field_canonical(object, bytes_hex(wanted)) }

function require_field(object, name, label,    value) {
    value = object_field(object, name)
    if (value == 0) fail(label " requires field '" name "'")
    return value
}

function allow_only(object, allowed, label,    i, key) {
    for (i = 1; i <= object_count[object]; i++) {
        key = object_key[object SUBSEP i]
        if (!(key in allowed)) return fail("unknown " label " field '" display_text(key) "'")
    }
    return 1
}

function require_kind(node, kind, label) {
    if (node_kind[node] != kind) return fail(label " must be " kind)
    return 1
}

function validate_string_array(node, label,    i, item) {
    if (!require_kind(node, "array", label)) return 0
    for (i = 1; i <= array_count[node]; i++) {
        item = array_item[node SUBSEP i]
        if (node_kind[item] != "string") return fail(label " must contain only strings")
    }
    return 1
}

function validate_provenance(node,    allowed, i, value) {
    if (!require_kind(node, "object", "provenance")) return 0
    allowed["homepage"] = allowed["repository"] = allowed["artifact"] = 1
    if (!allow_only(node, allowed, "provenance")) return 0
    for (i = 1; i <= object_count[node]; i++) {
        value = object_value[node SUBSEP i]
        if (node_kind[value] != "string" && node_kind[value] != "null") return fail("provenance values must be strings or null")
    }
    return 1
}

function validate_extensions(node,    i, key) {
    if (!require_kind(node, "object", "extensions")) return 0
    for (i = 1; i <= object_count[node]; i++) {
        key = object_key[node SUBSEP i]
        if (key !~ /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9.-]*$/) return fail("extension key must be namespaced: '" display_text(key) "'")
    }
    return 1
}

function validate_connection(node,    allowed, type, command, args, url) {
    if (!require_kind(node, "object", "connection")) return 0
    allowed["type"] = allowed["command"] = allowed["args"] = allowed["url"] = 1
    if (!allow_only(node, allowed, "connection")) return 0
    type = require_field(node, "type", "connection")
    if (error != "") return 0
    if (!require_kind(type, "string", "connection.type")) return 0
    if (node_raw[type] == "stdio") {
        command = require_field(node, "command", "stdio connection")
        args = require_field(node, "args", "stdio connection")
        if (error != "") return 0
        if (!require_kind(command, "string", "connection.command") || node_raw[command] == "") return fail("connection.command must be a non-empty string")
        if (!validate_string_array(args, "connection.args")) return 0
        if (object_field(node, "url") != 0) return fail("stdio connection must not define url")
    } else if (node_raw[type] == "http") {
        url = require_field(node, "url", "http connection")
        if (error != "") return 0
        if (!require_kind(url, "string", "connection.url") || node_raw[url] == "") return fail("connection.url must be a non-empty string")
        if (object_field(node, "command") != 0 || object_field(node, "args") != 0) return fail("http connection must not define command or args")
    } else return fail("connection.type must be 'stdio' or 'http'")
    return 1
}

function validate_variant_id(value) {
    return value ~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/ && length(value) <= 64
}

function validate_date(value,    year, month, day, max_day, leap) {
    if (value !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
    year = substr(value, 1, 4) + 0
    month = substr(value, 6, 2) + 0
    day = substr(value, 9, 2) + 0
    if (month < 1 || month > 12 || day < 1) return 0
    max_day = 31
    if (month == 4 || month == 6 || month == 9 || month == 11) max_day = 30
    if (month == 2) {
        leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))
        max_day = leap ? 29 : 28
    }
    return day <= max_day
}

function validate_alternatives(node,    i, entry, id, allowed, description, connection, requirements) {
    if (!require_kind(node, "object", "alternatives")) return 0
    for (i = 1; i <= object_count[node]; i++) {
        id = object_key[node SUBSEP i]
        if (id == "default" || id == "recommended" || !validate_variant_id(id)) return fail("alternative id must be a safe non-reserved variant id: '" display_text(id) "'")
        entry = object_value[node SUBSEP i]
        if (!require_kind(entry, "object", "alternative '" display_text(id) "'")) return 0
        allowed["description"] = allowed["connection"] = allowed["requirements"] = 1
        if (!allow_only(entry, allowed, "alternative '" display_text(id) "'")) return 0
        description = object_field(entry, "description")
        if (description != 0 && !require_kind(description, "string", "alternative.description")) return 0
        connection = require_field(entry, "connection", "alternative")
        requirements = require_field(entry, "requirements", "alternative")
        if (error != "") return 0
        if (!validate_connection(connection) || !validate_requirements(requirements)) return 0
        alternative_count++
        alternative_id[alternative_count] = id
        alternative_connection[alternative_count] = connection
    }
    return 1
}

function alternative_index(id,    i) {
    for (i = 1; i <= alternative_count; i++) if (alternative_id[i] == id) return i
    return 0
}

function validate_guidance(node,    allowed, recommended, authority, source, checked_at, reason) {
    if (!require_kind(node, "object", "guidance")) return 0
    allowed["recommended"] = allowed["authority"] = allowed["source"] = allowed["checked_at"] = allowed["reason"] = 1
    if (!allow_only(node, allowed, "guidance")) return 0
    recommended = require_field(node, "recommended", "guidance")
    authority = require_field(node, "authority", "guidance")
    source = require_field(node, "source", "guidance")
    checked_at = require_field(node, "checked_at", "guidance")
    reason = require_field(node, "reason", "guidance")
    if (error != "") return 0
    if (!require_kind(recommended, "string", "guidance.recommended") || !validate_variant_id(node_raw[recommended])) return fail("guidance.recommended must be 'default' or a safe variant id")
    if (!require_kind(authority, "string", "guidance.authority") || (node_raw[authority] != "vendor" && node_raw[authority] != "maintainer")) return fail("guidance.authority must be 'vendor' or 'maintainer'")
    if (!require_kind(source, "string", "guidance.source") || node_raw[source] !~ /^https:\/\/[A-Za-z0-9]/ || has_control(node_raw[source]) || node_raw[source] ~ /[[:space:]]/) return fail("guidance.source must be an https URL without control characters")
    if (!require_kind(checked_at, "string", "guidance.checked_at") || !validate_date(node_raw[checked_at])) return fail("guidance.checked_at must be a valid YYYY-MM-DD date")
    if (!require_kind(reason, "string", "guidance.reason") || node_raw[reason] == "") return fail("guidance.reason must be a non-empty string")
    if (node_raw[recommended] != "default" && alternative_index(node_raw[recommended]) == 0) return fail("guidance.recommended names an unavailable alternative")
    guidance_present = 1
    guidance_recommended = node_raw[recommended]
    guidance_authority = node_raw[authority]
    return 1
}

function validate_requirements(node,    allowed, binaries, inputs) {
    if (!require_kind(node, "object", "requirements")) return 0
    allowed["binaries"] = allowed["inputs"] = 1
    if (!allow_only(node, allowed, "requirements")) return 0
    binaries = require_field(node, "binaries", "requirements")
    inputs = require_field(node, "inputs", "requirements")
    if (error != "") return 0
    if (!validate_string_array(binaries, "requirements.binaries")) return 0
    if (!validate_string_array(inputs, "requirements.inputs")) return 0
    if (array_count[inputs] != 0) return fail("requirements.inputs is unsupported in MCP library schema; use an empty array")
    return 1
}

function validate_manifest(root,    allowed, schema, version, id, title, description, provenance, connection, requirements, extensions, alternatives, guidance) {
    if (node_kind[root] != "object") return fail("manifest root must be an object")
    schema = require_field(root, "schema_version", "manifest")
    id = require_field(root, "id", "manifest")
    title = require_field(root, "title", "manifest")
    connection = require_field(root, "connection", "manifest")
    requirements = require_field(root, "requirements", "manifest")
    if (error != "") return 0
    if (node_kind[schema] != "number" || (node_raw[schema] != "1" && node_raw[schema] != "2")) return fail("unsupported schema_version '" node_raw[schema] "'")
    version = node_raw[schema]
    allowed["schema_version"] = allowed["id"] = allowed["title"] = allowed["description"] = allowed["provenance"] = allowed["connection"] = allowed["requirements"] = allowed["extensions"] = 1
    if (version == "2") allowed["alternatives"] = allowed["guidance"] = 1
    if (!allow_only(root, allowed, "top-level")) return 0
    if (!require_kind(id, "string", "id") || node_raw[id] !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/ || length(node_raw[id]) > 64) return fail("id must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")
    if (!require_kind(title, "string", "title") || node_raw[title] == "") return fail("title must be a non-empty string")
    description = object_field(root, "description")
    if (description != 0 && !require_kind(description, "string", "description")) return 0
    provenance = object_field(root, "provenance")
    if (provenance != 0 && !validate_provenance(provenance)) return 0
    if (!validate_connection(connection) || !validate_requirements(requirements)) return 0
    extensions = object_field(root, "extensions")
    if (extensions != 0 && !validate_extensions(extensions)) return 0
    if (version == "2") {
        alternatives = object_field(root, "alternatives")
        if (alternatives != 0 && !validate_alternatives(alternatives)) return 0
        guidance = object_field(root, "guidance")
        if (guidance != 0 && !validate_guidance(guidance)) return 0
    }
    if (expected_id != "" && node_raw[id] != expected_id) return fail("manifest id '" node_raw[id] "' does not match requested id '" expected_id "'")
    manifest_connection = connection
    manifest_id = node_raw[id]
    manifest_title = node_raw[title]
    manifest_title_canonical = node_canonical[title]
    return 1
}

function serialize_string_array(node,    i, item, output) {
    output = "["
    for (i = 1; i <= array_count[node]; i++) {
        item = array_item[node SUBSEP i]
        if (i > 1) output = output ","
        output = output json_text_canonical(node_canonical[item])
    }
    return output "]"
}

function serialize_connection(node,    type, command, args, url) {
    type = object_field(node, "type")
    if (node_raw[type] == "stdio") {
        command = object_field(node, "command")
        args = object_field(node, "args")
        return "{\"command\":" json_text_canonical(node_canonical[command]) ",\"args\":" serialize_string_array(args) "}"
    }
    url = object_field(node, "url")
    return "{\"type\":\"http\",\"url\":" json_text_canonical(node_canonical[url]) "}"
}

function validate_codex_source_connection(node,    allowed, type, command, args, url) {
    if (!require_kind(node, "object", "Codex MCP server")) return 0
    allowed["type"] = allowed["command"] = allowed["args"] = allowed["url"] = 1
    if (!allow_only(node, allowed, "Codex MCP server")) return 0
    type = object_field(node, "type")
    command = object_field(node, "command")
    args = object_field(node, "args")
    url = object_field(node, "url")
    if (type == 0) {
        if (command == 0 || args == 0) return fail("stdio Codex MCP server requires command and args")
        if (!require_kind(command, "string", "Codex MCP command") || node_raw[command] == "") return fail("Codex MCP command must be a non-empty string")
        if (!validate_string_array(args, "Codex MCP args")) return 0
        if (url != 0) return fail("stdio Codex MCP server must not define url")
    } else {
        if (!require_kind(type, "string", "Codex MCP type") || node_raw[type] != "http") return fail("Codex MCP type must be 'http'")
        if (url == 0) return fail("http Codex MCP server requires url")
        if (!require_kind(url, "string", "Codex MCP url") || node_raw[url] == "") return fail("Codex MCP url must be a non-empty string")
        if (command != 0 || args != 0) return fail("http Codex MCP server must not define command or args")
    }
    return 1
}

function validate_codex_source(root,    allowed, servers, i, id, server) {
    if (!require_kind(root, "object", "Codex MCP source root")) return 0
    allowed["mcpServers"] = 1
    if (!allow_only(root, allowed, "Codex MCP source root")) return 0
    servers = require_field(root, "mcpServers", "Codex MCP source root")
    if (error != "") return 0
    if (!require_kind(servers, "object", "mcpServers")) return 0
    if (object_count[servers] > 256) return fail("mcpServers exceeds entry limit 256")
    for (i = 1; i <= object_count[servers]; i++) {
        id = object_key[servers SUBSEP i]
        if (!validate_variant_id(id)) return fail("Codex MCP server id must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")
        server = object_value[servers SUBSEP i]
        if (!validate_codex_source_connection(server)) return 0
    }
    codex_source_servers = servers
    return 1
}

function serialize_toml_string_array(node,    i, item, output) {
    output = "["
    for (i = 1; i <= array_count[node]; i++) {
        item = array_item[node SUBSEP i]
        if (i > 1) output = output ", "
        output = output json_text_canonical(node_canonical[item])
    }
    return output "]"
}

function serialize_codex_source_server(node,    type, command, args, url) {
    type = object_field(node, "type")
    if (type == 0) {
        command = object_field(node, "command")
        args = object_field(node, "args")
        return "{ command = " json_text_canonical(node_canonical[command]) ", args = " serialize_toml_string_array(args) " }"
    }
    url = object_field(node, "url")
    return "{ url = " json_text_canonical(node_canonical[url]) " }"
}

function serialize_codex_source(    i, id, server, output) {
    output = "mcp_servers = {"
    for (i = 1; i <= object_count[codex_source_servers]; i++) {
        id = object_key[codex_source_servers SUBSEP i]
        server = object_value[codex_source_servers SUBSEP i]
        if (i > 1) output = output ", "
        else output = output " "
        output = output json_text_canonical(object_key_canonical[codex_source_servers SUBSEP i]) " = " serialize_codex_source_server(server)
    }
    return output " }"
}

function parse_json_path(path, label,    read_status, read_bytes, have_line, line) {
    if (path == "") return fail("missing " label)
    json = ""
    read_status = 0
    read_bytes = 0
    have_line = 0
    while ((read_status = getline line < path) > 0) {
        if (have_line) read_bytes++
        read_bytes += length(line)
        if (read_bytes > max_bytes) return fail(label " exceeds byte limit " max_bytes)
        if (have_line) json = json "\n"
        json = json line
        have_line = 1
    }
    close(path)
    if (read_status < 0) return fail("cannot read " label)
    position = 1
    skip_space()
    if (!parse_value(1)) return 0
    parsed_root = last_node
    skip_space()
    if (position <= length(json)) return fail("trailing content after JSON value")
    return 1
}

function json_node_equal(left, right,    i, key, left_value, right_value) {
    if (node_kind[left] != node_kind[right]) return 0
    if (node_kind[left] == "string") return node_canonical[left] == node_canonical[right]
    if (node_kind[left] == "number" || node_kind[left] == "boolean" || node_kind[left] == "null") return node_raw[left] == node_raw[right]
    if (node_kind[left] == "array") {
        if (array_count[left] != array_count[right]) return 0
        for (i = 1; i <= array_count[left]; i++) if (!json_node_equal(array_item[left SUBSEP i], array_item[right SUBSEP i])) return 0
        return 1
    }
    if (object_count[left] != object_count[right]) return 0
    for (i = 1; i <= object_count[left]; i++) {
        key = object_key[left SUBSEP i]
        left_value = object_value[left SUBSEP i]
        right_value = object_field_canonical(right, object_key_canonical[left SUBSEP i])
        if (right_value == 0 || !json_node_equal(left_value, right_value)) return 0
    }
    return 1
}

function validate_merge_replacements(value,    parts, count, i, id) {
    if (value == "") return 1
    count = split(value, parts, ",")
    for (i = 1; i <= count; i++) {
        id = parts[i]
        if (!validate_variant_id(id)) return fail("replacement id must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")
        if (id in merge_replace) return fail("duplicate replacement id '" display_text(id) "'")
        merge_replace[id] = 1
    }
    return 1
}

function validate_merge_source(source_root, overlay_root,    source_servers, overlay_servers, i, id, source_server, overlay_server, merged_count) {
    if (!require_kind(source_root, "object", "existing MCP source root")) return 0
    source_servers = require_field(source_root, "mcpServers", "existing MCP source root")
    if (error != "") return 0
    if (!require_kind(source_servers, "object", "existing mcpServers")) return 0
    if (object_count[source_servers] > 256) return fail("existing mcpServers exceeds entry limit 256")
    for (i = 1; i <= object_count[source_servers]; i++) {
        id = object_key[source_servers SUBSEP i]
        if (!validate_variant_id(id)) return fail("existing MCP server id must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}")
        source_server = object_value[source_servers SUBSEP i]
        if (!require_kind(source_server, "object", "existing MCP server")) return 0
    }
    if (!validate_codex_source(overlay_root)) return 0
    overlay_servers = codex_source_servers
    if (!validate_merge_replacements(replace_ids)) return 0
    for (i = 1; i <= object_count[overlay_servers]; i++) {
        id = object_key[overlay_servers SUBSEP i]
        merge_selected[id] = 1
    }
    for (id in merge_replace) if (!(id in merge_selected)) return fail("replacement id is not selected: '" display_text(id) "'")
    for (i = 1; i <= object_count[overlay_servers]; i++) {
        id = object_key[overlay_servers SUBSEP i]
        overlay_server = object_value[overlay_servers SUBSEP i]
        source_server = object_field(source_servers, id)
        if (source_server == 0) {
            merge_action[id] = "add"
            merged_count++
        }
        else if (json_node_equal(source_server, overlay_server)) merge_action[id] = "identical"
        else if (id in merge_replace) merge_action[id] = "replace"
        else return fail("existing MCP server differs; re-run with --replace " id)
    }
    if (object_count[source_servers] + merged_count > 256) return fail("merged mcpServers exceeds entry limit 256")
    merge_source_root = source_root
    merge_source_servers = source_servers
    merge_overlay_servers = overlay_servers
    return 1
}

function serialize_json_node(node,    i, output) {
    if (node_kind[node] == "string") return json_text_canonical(node_canonical[node])
    if (node_kind[node] == "number" || node_kind[node] == "boolean" || node_kind[node] == "null") return node_raw[node]
    if (node_kind[node] == "array") {
        output = "["
        for (i = 1; i <= array_count[node]; i++) {
            if (i > 1) output = output ","
            output = output serialize_json_node(array_item[node SUBSEP i])
        }
        return output "]"
    }
    output = "{"
    for (i = 1; i <= object_count[node]; i++) {
        if (i > 1) output = output ","
        output = output json_text_canonical(object_key_canonical[node SUBSEP i]) ":" serialize_json_node(object_value[node SUBSEP i])
    }
    return output "}"
}

function serialize_merged_servers(    i, id, source_server, overlay_server, output, count) {
    output = "{"
    count = 0
    for (i = 1; i <= object_count[merge_source_servers]; i++) {
        id = object_key[merge_source_servers SUBSEP i]
        source_server = object_value[merge_source_servers SUBSEP i]
        if (count++ > 0) output = output ","
        output = output json_text_canonical(object_key_canonical[merge_source_servers SUBSEP i]) ":"
        if (merge_action[id] == "replace") {
            overlay_server = object_field(merge_overlay_servers, id)
            output = output serialize_json_node(overlay_server)
        } else output = output serialize_json_node(source_server)
    }
    for (i = 1; i <= object_count[merge_overlay_servers]; i++) {
        id = object_key[merge_overlay_servers SUBSEP i]
        if (object_field(merge_source_servers, id) != 0) continue
        if (count++ > 0) output = output ","
        overlay_server = object_value[merge_overlay_servers SUBSEP i]
        output = output json_text_canonical(object_key_canonical[merge_overlay_servers SUBSEP i]) ":" serialize_json_node(overlay_server)
    }
    return output "}"
}

function serialize_merged_source(    i, key, value, output) {
    output = "{"
    for (i = 1; i <= object_count[merge_source_root]; i++) {
        if (i > 1) output = output ","
        key = object_key[merge_source_root SUBSEP i]
        value = object_value[merge_source_root SUBSEP i]
        output = output json_text_canonical(object_key_canonical[merge_source_root SUBSEP i]) ":"
        if (key == "mcpServers") output = output serialize_merged_servers()
        else output = output serialize_json_node(value)
    }
    return output "}"
}

function print_merge_plan(    i, id) {
    for (i = 1; i <= object_count[merge_overlay_servers]; i++) {
        id = object_key[merge_overlay_servers SUBSEP i]
        printf "%s\t%s\n", id, merge_action[id]
    }
}

function resolve_selected_variant(    requested, alternative_pos) {
    requested = selected_variant
    if (requested == "") requested = "default"
    if (requested != "default" && requested != "recommended" && !validate_variant_id(requested)) return fail("requested variant must be 'default', 'recommended', or a safe variant id")
    if (requested == "recommended") {
        if (!guidance_present) return fail("requested variant 'recommended' requires guidance")
        requested = guidance_recommended
    }
    if (requested == "default") {
        resolved_variant = "default"
        resolved_connection = manifest_connection
    } else {
        alternative_pos = alternative_index(requested)
        if (alternative_pos == 0) return fail("requested variant '" display_text(requested) "' is unavailable")
        resolved_variant = requested
        resolved_connection = alternative_connection[alternative_pos]
    }
    resolved_authority = (guidance_present && resolved_variant == guidance_recommended) ? guidance_authority : "unknown"
    return 1
}

BEGIN {
    init_bytes()
    if (!parse_json_path(ARGV[1], "manifest")) {
        print error > "/dev/stderr"
        exit 1
    }
    root = parsed_root
    if (output_mode == "merge-plan" || output_mode == "merge-json") {
        source_root = root
        if (error == "" && !parse_json_path(overlay_path, "MCP source overlay")) { }
        overlay_root = parsed_root
        if (error == "" && !validate_merge_source(source_root, overlay_root)) { }
    } else if (output_mode == "codex-source") {
        if (error == "" && !validate_codex_source(root)) { }
    } else if (error == "" && !validate_manifest(root)) { }
    if (error != "") {
        print error > "/dev/stderr"
        exit 1
    }
    if (output_mode == "merge-plan") print_merge_plan()
    else if (output_mode == "merge-json") print serialize_merged_source()
    else if (output_mode == "codex-source") print serialize_codex_source()
    else if (output_mode == "metadata") printf "%s\t%s\n", manifest_id, display_canonical(manifest_title_canonical)
    else if (output_mode == "server" || output_mode == "selection") {
        if (!resolve_selected_variant()) {
            print error > "/dev/stderr"
            exit 1
        }
        if (output_mode == "server") print serialize_connection(resolved_connection)
        else printf "%s\t%s\t%s\n", resolved_variant, node_raw[object_field(resolved_connection, "type")], resolved_authority
    }
}
