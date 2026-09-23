//! `agentsync doctor`: `cmd_doctor` of `lib/helpers/doctor.sh`, which checks
//! a project's layout, tools, overrides, sources, drift, secrets, skills,
//! rules, tool outputs, and parent duplicates, and exits 0, 1, or 2.

mod json;
mod project_checks;
mod secrets;
mod tool_checks;

use std::io::Write;
use std::path::Path;

use super::put;
use crate::config::payload::{self, Source};
use crate::config::tool::Tool;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths::{DiskText, ExplicitSource, Paths};
use crate::project::Project;
use crate::{Error, config::catalog, config::edit_paths, config::format_rev, config::yaml_subset};

pub const HELP: Help = Help {
    command: "doctor",
    tagline: "validate setup and surface warnings",
    synopsis: &["doctor"],
    description: &[
        "Checks the project section by section and prints one line per\nfinding: project layout, enabled tools, edit paths, user overrides,\nsource directories, drift, security, skills, rules, tool outputs, and\ncross-project duplicates. The report goes to stdout; the summary line\nnames every command to run next.",
        "Honours AGENTSYNC_CONFIG_PATH for the project config and\nAGENTSYNC_EXTERNAL_SOURCE_ROOTS for source directories that live\noutside the project.",
    ],
    sections: &[
        Section {
            title: "OPTIONS",
            entries: &[("-h, --help", "Show this help")],
        },
        Section {
            title: "EXIT STATUS",
            entries: &[
                ("0", "Every check passed, or only advisories were raised"),
                ("1", "Warnings: setup problems worth fixing"),
                ("2", "Errors, or no .ai/ directory to check"),
            ],
        },
        Section {
            title: "SEE ALSO",
            entries: &[
                (
                    "agentsync check",
                    "Compare generated outputs with the source",
                ),
                ("agentsync init", "Create the .ai/ directory doctor checks"),
            ],
        },
    ],
    examples: &["doctor"],
};

/// What `doctor` takes from the process.
pub struct Env<'a> {
    pub version: &'a str,
    pub external_roots: Option<String>,
}

struct External {
    raw: String,
    abs: String,
    refused: bool,
    untrusted: bool,
}

struct Doctor<'a> {
    project: &'a Project,
    root: String,
    config: Option<String>,
    config_shown: String,
    paths: Paths,
    style: &'a Style,
    version: &'a str,
    warnings: usize,
    errors: usize,
    advisories: usize,
    warned_legacy: bool,
    out: &'a mut dyn Write,
    err: &'a mut dyn Write,
}

impl Doctor<'_> {
    fn say(&mut self, text: &str) -> Result<(), Error> {
        put(self.out, text.as_bytes())
    }

    fn ok(&mut self, text: &str) -> Result<(), Error> {
        let line = format!("    {} {text}\n", self.style.green("✓"));
        self.say(&line)
    }

    fn warn(&mut self, text: &str) -> Result<(), Error> {
        self.warnings += 1;
        let line = format!("    {} {text}\n", self.style.yellow("!"));
        self.say(&line)
    }

    fn fail(&mut self, text: &str) -> Result<(), Error> {
        self.errors += 1;
        let line = format!("    {} {text}\n", self.style.red("✗"));
        self.say(&line)
    }

    fn info(&mut self, text: &str) -> Result<(), Error> {
        let line = format!("    {} {text}\n", self.style.dim("·"));
        self.say(&line)
    }

    fn advise(&mut self, text: &str) -> Result<(), Error> {
        self.advisories += 1;
        let line = format!("    {} {text}\n", self.style.yellow("!"));
        self.say(&line)
    }

    fn heading(&mut self, text: &str) -> Result<(), Error> {
        let line = format!("{}\n", self.style.bold(&format!("  {text}")));
        self.say(&line)
    }

    fn rel(&self, path: &str) -> String {
        path.strip_prefix(&format!("{}/", self.root))
            .unwrap_or(path)
            .to_string()
    }

    /// `_doctor_external_source`.
    fn external_source(&self, key: &str) -> Option<External> {
        let config = self.config.as_deref()?;
        let raw = yaml_subset::value(config, &format!("source.{key}"));
        if raw.is_empty() {
            return None;
        }
        let (refused, untrusted) = match self.paths.classify_explicit_source(&raw) {
            ExplicitSource::Inside => return None,
            ExplicitSource::Outside(_) => (false, false),
            ExplicitSource::Refused(_) => (true, false),
            ExplicitSource::Untrusted(_) => (false, true),
        };
        Some(External {
            abs: self.paths.absolute(&raw),
            raw,
            refused,
            untrusted,
        })
    }

    fn tool(&self, slug: &str) -> Result<Tool, Error> {
        Tool::load(self.project, slug)
    }

    fn display_name(&self, slug: &str) -> Result<String, Error> {
        Ok(self.tool(slug)?.display_name())
    }

    /// `resolve_payload_source` under `[[ -f ]]`: the payload when its file
    /// exists, with the legacy-layout warning on stderr once per run.
    fn resolve(&mut self, tool: &Tool, resource: &str) -> Result<Option<Source>, Error> {
        let (source, legacy) = payload::effective_source(self.project, tool, resource)?;
        if let Some(path) = legacy.filter(|_| !self.warned_legacy) {
            self.warned_legacy = true;
            put(
                self.err,
                payload::legacy_warning(self.project, &path, self.style).as_bytes(),
            )?;
        }
        Ok(source.filter(|source| match source {
            Source::Disk(path) => path.is_file(),
            Source::Shipped(_) => true,
        }))
    }

    fn source_shown(&self, source: &Source) -> String {
        self.rel(&source.shown())
    }
}

