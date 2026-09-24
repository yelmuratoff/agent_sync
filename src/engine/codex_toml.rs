use serde_json::{Map, Value};

use crate::config::mcp_catalog;
use crate::engine::toml_keys::Declared;

pub fn settings_claim_mcp(settings: &str) -> bool {
    settings.lines().any(|line| {
        let line = line.trim_start();
        !line.starts_with('#')
            && (line.contains("mcp_servers") || line.contains("\\u") || line.contains("\\U"))
    })
}

const STDIO_STRINGS: &[&str] = &["cwd"];
const STDIO_LISTS: &[&str] = &["env_vars"];
const STDIO_MAPS: &[&str] = &["env"];
const HTTP_STRINGS: &[&str] = &["bearer_token_env_var"];
const HTTP_LISTS: &[&str] = &[];
const HTTP_MAPS: &[&str] = &["http_headers", "env_http_headers"];
const SHARED_BOOLS: &[&str] = &["enabled", "required"];
const SHARED_NUMBERS: &[&str] = &["startup_timeout_sec", "tool_timeout_sec"];
const SHARED_LISTS: &[&str] = &["enabled_tools", "disabled_tools"];

const OWNERSHIP_CONFLICT: &str =
    "settings already contain or may encode mcp_servers; keep MCP ownership in one source";

/// The keys a key-owned `config.toml` takes from the settings source, plus one
/// `mcp_servers.<id>` subtree per server in the MCP source.
pub fn declared(settings: &str, canonical: Option<&[u8]>) -> Result<Declared, String> {
    let mut declared =
        Declared::from_toml(settings).map_err(|e| format!("settings are not valid TOML: {e}"))?;
    if let Some(canonical) = canonical {
        if declared.contains_top_level("mcp_servers") {
            return Err(OWNERSHIP_CONFLICT.into());
        }
        declared.add_subtrees(&compose("", canonical)?, "mcp_servers")?;
    }
    Ok(declared)
}

pub fn compose(settings: &str, canonical: &[u8]) -> Result<String, String> {
    if settings_claim_mcp(settings) {
        return Err(OWNERSHIP_CONFLICT.into());
    }
    if canonical.len() as u64 > mcp_catalog::MAX_MANIFEST_BYTES {
        return Err("MCP source exceeds the byte limit for Codex composition".into());
    }
    let value =
        mcp_catalog::parse_strict(canonical).map_err(|_| "MCP source is not supported JSON")?;
    let root = value.as_object().ok_or("MCP source must be an object")?;
    if root.len() != 1 {
        return Err("MCP source must contain only mcpServers".into());
    }
    let servers = root
        .get("mcpServers")
        .and_then(Value::as_object)
        .ok_or("mcpServers must be an object")?;
    let mut out = settings.to_string();
    for (name, value) in servers {
        if !mcp_catalog::valid_id(name) {
            return Err("MCP server name cannot be represented in Codex config".into());
        }
        let fields = value.as_object().ok_or("MCP server must be an object")?;
        let has_command = fields.contains_key("command");
        let has_url = fields.contains_key("url");
        if has_command == has_url {
            return Err("MCP server must have exactly one command or url".into());
        }
        let (kind, strings, lists, maps) = if has_command {
            ("stdio", STDIO_STRINGS, STDIO_LISTS, STDIO_MAPS)
        } else {
            ("http", HTTP_STRINGS, HTTP_LISTS, HTTP_MAPS)
        };
        check_fields(name, kind, fields, &[strings, lists, maps])?;
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        out.push_str(&format!("\n[mcp_servers.{name}]\n"));
        if has_command {
            let command = fields["command"]
                .as_str()
                .ok_or("MCP command must be a string")?;
            if command.is_empty() {
                return Err("MCP command must not be empty".into());
            }
            out.push_str(&format!("command = {}\n", toml_string(command)?));
            if let Some(args) = fields.get("args") {
                out.push_str(&format!("args = {}\n", string_list(name, "args", args)?));
            }
        } else {
            let url = fields["url"].as_str().ok_or("MCP URL must be a string")?;
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                return Err("MCP URL must use HTTP or HTTPS".into());
            }
            out.push_str(&format!("url = {}\n", toml_string(url)?));
        }
        write_scalars(&mut out, name, fields, strings, lists)?;
        for field in maps {
            if let Some(map) = fields.get(*field) {
                write_map(&mut out, name, field, map)?;
            }
        }
    }
    Ok(out)
}

