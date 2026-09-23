use serde_json::Value;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

use crate::Error;
use crate::config::mcp_catalog;

pub struct Lock {
    path: PathBuf,
    _file: File,
}

impl Lock {
    pub fn acquire(parent: &Path) -> Result<Self, Error> {
        let path = parent.join(".agentsync-mcp-use.lock");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|error| Error::io(&path, error))?;
        Ok(Self { path, _file: file })
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

pub fn compose(
    existing: &[u8],
    selected: &[u8],
    id: &str,
    replace: bool,
) -> Result<Option<Vec<u8>>, &'static str> {
    if existing.len() as u64 > mcp_catalog::MAX_MANIFEST_BYTES {
        return Err("Existing MCP source exceeds the merge byte limit");
    }
    let mut source = mcp_catalog::parse_strict(existing)
        .map_err(|_| "Existing MCP source is not supported JSON")?;
    let root = source
        .as_object_mut()
        .ok_or("Existing MCP source must be a JSON object")?;
    let servers = root
        .get_mut("mcpServers")
        .and_then(Value::as_object_mut)
        .ok_or("Existing MCP source needs an mcpServers object")?;
    if servers.values().any(|server| !server.is_object()) {
        return Err("Existing MCP source has an unsupported server structure");
    }
    let selected: Value = serde_json::from_slice(selected)
        .map_err(|_| "Selected MCP connection is not valid JSON")?;
    let server = selected
        .get("mcpServers")
        .and_then(|servers| servers.get(id))
        .ok_or("Selected MCP connection is missing its server")?;
    if servers.get(id) == Some(server) {
        return Ok(None);
    }
    if servers.contains_key(id) && !replace {
        return Err("MCP server ID already exists; pass --replace <id> to replace it");
    }
    servers.insert(id.to_string(), server.clone());
    let mut output = serde_json::to_vec(&source).map_err(|_| "Cannot encode merged MCP source")?;
    output.push(b'\n');
    if output.len() as u64 > mcp_catalog::MAX_MANIFEST_BYTES {
        return Err("Merged MCP source exceeds the merge byte limit");
    }
    Ok(Some(output))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_unrelated_members_and_requires_explicit_replacement() {
        let old = br#"{"notes":{"x":true},"mcpServers":{"first":{"command":"old"},"second":{"url":"https://example.test"}}}"#;
        let selected = br#"{"mcpServers":{"first":{"command":"new"}}}"#;
        assert!(compose(old, selected, "first", false).is_err());
        let merged = compose(old, selected, "first", true).unwrap().unwrap();
        let value: Value = serde_json::from_slice(&merged).unwrap();
        assert_eq!(value["notes"]["x"], true);
        assert_eq!(value["mcpServers"]["second"]["url"], "https://example.test");
        assert_eq!(value["mcpServers"]["first"]["command"], "new");
        assert!(
            compose(&merged, selected, "first", false)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn rejects_duplicate_keys_and_unsupported_structure() {
        let selected = br#"{"mcpServers":{"first":{"command":"new"}}}"#;
        for old in [
            br#"{"mcpServers":{},"mcpServers":{}}"#.as_slice(),
            br#"{"mcpServers":[]}"#.as_slice(),
            br#"[]"#.as_slice(),
            br#"{"mcpServers":{"other":[]}}"#.as_slice(),
        ] {
            assert!(compose(old, selected, "first", false).is_err());
        }
    }
}
