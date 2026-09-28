//! `lib/helpers/template_manifest.sh`: content hashes of the templates copied
//! into `.ai/src/`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::transaction::manifest::{hashed_lines, sha256_hex};
use crate::{Error, engine::staging};

pub const REL: &str = ".ai/.template-manifest";

/// `template_manifest_hash`: the SHA-256 of a file, links followed; `None`
/// when the path is not a readable regular file.
pub fn hash(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    std::fs::read(path).ok().map(|bytes| sha256_hex(&bytes))
}

/// `TEMPLATE_MANIFEST_KEYS` and `TEMPLATE_MANIFEST_VALUES`.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct TemplateManifest {
    entries: Vec<(String, String)>,
}

impl TemplateManifest {
    /// `template_manifest_load`: empty when the file is missing.
    pub fn load(root: &Path) -> Result<Self, Error> {
        let path = root.join(REL);
        if !path.is_file() {
            return Ok(Self::default());
        }
        let bytes = std::fs::read(&path).map_err(|e| Error::io(&path, e))?;
        Ok(Self {
            entries: hashed_lines(&bytes),
        })
    }

    /// `template_manifest_lookup`: the first hash recorded for `rel`.
    pub fn lookup(&self, rel: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|(key, _)| key == rel)
            .map(|(_, hash)| hash.as_str())
    }

    /// `template_manifest_record`: the first entry for `rel` takes `hash`, or
    /// one is appended; an empty path or hash is ignored.
    pub fn record(&mut self, rel: &str, hash: &str) {
        if rel.is_empty() || hash.is_empty() {
            return;
        }
        match self.entries.iter_mut().find(|(key, _)| key == rel) {
            Some((_, recorded)) => *recorded = hash.to_string(),
            None => self.entries.push((rel.to_string(), hash.to_string())),
        }
    }

    /// `template_manifest_remove`: every entry for `rel`.
    pub fn remove(&mut self, rel: &str) {
        self.entries.retain(|(key, _)| key != rel);
    }

    /// `${#TEMPLATE_MANIFEST_KEYS[@]} -eq 0`.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// `template_manifest_heal_from_match`: records the shipped hash of every
    /// template whose project copy, at the path `locate` gives it, matches it
    /// byte for byte, whatever the scope of the run.
    pub fn heal_from_match<'a>(
        &mut self,
        templates: impl IntoIterator<Item = (&'a str, &'a [u8])>,
        locate: impl Fn(&str) -> PathBuf,
    ) {
        for (rel, bytes) in templates {
            let Some(current) = hash(&locate(rel)) else {
                continue;
            };
            let shipped = sha256_hex(bytes);
            if current == shipped {
                self.record(rel, &shipped);
            }
        }
    }

    /// `template_manifest_write`: `sort -u` lines, or no file when empty.
    pub fn write(&self, root: &Path) -> Result<(), Error> {
        let ai = root.join(".ai");
        std::fs::create_dir_all(&ai).map_err(|e| Error::io(&ai, e))?;
        let path = root.join(REL);
        if self.entries.is_empty() {
            return match std::fs::remove_file(&path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(Error::io(&path, e)),
                _ => Ok(()),
            };
        }
        let lines: BTreeSet<String> = self
            .entries
            .iter()
            .map(|(rel, hash)| format!("{rel}\t{hash}"))
            .collect();
        let mut text = lines.into_iter().collect::<Vec<_>>().join("\n");
        text.push('\n');
        staging::write_beside(&path, text.as_bytes())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_file_hashes_as_sha256sum_prints_it_and_anything_else_has_no_hash() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.md");
        std::fs::write(&file, "shared rule\n").unwrap();
        assert_eq!(
            hash(&file).as_deref(),
            Some("a5aa98439217de45641258de8f69aea33202a07829b4acf375b5484860ca05b8")
        );
        assert_eq!(hash(dir.path()), None);
        assert_eq!(hash(&dir.path().join("missing.md")), None);
    }

    #[test]
    fn entries_load_look_up_drop_and_write_back_sorted_like_bash() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            TemplateManifest::load(dir.path()).unwrap(),
            TemplateManifest::default()
        );
        std::fs::create_dir_all(dir.path().join(".ai")).unwrap();
        std::fs::write(
            dir.path().join(REL),
            "z.md\tzz\n# c\th\nskills/a/SKILL.md\t1\nnohash\n\tb.md\t\tbb\t\nskills/a/SKILL.md\t2\n",
        )
        .unwrap();
        let mut manifest = TemplateManifest::load(dir.path()).unwrap();
        assert_eq!(manifest.lookup("skills/a/SKILL.md"), Some("1"));
        assert_eq!(manifest.lookup("nohash"), None);
        manifest.remove("skills/a/SKILL.md");
        manifest.write(dir.path()).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join(REL)).unwrap(),
            "b.md\tbb\nz.md\tzz\n"
        );
        manifest.remove("b.md");
        manifest.remove("z.md");
        manifest.write(dir.path()).unwrap();
        assert!(!dir.path().join(REL).exists());
    }

    #[test]
    fn record_updates_the_first_entry_or_appends_and_ignores_blanks() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".ai")).unwrap();
        std::fs::write(dir.path().join(REL), "a.md\t1\na.md\t2\n").unwrap();
        let mut manifest = TemplateManifest::load(dir.path()).unwrap();
        assert!(!manifest.is_empty());
        manifest.record("a.md", "3");
        manifest.record("b.md", "4");
        manifest.record("", "5");
        manifest.record("c.md", "");
        assert_eq!(manifest.lookup("a.md"), Some("3"));
        assert_eq!(manifest.lookup("c.md"), None);
        manifest.write(dir.path()).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join(REL)).unwrap(),
            "a.md\t2\na.md\t3\nb.md\t4\n"
        );
        assert!(TemplateManifest::default().is_empty());
    }

    #[test]
    fn heal_records_only_the_copies_that_match_their_template() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join(".ai/src");
        std::fs::create_dir_all(base.join("rules")).unwrap();
        std::fs::create_dir_all(base.join("skills/a")).unwrap();
        std::fs::write(base.join("AGENTS.md"), "agents\n").unwrap();
        std::fs::write(base.join("rules/same.md"), "same\n").unwrap();
        std::fs::write(base.join("rules/edited.md"), "mine\n").unwrap();
        std::fs::write(base.join("skills/a/SKILL.md"), "skill\n").unwrap();
        let templates: [(&str, &[u8]); 5] = [
            ("AGENTS.md", b"agents\n"),
            ("rules/same.md", b"same\n"),
            ("rules/edited.md", b"theirs\n"),
            ("rules/missing.md", b"new\n"),
            ("skills/a/SKILL.md", b"skill\n"),
        ];
        let mut manifest = TemplateManifest::default();
        manifest.record("rules/edited.md", "old");
        manifest.heal_from_match(templates, |rel| base.join(rel));
        manifest.write(dir.path()).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join(REL)).unwrap(),
            format!(
                "AGENTS.md\t{}\nrules/edited.md\told\nrules/same.md\t{}\nskills/a/SKILL.md\t{}\n",
                sha256_hex(b"agents\n"),
                sha256_hex(b"same\n"),
                sha256_hex(b"skill\n")
            )
        );
    }
}
