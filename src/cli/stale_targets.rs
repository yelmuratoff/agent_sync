//! Outputs a disabled target left behind: `targets.<key>.enabled: false`
//! stops the pass, so nothing updates or prunes what it wrote before, and
//! the manifest keeps claiming the file. `check` and `doctor` report them.

use crate::config::tool::Tool;
use crate::engine::render::TARGET_KEYS;
use crate::project::Project;
use crate::{Error, paths};

/// A recorded output below the dest of a target its enabled tool switched off.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Stale {
    pub rel: String,
    pub slug: String,
    pub key: &'static str,
}

/// Each file of `recorded` (repo-relative manifest paths) that still exists,
/// lies at or below the dest of a disabled target of an enabled tool, and no
/// enabled target writes.
pub(crate) fn left_by_disabled_targets(
    project: &Project,
    recorded: &[String],
) -> Result<Vec<Stale>, Error> {
    let mut enabled_dests = Vec::new();
    let mut disabled = Vec::new();
    for slug in project.enabled_tools()? {
        let tool = Tool::load(project, &slug)?;
        for key in TARGET_KEYS {
            let raw = tool.value(&format!("targets.{key}.dest"));
            let dest = raw.trim_start_matches("./").trim_end_matches('/');
            if dest.is_empty() || paths::is_absolute(dest) || dest.starts_with('~') {
                continue;
            }
            if tool.flag(&format!("targets.{key}.enabled")) == Some(false) {
                disabled.push((dest.to_string(), slug.clone(), key));
            } else {
                enabled_dests.push(dest.to_string());
            }
        }
    }
    let under = |rel: &str, dest: &str| rel == dest || rel.starts_with(&format!("{dest}/"));
    let mut found = Vec::new();
    for rel in recorded {
        if enabled_dests.iter().any(|dest| under(rel, dest)) || !project.root.join(rel).is_file() {
            continue;
        }
        if let Some((_, slug, key)) = disabled.iter().find(|(dest, ..)| under(rel, dest)) {
            found.push(Stale {
                rel: rel.clone(),
                slug: slug.clone(),
                key,
            });
        }
    }
    Ok(found)
}

/// The two report lines for one stale output: the finding, then the hint.
pub(crate) fn lines(stale: &Stale) -> [String; 2] {
    let Stale { rel, slug, key } = stale;
    [
        format!(
            "! {rel} is left from {slug} targets.{key}, which is disabled; sync no longer updates it"
        ),
        format!("  • Delete it, or set targets.{key}.enabled back to true"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::DiskText;

    #[test]
    fn only_a_file_no_enabled_target_writes_is_stale() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let write = |rel: &str, text: &str| {
            let path = root.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        };
        write(
            ".ai/agent_sync.yaml",
            "tools:\n  enabled:\n    - claude\n    - codex\n",
        );
        write(
            ".ai/src/tools/claude.yaml",
            "targets:\n  agents:\n    enabled: false\n  rules:\n    dest: \"AGENTS.md\"\n    enabled: false\n",
        );
        write("CLAUDE.md", "old\n");
        write("AGENTS.md", "shared\n");
        let project = Project::at(root.disk_text()).unwrap();
        let recorded = ["AGENTS.md", "CLAUDE.md", "gone.md"].map(String::from);
        assert_eq!(
            left_by_disabled_targets(&project, &recorded).unwrap(),
            vec![Stale {
                rel: "CLAUDE.md".to_string(),
                slug: "claude".to_string(),
                key: "agents",
            }]
        );
    }
}
