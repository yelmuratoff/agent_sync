//! Key-level ownership of a settings file another program also writes. Sync
//! merges the document it would otherwise write whole into the live file by
//! key: it sets the keys that document declares, removes the ones it declared
//! before and no longer does, and leaves every other key as the other program
//! wrote it. The format follows the file's extension.

use std::collections::BTreeMap;

use sha2::{Digest, Sha256};

use crate::engine::{json_keys, toml_keys};

pub type KeyPath = Vec<String>;

/// Top-level maps whose entries are owned whole, one per server, so a server
/// the other program added sits beside the declared ones untouched.
pub const UNIT_ROOTS: [&str; 4] = ["mcp_servers", "mcpServers", "mcp", "context_servers"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Toml,
    Json,
}

impl Format {
    pub fn of(path: &str) -> Option<Self> {
        let leaf = path.rsplit('/').next().unwrap_or(path);
        if leaf.ends_with(".toml") {
            Some(Self::Toml)
        } else if leaf.ends_with(".json") {
            Some(Self::Json)
        } else {
            None
        }
    }
}

/// The keys one file's sync owns, each with a short hash of its value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Owned(BTreeMap<KeyPath, String>);

impl Owned {
    pub(crate) fn from_pairs(pairs: impl IntoIterator<Item = (KeyPath, String)>) -> Self {
        Self(pairs.into_iter().collect())
    }

    pub fn keys(&self) -> impl Iterator<Item = &KeyPath> {
        self.0.keys()
    }

    /// The manifest column: a JSON array of `[path, hash]` pairs.
    pub fn encode(&self) -> String {
        let pairs: Vec<(&KeyPath, &String)> = self.0.iter().collect();
        serde_json::to_string(&pairs).unwrap_or_default()
    }

    pub fn decode(text: &str) -> Option<Self> {
        let pairs: Vec<(KeyPath, String)> = serde_json::from_str(text).ok()?;
        Some(Self(pairs.into_iter().collect()))
    }

    pub fn digest(&self) -> String {
        sha256_hex(self.encode().as_bytes())
    }

    /// This record without the keys that hash as absent.
    pub fn present(self) -> Self {
        Self(
            self.0
                .into_iter()
                .filter(|(_, hash)| !hash.is_empty())
                .collect(),
        )
    }

    /// Keys whose value in `now` no longer matches this record.
    pub fn changed(&self, now: &Owned) -> Vec<KeyPath> {
        self.0
            .iter()
            .filter(|(key, hash)| now.0.get(*key) != Some(*hash))
            .map(|(key, _)| key.clone())
            .collect()
    }
}

#[derive(Debug)]
pub struct Merged {
    pub text: String,
    pub owned: Owned,
    /// Owned keys another program changed since `previous` was recorded, or,
    /// without a record, declared keys whose live value differs.
    pub drifted: Vec<KeyPath>,
}

/// `desired` merged over `live`. Keys `previous` owned and `desired` no longer
/// declares are removed; without a record nothing is removed. The text comes
/// back byte for byte when every declared value already matches.
pub fn merge(
    format: Format,
    live: &str,
    desired: &str,
    previous: Option<&Owned>,
) -> Result<Merged, String> {
    match format {
        Format::Toml => toml_keys::merge(live, desired, previous),
        Format::Json => json_keys::merge(live, desired, previous),
    }
}

/// The current hashes in `live` of the keys `record` owns; an absent key
/// hashes as empty.
pub fn owned_in(format: Format, live: &str, record: &Owned) -> Result<Owned, String> {
    match format {
        Format::Toml => toml_keys::owned_in(live, record),
        Format::Json => json_keys::owned_in(live, record),
    }
}

/// `source` with each of `keys` set to its value in `live`, or removed where
/// `live` no longer has it.
pub fn adopt(format: Format, live: &str, source: &str, keys: &[KeyPath]) -> Result<String, String> {
    match format {
        Format::Toml => toml_keys::adopt(live, source, keys),
        Format::Json => json_keys::adopt(live, source, keys),
    }
}

/// Whether `path` is one server entry of a server map.
pub fn is_unit(path: &KeyPath) -> bool {
    path.len() == 2 && UNIT_ROOTS.contains(&path[0].as_str())
}

/// A key path as TOML writes it, segments quoted where they must be.
pub fn display(path: &KeyPath) -> String {
    path.iter()
        .map(|segment| {
            toml_edit::Key::new(segment.as_str())
                .display_repr()
                .into_owned()
        })
        .collect::<Vec<_>>()
        .join(".")
}

/// The hash a record keeps for one value, given its canonical text.
pub(crate) fn short_hash(canonical: &str) -> String {
    sha256_hex(canonical.as_bytes())[..16].to_string()
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_format_follows_the_extension() {
        assert_eq!(Format::of(".codex/config.toml"), Some(Format::Toml));
        assert_eq!(Format::of("/h/.claude/settings.json"), Some(Format::Json));
        assert_eq!(Format::of(".cursor/rules"), None);
        assert_eq!(Format::of("a.toml/b"), None);
    }

    #[test]
    fn displays_key_paths_as_toml_writes_them() {
        assert_eq!(display(&vec!["tui".into(), "theme".into()]), "tui.theme");
        assert_eq!(
            display(&vec!["projects".into(), "/tmp/x".into()]),
            "projects.\"/tmp/x\""
        );
    }

    #[test]
    fn owned_records_round_trip_through_the_manifest_column() {
        let owned = Owned::from_pairs([
            (vec!["model".into()], "ab".into()),
            (vec!["odd\tkey".into(), "x".into()], "cd".into()),
        ]);
        assert!(!owned.encode().contains('\t'));
        assert_eq!(Owned::decode(&owned.encode()), Some(owned));
        assert_eq!(Owned::decode("not json"), None);
    }
}
