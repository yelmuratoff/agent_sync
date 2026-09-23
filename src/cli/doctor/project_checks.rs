//! Project-wide checks: drift, secret scan, skills, rules, orphan outputs, and parent duplicates.

use std::path::{Path, PathBuf};

use super::Doctor;
use super::json::json_valid;
use super::secrets::scan_secrets;
use crate::cli::{files_below, sorted_entries};
use crate::paths::{self, DiskText};
use crate::transaction::manifest::{self, Manifest};
use crate::{
    Error, config::template_manifest, config::yaml_subset, engine::convert, engine::overlay,
};

/// `_DOCTOR_OUTPUT_DIR_MAP`.
const OUTPUT_DIRS: [(&str, &str); 12] = [
    (".claude", "claude"),
    (".cursor", "cursor"),
    (".codex", "codex"),
    (".kimi-code", "kimi"),
    (".opencode", "opencode"),
    (".windsurf", "windsurf"),
    (".gemini", "gemini"),
    (".junie", "junie"),
    (".cline", "cline"),
    (".amazonq", "amazonq"),
    (".zed", "zed"),
    (".agents", "codex"),
];

impl Doctor<'_> {
    /// `_doctor_check_drift`.
    pub(super) fn check_drift(&mut self) -> Result<(), Error> {
        let style = self.style;
        let manifest_path = Path::new(&self.root).join(manifest::REL);
        if !manifest_path.is_file() {
            return self.info(&format!(
                "No .sync-manifest yet — run {} to create it",
                style.cyan("agentsync sync")
            ));
        }
        let Some(manifest) = Manifest::load(&self.root)? else {
            return Ok(());
        };
        if manifest.entries().is_empty() {
            return self.info(".sync-manifest is empty");
        }
        let (mut edited, mut missing, mut clean) = (0, 0, 0);
        for (rel, old_hash) in manifest.entries() {
            let dest = Path::new(&self.root).join(rel);
            if !dest.is_file() {
                self.warn(&format!("{rel} — missing (deleted manually)"))?;
                missing += 1;
                continue;
            }
            let Some(current) = template_manifest::hash(&dest) else {
                self.warn(&format!("{rel} — could not hash"))?;
                continue;
            };
            if &current != old_hash {
                self.warn(&format!("{rel} — edited since last sync"))?;
                edited += 1;
            } else {
                clean += 1;
            }
        }
        if edited == 0 && missing == 0 {
            self.ok(&format!("All {clean} tracked file(s) match the manifest"))
        } else {
            self.say(&format!(
                "\n    {} {} {} {} {}\n",
                style.dim("Re-run"),
                style.cyan("agentsync sync"),
                style.dim("to overwrite, or move edits into"),
                style.cyan(".ai/src/"),
                style.dim("first.")
            ))
        }
    }

    /// `_doctor_scan_one_file`; returns (secret hit, invalid JSON).
    fn scan_one_file(&mut self, file: &Path) -> Result<(bool, bool), Error> {
        let style = self.style;
        let shown = self.rel(&file.disk_text());
        let bytes = std::fs::read(file).map_err(|e| Error::io(file, e))?;
        if file.extension().is_some_and(|ext| ext == "json") && !json_valid(&bytes) {
            self.fail(&format!("{shown}: invalid JSON syntax"))?;
            return Ok((false, true));
        }
        let hits = scan_secrets(&bytes);
        if hits.is_empty() {
            return Ok((false, false));
        }
        self.fail(&format!("{shown}: possible secret"))?;
        for hit in hits {
            self.say(&format!("        {}\n", style.dim(&hit)))?;
        }
        Ok((true, false))
    }

    /// `_doctor_scan_overrides`.
    pub(super) fn scan_overrides(&mut self) -> Result<(), Error> {
        let style = self.style;
        let (mut hits, mut invalid, mut legacy) = (0, 0, 0);
        let tools_root = self.project.user_tools_dir();
        if tools_root.is_dir() {
            for tool_dir in sorted_entries(&tools_root)
                .into_iter()
                .filter(|p| p.is_dir())
            {
                for resource in ["mcp", "settings", "hooks"] {
                    for file in sorted_entries(&tool_dir).into_iter().filter(|p| {
                        p.is_file()
                            && p.file_name()
                                .is_some_and(|n| n.disk_text().starts_with(&format!("{resource}.")))
                    }) {
                        let (hit, bad) = self.scan_one_file(&file)?;
                        hits += usize::from(hit);
                        invalid += usize::from(bad);
                    }
                }
            }
        }
        for resource in ["mcp", "settings", "hooks"] {
            let dir = Path::new(&self.root).join(".ai/src").join(resource);
            if !dir.is_dir() {
                continue;
            }
            for file in sorted_entries(&dir).into_iter().filter(|p| p.is_file()) {
                legacy += 1;
                let (hit, bad) = self.scan_one_file(&file)?;
                hits += usize::from(hit);
                invalid += usize::from(bad);
            }
        }
        if legacy > 0 {
            self.warn(&format!(
                "Legacy payload layout ({legacy} file(s) under .ai/src/{{hooks,mcp,settings}}/). Run {} to move them to .ai/src/tools/<tool>/<resource>.<ext>.",
                style.cyan("agentsync migrate --apply")
            ))?;
        }
        if hits == 0 && invalid == 0 && legacy == 0 {
            self.info("No overrides to scan, or all clean.")?;
        } else if hits > 0 {
            self.say("\n")?;
            self.info(&format!(
                "{}: use ${{ENV_VAR}} placeholders; never commit raw secrets.",
                style.yellow("Reminder")
            ))?;
        }
        Ok(())
    }

    /// `_doctor_check_empty_skills`.
    pub(super) fn check_empty_skills(&mut self) -> Result<(), Error> {
        let style = self.style;
        let skills = Path::new(&self.root).join(".ai/src/skills");
        if !skills.is_dir() {
            return self.info("No .ai/src/skills/ — nothing to scan.");
        }
        let mut found = 0;
        for dir in sorted_entries(&skills).into_iter().filter(|p| p.is_dir()) {
            if !dir.join("SKILL.md").is_file() {
                let name = dir.file_name().unwrap_or_default().disk_text();
                self.advise(&format!(
                    "skills/{name}/ — missing SKILL.md {}",
                    style.dim("(empty skill — populate or remove)")
                ))?;
                found += 1;
            }
        }
        if found == 0 {
            self.ok("All skill directories contain SKILL.md")
        } else {
            self.info(&format!(
                "{} {} {}",
                style.dim("Tip:"),
                style.cyan("agentsync simplify"),
                style.dim("can prune empty skill dirs.")
            ))
        }
    }

    /// `_doctor_check_always_on_rules`.
    pub(super) fn check_always_on_rules(&mut self) -> Result<(), Error> {
        let style = self.style;
        let rules = Path::new(&self.root).join(".ai/src/rules");
        if !rules.is_dir() {
            return self.info("No .ai/src/rules/ — nothing to scan.");
        }
        let (mut count, mut bytes) = (0usize, 0usize);
        for file in sorted_entries(&rules)
            .into_iter()
            .filter(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "md"))
        {
            let content = std::fs::read(&file).map_err(|e| Error::io(&file, e))?;
            if is_path_scoped(&content) {
                continue;
            }
            count += 1;
            bytes += content.len();
        }
        if count == 0 {
            self.ok("No always-on rules (every rule is paths:-scoped)")
        } else if bytes >= 20000 {
            self.advise(&format!(
                "{count} always-on rule(s) load on every task (~{} KB, ~{} tokens). Add {} frontmatter to domain rules so they load only when matching files are touched — a large always-on set dilutes attention.",
                bytes / 1024,
                bytes / 4,
                style.cyan("paths:")
            ))
        } else {
            self.ok(&format!(
                "Always-on rule context is lean ({count} file(s), ~{} KB)",
                bytes / 1024
            ))
        }
    }

    /// `_doctor_check_orphan_outputs`.
    pub(super) fn check_orphan_outputs(&mut self) -> Result<(), Error> {
        let style = self.style;
        let enabled = self.project.enabled_tools()?;
        let mut found = 0;
        if Path::new(&self.root).join(".agent").is_dir() {
            self.advise(&format!(
                ".agent/ — legacy pre-v0.6 layout (run {} to preview cleanup)",
                style.cyan("agentsync migrate --legacy")
            ))?;
            found += 1;
        }
        for (dir, tool) in OUTPUT_DIRS {
            if !Path::new(&self.root).join(dir).is_dir() {
                continue;
            }
            if dir == ".agents" && (enabled.contains("codex") || enabled.contains("antigravity")) {
                continue;
            }
            if !enabled.contains(tool) {
                self.advise(&format!(
                    "{dir}/ — orphan (tool '{tool}' not enabled; output left from prior run)"
                ))?;
                found += 1;
            }
        }
        if found == 0 {
            self.ok("No orphan tool-output directories")?;
        }
        Ok(())
    }

    /// `_doctor_check_cross_project`.
    pub(super) fn check_cross_project(&mut self) -> Result<(), Error> {
        let style = self.style;
        let child_src = format!("{}/.ai/src", self.root);
        if !Path::new(&child_src).is_dir() {
            return self.info("No .ai/src/ in this project — skipping cross-project scan.");
        }
        let mut from_shared = false;
        let parent_src = match self
            .config
            .as_deref()
            .and_then(|config| overlay::shared_parent_src(config, &self.root))
        {
            Some(parent) => {
                from_shared = true;
                Some(parent)
            }
            None => paths::find_parent_ai_src(&self.root),
        };
        let Some(parent_src) = parent_src else {
            return self.info("No parent .ai/src/ found within git boundary.");
        };
        let origin_hint = if from_shared {
            format!(" {}", style.dim("(from shared.path)"))
        } else {
            String::new()
        };
        self.info(&format!(
            "Parent source: {}{origin_hint}",
            style.dim(&parent_src)
        ))?;
        self.say("\n")?;

        let inherited: Vec<&str> = self
            .config
            .as_deref()
            .map(|config| {
                overlay::inherit_categories(&yaml_subset::value(config, "shared.inherit"))
            })
            .unwrap_or_default();
        let parent_root = paths::parent(&parent_src);
        let (mut dupes, mut divergent) = (0, 0);
        let mut pairs: Vec<(String, PathBuf)> = Vec::new();
        for category in ["rules", "commands", "agents"] {
            let dir = Path::new(&parent_src).join(category);
            if !dir.is_dir() {
                continue;
            }
            for file in sorted_entries(&dir)
                .into_iter()
                .filter(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "md"))
            {
                let name = file.file_name().unwrap_or_default().disk_text();
                pairs.push((format!("{category}/{name}"), file));
            }
        }
        let skills = Path::new(&parent_src).join("skills");
        if skills.is_dir() {
            let mut files = Vec::new();
            files_below(&skills, &mut files);
            files.retain(|p| {
                !p.file_name()
                    .is_some_and(|n| n.disk_text().starts_with('.'))
            });
            files.sort();
            for file in files {
                let rel = file
                    .strip_prefix(&parent_src)
                    .map(|p| p.disk_text())
                    .unwrap_or_default();
                pairs.push((rel, file));
            }
        }
        for (rel, parent_file) in pairs {
            let child_file = Path::new(&child_src).join(&rel);
            if !child_file.is_file() {
                continue;
            }
            let (Some(child_hash), Some(parent_hash)) = (
                template_manifest::hash(&child_file),
                template_manifest::hash(&parent_file),
            ) else {
                continue;
            };
            let category = rel.split('/').next().unwrap_or("");
            if child_hash == parent_hash {
                let hint = if inherited.contains(&category) {
                    format!(" {}", style.dim("(inherited via shared: — safe to delete)"))
                } else {
                    String::new()
                };
                let shown = parent_file
                    .disk_text()
                    .strip_prefix(&format!("{parent_root}/"))
                    .unwrap_or(&parent_file.disk_text())
                    .to_string();
                self.advise(&format!(
                    "{rel} — duplicate of parent's {}{hint}",
                    style.dim(&shown)
                ))?;
                dupes += 1;
            } else {
                let content =
                    std::fs::read(&parent_file).map_err(|e| Error::io(&parent_file, e))?;
                if convert::read_field(&content, "category") == b"governance" {
                    self.advise(&format!(
                        "{rel} — {} {}",
                        style.yellow("governance file diverges from parent"),
                        style.dim("(category: governance — likely a mistake, not an override)")
                    ))?;
                } else {
                    self.info(&format!(
                        "{rel} — diverges from parent {}",
                        style.dim("(review intent)")
                    ))?;
                }
                divergent += 1;
            }
        }
        if dupes == 0 && divergent == 0 {
            self.ok("No source files shared with parent.")
        } else if dupes > 0 {
            self.say("\n")?;
            self.info(&format!(
                "{} {} {}",
                style.dim("Run"),
                style.cyan("agentsync dedupe"),
                style.dim("to remove duplicates interactively.")
            ))
        } else {
            Ok(())
        }
    }
}