fn check_fields(
    name: &str,
    kind: &str,
    fields: &Map<String, Value>,
    own: &[&[&str]],
) -> Result<(), String> {
    let primary = if kind == "stdio" {
        &["command", "args"][..]
    } else {
        &["url"][..]
    };
    let known = |key: &str| {
        key == "type"
            || primary.contains(&key)
            || own.iter().any(|group| group.contains(&key))
            || [SHARED_BOOLS, SHARED_NUMBERS, SHARED_LISTS]
                .iter()
                .any(|group| group.contains(&key))
    };
    if let Some(key) = fields.keys().find(|key| !known(key)) {
        return Err(format!(
            "MCP server {name}: field `{key}` is not supported for a Codex {kind} server"
        ));
    }
    if fields
        .get("type")
        .is_some_and(|value| value.as_str() != Some(kind))
    {
        return Err(format!(
            "MCP server {name}: `type` must be \"{kind}\" for this server"
        ));
    }
    Ok(())
}

fn write_scalars(
    out: &mut String,
    name: &str,
    fields: &Map<String, Value>,
    strings: &[&str],
    lists: &[&str],
) -> Result<(), String> {
    for field in strings {
        if let Some(value) = fields.get(*field) {
            let text = value
                .as_str()
                .ok_or_else(|| format!("MCP server {name}: `{field}` must be a string"))?;
            out.push_str(&format!("{field} = {}\n", toml_string(text)?));
        }
    }
    for field in lists.iter().chain(SHARED_LISTS) {
        if let Some(value) = fields.get(*field) {
            out.push_str(&format!("{field} = {}\n", string_list(name, field, value)?));
        }
    }
    for field in SHARED_BOOLS {
        if let Some(value) = fields.get(*field) {
            let flag = value
                .as_bool()
                .ok_or_else(|| format!("MCP server {name}: `{field}` must be true or false"))?;
            out.push_str(&format!("{field} = {flag}\n"));
        }
    }
    for field in SHARED_NUMBERS {
        if let Some(value) = fields.get(*field) {
            let number = value
                .as_number()
                .filter(|n| n.as_f64().is_some_and(|f| f >= 0.0))
                .ok_or_else(|| {
                    format!("MCP server {name}: `{field}` must be a non-negative number")
                })?;
            out.push_str(&format!("{field} = {number}\n"));
        }
    }
    Ok(())
}