/// `cmd_doctor`: the report on `out`, the tri-state status as the result.
pub fn doctor(
    args: &[String],
    discover: &dyn Fn() -> Result<Project, Error>,
    style: &Style,
    env: &Env,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    if matches!(args.first().map(String::as_str), Some("--help" | "-h")) {
        put(out, HELP.render(style).as_bytes())?;
        return Ok(0);
    }
    let project = match discover() {
        Ok(project) => project,
        Err(Error::ConfigPathNotFound(path)) => {
            put(
                err,
                format!(
                    "{}: AGENTSYNC_CONFIG_PATH is set but file not found: {}\n",
                    style.red("Error"),
                    path.display()
                )
                .as_bytes(),
            )?;
            return Ok(2);
        }
        Err(e) => return Err(e),
    };
    let root = project.root.disk_text();
    let config = match &project.config_path {
        Some(path) => Some(
            std::fs::read(path)
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                .map_err(|e| Error::io(path, e))?,
        ),
        None => None,
    };
    let config_shown = project
        .config_path
        .as_ref()
        .map(|p| {
            let text = p.disk_text();
            text.strip_prefix(&format!("{root}/"))
                .unwrap_or(&text)
                .to_string()
        })
        .unwrap_or_default();
    let mut paths = Paths::on_disk(&root);
    paths.trust_external_roots(env.external_roots.as_deref());
    let mut d = Doctor {
        project: &project,
        root: root.clone(),
        config,
        config_shown,
        paths,
        style,
        version: env.version,
        warnings: 0,
        errors: 0,
        advisories: 0,
        warned_legacy: false,
        out,
        err,
    };

    d.say(&format!(
        "\n{}\n{}\n\n",
        style.bold("  AgentSync Doctor"),
        style.dim(&format!("  {root}"))
    ))?;

    d.heading("Project layout")?;
    if Path::new(&root).join(".ai").is_dir() {
        d.ok(".ai/ directory present")?;
    } else {
        d.fail(&format!(
            ".ai/ directory missing — run {}",
            style.cyan("agentsync init")
        ))?;
        d.say("\n")?;
        return Ok(2);
    }
    let agents_found = match d.external_source("agents") {
        Some(external) => Path::new(&external.abs).is_file(),
        None => {
            Path::new(&root).join(".ai/src/AGENTS.md").is_file()
                || Path::new(&root).join(".ai/AGENTS.md").is_file()
        }
    };
    if agents_found {
        d.ok("AGENTS.md source file found")?;
    } else {
        d.fail("No AGENTS.md in .ai/src/ or .ai/ — sync will fail")?;
    }
    if let Some(config) = d.config.clone() {
        let shown = d.config_shown.clone();
        d.ok(&format!("Project config: {}", style.dim(&shown)))?;
        let pinned = yaml_subset::value(&config, "agentsync_version").replace('"', "");
        if !pinned.is_empty() && !d.version.is_empty() && pinned != d.version {
            d.warn(&format!(
                "CLI version {} differs from pinned {} — run {} to align",
                style.dim(&format!("v{}", d.version)),
                style.dim(&format!("v{pinned}")),
                style.cyan("agentsync upgrade-config")
            ))?;
        }
        let engine_rev = format_rev::engine();
        let project_rev = format_rev::project(&config);
        if project_rev < engine_rev {
            d.warn(&format!(
                "Project format {} is behind the engine {} — run {} to preview",
                style.dim(&format!("r{project_rev}")),
                style.dim(&format!("r{engine_rev}")),
                style.cyan("agentsync migrate")
            ))?;
        } else {
            d.ok(&format!(
                "Project format: {}",
                style.dim(&format!("r{project_rev}"))
            ))?;
        }
    } else {
        d.warn("No agent_sync.yaml — using defaults only")?;
    }
    d.say("\n")?;

    d.heading("Enabled tools")?;
    let enabled = project.enabled_tools()?;
    if enabled.is_empty() {
        d.info(&format!(
            "No tools enabled — run {}",
            style.cyan("agentsync enable <slug>")
        ))?;
    } else {
        for slug in &enabled {
            let has_base = catalog::base_tool_yaml(slug).is_some();
            let has_user = project.user_tool_file(slug).is_file();
            if has_base && has_user {
                let display = d.display_name(slug)?;
                d.ok(&format!("{display} {}", style.dim("(customized)")))?;
            } else if has_base {
                let display = d.display_name(slug)?;
                d.ok(&display)?;
            } else if has_user {
                d.warn(&format!(
                    "{slug}: custom tool (no base) — ensure override defines full config"
                ))?;
            } else {
                d.fail(&format!(
                    "{slug}: unknown — no base template and no override"
                ))?;
            }
            let tool = d.tool(slug)?;
            d.check_commands_config(&tool)?;
            d.check_payload_ownership(&tool)?;
            d.check_guard_wired(&tool)?;
        }
    }
    d.say("\n")?;

    if !enabled.is_empty() {
        d.heading("Edit paths")?;
        let known: Vec<String> = {
            let mut all = catalog::base_tools();
            all.extend(project.user_override_tools()?);
            all
        };
        let mut any = false;
        for slug in &enabled {
            if !known.contains(slug) {
                continue;
            }
            let tool = d.tool(slug)?;
            let text = edit_paths::checklist(&project, &tool, style);
            d.say(&text)?;
            any = true;
        }
        if !any {
            d.info("No tools with editable payloads.")?;
        }
        d.say("\n")?;
    }

    d.heading("User overrides")?;
    let overrides = project.user_override_tools()?;
    if overrides.is_empty() {
        d.info("No customizations — all tools inherit fully from base")?;
    } else {
        let configured = project.configured_enabled_tools()?;
        for slug in &overrides {
            let user_file = project.user_tool_file(slug);
            let text = std::fs::read(&user_file)
                .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
                .map_err(|e| Error::io(&user_file, e))?;
            if yaml_subset::value(&text, "enabled") == "true" && !configured.contains(slug) {
                d.warn(&format!(
                    "{slug}: uses legacy 'enabled: true' — migrate with {}",
                    style.cyan(&format!("agentsync enable {slug}"))
                ))?;
            } else if catalog::base_tool_yaml(slug).is_some() {
                let display = d.display_name(slug)?;
                d.info(&format!(
                    "{display} — see {}",
                    style.cyan(&format!("agentsync diff {slug}"))
                ))?;
            } else {
                d.info(&format!("{slug} (custom tool, no base)"))?;
            }
        }
    }
    d.say("\n")?;

    d.heading("Source directories")?;
    for (src, key) in [
        ("AGENTS.md", "agents"),
        ("rules", "rules"),
        ("skills", "skills"),
        ("commands", "commands"),
        ("agents", "subagents"),
    ] {
        let (display, abs) = match d.external_source(key) {
            Some(external) => {
                if external.refused {
                    d.fail(&format!(
                        "source.{key} must not be the filesystem root, the home directory, or the project root or its ancestor: {}",
                        external.raw
                    ))?;
                    continue;
                }
                if external.untrusted {
                    d.fail(&format!(
                        "source.{key} points outside the project and AGENTSYNC_EXTERNAL_SOURCE_ROOTS does not list it: {}",
                        external.raw
                    ))?;
                    continue;
                }
                (external.raw, external.abs)
            }
            None => (format!(".ai/src/{src}"), format!("{root}/.ai/src/{src}")),
        };
        if Path::new(&abs).exists() {
            d.ok(&display)?;
        } else if src == "AGENTS.md" {
            d.fail(&format!("{display} missing (required)"))?;
        } else {
            d.info(&format!("{display} not present (optional)"))?;
        }
    }
    d.say("\n")?;

    d.heading("Drift")?;
    d.check_drift()?;
    d.say("\n")?;

    d.heading("Security")?;
    d.scan_overrides()?;
    d.say("\n")?;

    d.heading("Skills")?;
    d.check_empty_skills()?;
    d.say("\n")?;

    d.heading("Rules")?;
    d.check_always_on_rules()?;
    d.say("\n")?;

    d.heading("Tool outputs")?;
    d.check_orphan_outputs()?;
    d.say("\n")?;

    d.heading("Cross-project")?;
    d.check_cross_project()?;
    d.say("\n")?;

    let advisory_label = if d.advisories > 0 {
        format!(
            ", {}",
            style.dim(&format!("{} advisory(ies)", d.advisories))
        )
    } else {
        String::new()
    };
    if d.errors > 0 {
        d.say(&format!(
            "  {}, {}{advisory_label}\n\n",
            style.red(&format!("{} error(s)", d.errors)),
            style.yellow(&format!("{} warning(s)", d.warnings))
        ))?;
        Ok(2)
    } else if d.warnings > 0 {
        d.say(&format!(
            "  {} with {}{advisory_label}\n\n",
            style.green("OK"),
            style.yellow(&format!("{} warning(s)", d.warnings))
        ))?;
        Ok(1)
    } else if d.advisories > 0 {
        d.say(&format!(
            "  {} with {}\n\n",
            style.green("OK"),
            style.dim(&format!("{} advisory(ies)", d.advisories))
        ))?;
        Ok(0)
    } else {
        d.say(&format!("  {}\n\n", style.green("All checks passed.")))?;
        Ok(0)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn project(files: &[(&str, &str)], dirs: &[&str]) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        for rel in dirs {
            std::fs::create_dir_all(Path::new(&root).join(rel)).unwrap();
        }
        for (rel, text) in files {
            let path = Path::new(&root).join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        (dir, root)
    }

    fn run(root: &str) -> (u8, String, String) {
        let env = Env {
            version: "0.36.0",
            external_roots: None,
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = doctor(
            &[],
            &|| Project::at(root),
            &Style::plain(),
            &env,
            &mut out,
            &mut err,
        )
        .unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[test]
    fn help_is_answered_on_stdout_before_the_project_is_discovered() {
        let env = Env {
            version: "0.36.0",
            external_roots: None,
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = doctor(
            &["--help".to_string()],
            &|| panic!("--help must not discover the project"),
            &Style::plain(),
            &env,
            &mut out,
            &mut err,
        )
        .unwrap();
        assert_eq!(status, 0);
        assert_eq!(err, b"");
        let out = String::from_utf8(out).unwrap();
        assert_eq!(out, HELP.render(&Style::plain()));
        assert!(out.starts_with(
            "\n  agentsync doctor — validate setup and surface warnings\n\n  USAGE\n    agentsync doctor\n"
        ));
    }

    #[test]
    fn a_project_without_a_config_reports_like_cmd_doctor() {
        let (_dir, root) = project(&[(".ai/src/AGENTS.md", "# Agents\n")], &[".git"]);
        let (status, out, err) = run(&root);
        assert_eq!(status, 1);
        assert_eq!(err, "");
        let expected = format!(
            "\n  AgentSync Doctor\n  {root}\n\n  Project layout\n    ✓ .ai/ directory present\n    ✓ AGENTS.md source file found\n    ! No agent_sync.yaml — using defaults only\n\n  Enabled tools\n    · No tools enabled — run agentsync enable <slug>\n\n  User overrides\n    · No customizations — all tools inherit fully from base\n\n  Source directories\n    ✓ .ai/src/AGENTS.md\n    · .ai/src/rules not present (optional)\n    · .ai/src/skills not present (optional)\n    · .ai/src/commands not present (optional)\n    · .ai/src/agents not present (optional)\n\n  Drift\n    · No .sync-manifest yet — run agentsync sync to create it\n\n  Security\n    · No overrides to scan, or all clean.\n\n  Skills\n    · No .ai/src/skills/ — nothing to scan.\n\n  Rules\n    · No .ai/src/rules/ — nothing to scan.\n\n  Tool outputs\n    ✓ No orphan tool-output directories\n\n  Cross-project\n    · No parent .ai/src/ found within git boundary.\n\n  OK with 1 warning(s)\n\n"
        );
        assert_eq!(out, expected);
    }

    #[test]
    fn a_pinned_config_stale_manifest_and_orphan_output_report_like_cmd_doctor() {
        let (_dir, root) = project(
            &[
                (".ai/src/AGENTS.md", "# Agents\n"),
                (
                    ".ai/src/rules/scoped.md",
                    "---\npaths:\n  - \"**/*.ts\"\n---\n# Scoped\n",
                ),
                (
                    ".ai/agent_sync.yaml",
                    "agentsync_version: \"0.0.1\"\nformat: 1\ntools:\n  - cursor\n",
                ),
                (
                    ".ai/.sync-manifest",
                    "CLAUDE.md\t0000000000000000000000000000000000000000000000000000000000000000\n",
                ),
            ],
            &[".git", ".ai/src/skills/empty", ".claude"],
        );
        let (status, out, err) = run(&root);
        assert_eq!(status, 1);
        assert_eq!(err, "");
        let expected = format!(
            "\n  AgentSync Doctor\n  {root}\n\n  Project layout\n    ✓ .ai/ directory present\n    ✓ AGENTS.md source file found\n    ✓ Project config: .ai/agent_sync.yaml\n    ! CLI version v0.36.0 differs from pinned v0.0.1 — run agentsync upgrade-config to align\n    ! Project format r1 is behind the engine r2 — run agentsync migrate to preview\n\n  Enabled tools\n    · No tools enabled — run agentsync enable <slug>\n\n  User overrides\n    · No customizations — all tools inherit fully from base\n\n  Source directories\n    ✓ .ai/src/AGENTS.md\n    ✓ .ai/src/rules\n    ✓ .ai/src/skills\n    · .ai/src/commands not present (optional)\n    · .ai/src/agents not present (optional)\n\n  Drift\n    ! CLAUDE.md — missing (deleted manually)\n\n    Re-run agentsync sync to overwrite, or move edits into .ai/src/ first.\n\n  Security\n    · No overrides to scan, or all clean.\n\n  Skills\n    ! skills/empty/ — missing SKILL.md (empty skill — populate or remove)\n    · Tip: agentsync simplify can prune empty skill dirs.\n\n  Rules\n    ✓ No always-on rules (every rule is paths:-scoped)\n\n  Tool outputs\n    ! .claude/ — orphan (tool 'claude' not enabled; output left from prior run)\n\n  Cross-project\n    · No parent .ai/src/ found within git boundary.\n\n  OK with 3 warning(s), 2 advisory(ies)\n\n"
        );
        assert_eq!(out, expected);
    }

    #[test]
    fn a_missing_ai_directory_exits_2_like_cmd_doctor() {
        let (_dir, root) = project(&[], &[".git"]);
        let (status, out, err) = run(&root);
        assert_eq!(status, 2);
        assert_eq!(err, "");
        assert_eq!(
            out,
            format!(
                "\n  AgentSync Doctor\n  {root}\n\n  Project layout\n    ✗ .ai/ directory missing — run agentsync init\n\n"
            )
        );
    }
}