/// `sed -n '2,/^---$/p' | grep -q '^paths:[[:space:]]*$'` after a first
/// line of `---`. sed tests the closing address from line 3 on, so a `---`
/// on line 2 does not end the range.
fn is_path_scoped(content: &[u8]) -> bool {
    let mut lines = content.split(|b| *b == b'\n');
    if lines.next() != Some(b"---") {
        return false;
    }
    for (index, line) in lines.enumerate() {
        if line.strip_prefix(b"paths:").is_some_and(|rest| {
            rest.iter()
                .all(|b| matches!(b, b' ' | b'\t' | b'\r' | 0x0b | 0x0c))
        }) {
            return true;
        }
        if index > 0 && line == b"---" {
            return false;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_paths_key_is_found_like_the_sed_range_does() {
        assert!(is_path_scoped(
            b"---\npaths:\n  - \"**/*.ts\"\n---\n# Scoped\n"
        ));
        assert!(is_path_scoped(b"---\n---\npaths:\n"));
        assert!(is_path_scoped(b"---\npaths:  \n---\n"));
        assert!(!is_path_scoped(b"# Rule\n"));
        assert!(!is_path_scoped(b"---\ndesc: x\n---\npaths:\n"));
        assert!(!is_path_scoped(b"---\npaths: foo\n---\n"));
        assert!(!is_path_scoped(b"---"));
        assert!(!is_path_scoped(b"paths:\n"));
    }
}