fn string_list(name: &str, field: &str, value: &Value) -> Result<String, String> {
    let refuse = || format!("MCP server {name}: `{field}` must be an array of strings");
    let items = value.as_array().ok_or_else(refuse)?;
    let items = items
        .iter()
        .map(|item| {
            item.as_str()
                .ok_or_else(refuse)
                .and_then(|text| toml_string(text).map_err(String::from))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(format!("[{}]", items.join(", ")))
}

fn write_map(out: &mut String, name: &str, field: &str, value: &Value) -> Result<(), String> {
    let refuse = || format!("MCP server {name}: `{field}` must map names to strings");
    let entries = value.as_object().ok_or_else(refuse)?;
    out.push_str(&format!("\n[mcp_servers.{name}.{field}]\n"));
    for (key, value) in entries {
        out.push_str(&format!(
            "{} = {}\n",
            toml_string(key)?,
            toml_string(value.as_str().ok_or_else(refuse)?)?
        ));
    }
    Ok(())
}

fn toml_string(value: &str) -> Result<String, &'static str> {
    if value
        .chars()
        .any(|ch| matches!(ch, '\0' | '\u{7f}' | '\u{8}' | '\u{c}'))
    {
        return Err("MCP string contains an unsupported control character");
    }
    serde_json::to_string(value).map_err(|_| "Cannot encode MCP string")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composes_http_and_stdio_without_rewriting_settings() {
        let settings = "model = \"gpt\"\n";
        let source = br#"{"mcpServers":{"docs":{"type":"http","url":"https://example.test/mcp"},"local":{"command":"tool","args":["a"],"env":{"TOKEN":"${TOKEN}"}}}}"#;
        let out = compose(settings, source).unwrap();
        assert!(out.starts_with(settings));
        assert!(out.contains("[mcp_servers.docs]\nurl = \"https://example.test/mcp\"\n"));
        assert!(out.contains("[mcp_servers.local]\ncommand = \"tool\"\nargs = [\"a\"]\n"));
        assert!(out.contains("[mcp_servers.local.env]\n\"TOKEN\" = \"${TOKEN}\"\n"));
    }

    #[test]
    fn composes_codex_native_fields_before_the_server_subtables() {
        let source = br#"{"mcpServers":{
            "repl":{"command":"node_repl","args":[],"cwd":".","env_vars":["HOME"],"enabled":false,"required":true,"startup_timeout_sec":120,"tool_timeout_sec":1.5,"enabled_tools":["run"],"disabled_tools":["kill"],"env":{"A":"1"}},
            "docs":{"url":"https://example.test/mcp","bearer_token_env_var":"DOCS_TOKEN","http_headers":{"X-Team":"core"},"env_http_headers":{"X-Key":"DOCS_KEY"}}}}"#;
        let out = compose("", source).unwrap();
        assert_eq!(
            out,
            "\n[mcp_servers.docs]\nurl = \"https://example.test/mcp\"\nbearer_token_env_var = \"DOCS_TOKEN\"\n\
             \n[mcp_servers.docs.http_headers]\n\"X-Team\" = \"core\"\n\
             \n[mcp_servers.docs.env_http_headers]\n\"X-Key\" = \"DOCS_KEY\"\n\
             \n[mcp_servers.repl]\ncommand = \"node_repl\"\nargs = []\ncwd = \".\"\nenv_vars = [\"HOME\"]\n\
             enabled_tools = [\"run\"]\ndisabled_tools = [\"kill\"]\nenabled = false\nrequired = true\n\
             startup_timeout_sec = 120\ntool_timeout_sec = 1.5\n\n[mcp_servers.repl.env]\n\"A\" = \"1\"\n"
        );
    }

    #[test]
    fn declares_settings_leaves_and_one_subtree_per_server() {
        let source = br#"{"mcpServers":{"dart":{"command":"dart","args":["mcp-server"]}}}"#;
        let declared =
            declared("model = \"gpt\"\n[tui]\ntheme = \"dark\"\n", Some(source)).unwrap();
        let merged = crate::engine::toml_keys::merge("", &declared, None).unwrap();
        assert_eq!(
            merged.text,
            "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n\n[mcp_servers.dart]\ncommand = \"dart\"\nargs = [\"mcp-server\"]\n"
        );
    }

    #[test]
    fn declared_refuses_servers_in_settings_beside_an_mcp_source() {
        let source = br#"{"mcpServers":{}}"#;
        assert_eq!(
            declared("[mcp_servers.x]\ncommand = \"x\"\n", Some(source)).unwrap_err(),
            OWNERSHIP_CONFLICT
        );
        assert!(declared("[mcp_servers.x]\ncommand = \"x\"\n", None).is_ok());
    }

    #[test]
    fn names_the_field_it_refuses() {
        let refused = |source: &str| compose("", source.as_bytes()).unwrap_err();
        assert_eq!(
            refused(r#"{"mcpServers":{"docs":{"url":"https://x.test","headers":{}}}}"#),
            "MCP server docs: field `headers` is not supported for a Codex http server"
        );
        assert_eq!(
            refused(r#"{"mcpServers":{"repl":{"command":"x","bearer_token_env_var":"T"}}}"#),
            "MCP server repl: field `bearer_token_env_var` is not supported for a Codex stdio server"
        );
        assert_eq!(
            refused(r#"{"mcpServers":{"repl":{"command":"x","enabled":"no"}}}"#),
            "MCP server repl: `enabled` must be true or false"
        );
        assert_eq!(
            refused(r#"{"mcpServers":{"repl":{"command":"x","startup_timeout_sec":-1}}}"#),
            "MCP server repl: `startup_timeout_sec` must be a non-negative number"
        );
        assert_eq!(
            refused(r#"{"mcpServers":{"repl":{"command":"x","cwd":1}}}"#),
            "MCP server repl: `cwd` must be a string"
        );
        assert_eq!(
            refused(r#"{"mcpServers":{"repl":{"command":"x","type":"http"}}}"#),
            "MCP server repl: `type` must be \"stdio\" for this server"
        );
    }

    #[test]
    fn refuses_existing_ownership_and_unsupported_sources() {
        let source = br#"{"mcpServers":{"docs":{"url":"https://example.test"}}}"#;
        assert!(compose("[mcp_servers.docs]\n", source).is_err());
        assert!(compose("[\"mcp\\u005fservers.docs\"]\n", source).is_err());
        assert!(compose("", br#"{"mcpServers":{"docs":{"url":"a","url":"b"}}}"#).is_err());
        assert!(compose("", br#"{"mcpServers":{"docs":{"url":"a","headers":{}}}}"#).is_err());
        assert!(compose("", br#"{"mcpServers":{"docs":{"url":"file:///tmp/x"}}}"#).is_err());
    }

    #[test]
    fn refuses_control_characters_with_non_toml_json_escapes() {
        for character in ['\u{8}', '\u{c}'] {
            let source = format!(
                "{{\"mcpServers\":{{\"local\":{{\"command\":\"tool\",\"args\":[{}]}}}}}}",
                serde_json::to_string(&character.to_string()).unwrap()
            );
            assert!(compose("", source.as_bytes()).is_err());
        }
    }
}
