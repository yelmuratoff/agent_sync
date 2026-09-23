use serde_json::{Map, Value};

use crate::config::mcp_catalog;

pub fn settings_claim_mcp(settings: &str) -> bool {
    settings.lines().any(|line| {
        let line = line.trim_start();
        !line.starts_with('#')
            && (line.contains("mcp_servers") || line.contains("\\u") || line.contains("\\U"))
    })
}

pub fn compose(settings: &str, canonical: &[u8]) -> Result<String, &'static str> {
    if settings_claim_mcp(settings) {
        return Err(
            "settings already contain or may encode mcp_servers; keep MCP ownership in one source",
        );
    }
    if canonical.len() as u64 > mcp_catalog::MAX_MANIFEST_BYTES {
        return Err("MCP source exceeds the byte limit for Codex composition");
    }
    let value =
        mcp_catalog::parse_strict(canonical).map_err(|_| "MCP source is not supported JSON")?;
    let root = value.as_object().ok_or("MCP source must be an object")?;
    if root.len() != 1 {
        return Err("MCP source must contain only mcpServers");
    }
    let servers = root
        .get("mcpServers")
        .and_then(Value::as_object)
        .ok_or("mcpServers must be an object")?;
    let mut out = settings.to_string();
    for (name, value) in servers {
        if !mcp_catalog::valid_id(name) {
            return Err("MCP server name cannot be represented in Codex config");
        }
        let fields = value.as_object().ok_or("MCP server must be an object")?;
        let has_command = fields.contains_key("command");
        let has_url = fields.contains_key("url");
        if has_command == has_url {
            return Err("MCP server must have exactly one command or url");
        }
        if has_command {
            stdio_fields(fields)?;
        } else {
            http_fields(fields)?;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        out.push_str(&format!("\n[mcp_servers.{name}]\n"));
        if has_command {
            let command = fields["command"]
                .as_str()
                .ok_or("MCP command must be a string")?;
            if command.is_empty() {
                return Err("MCP command must not be empty");
            }
            out.push_str(&format!("command = {}\n", toml_string(command)?));
            if let Some(args) = fields.get("args") {
                let args = args.as_array().ok_or("MCP args must be an array")?;
                let args = args
                    .iter()
                    .map(|arg| {
                        arg.as_str()
                            .ok_or("MCP args must be strings")
                            .and_then(toml_string)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                out.push_str(&format!("args = [{}]\n", args.join(", ")));
            }
            if let Some(env) = fields.get("env") {
                write_map(&mut out, name, "env", env)?;
            }
        } else {
            let url = fields["url"].as_str().ok_or("MCP URL must be a string")?;
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                return Err("MCP URL must use HTTP or HTTPS");
            }
            out.push_str(&format!("url = {}\n", toml_string(url)?));
        }
    }
    Ok(out)
}

fn stdio_fields(fields: &Map<String, Value>) -> Result<(), &'static str> {
    if fields
        .keys()
        .any(|key| !matches!(key.as_str(), "command" | "args" | "env" | "type"))
        || fields
            .get("type")
            .is_some_and(|value| value.as_str() != Some("stdio"))
    {
        return Err("unsupported Codex stdio MCP field");
    }
    Ok(())
}

fn http_fields(fields: &Map<String, Value>) -> Result<(), &'static str> {
    if fields
        .keys()
        .any(|key| !matches!(key.as_str(), "url" | "type"))
        || fields
            .get("type")
            .is_some_and(|value| value.as_str() != Some("http"))
    {
        return Err("unsupported Codex HTTP MCP field");
    }
    Ok(())
}

fn write_map(out: &mut String, name: &str, field: &str, value: &Value) -> Result<(), &'static str> {
    let entries = value.as_object().ok_or("MCP env must be an object")?;
    out.push_str(&format!("\n[mcp_servers.{name}.{field}]\n"));
    for (key, value) in entries {
        out.push_str(&format!(
            "{} = {}\n",
            toml_string(key)?,
            toml_string(value.as_str().ok_or("MCP env values must be strings")?)?
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
