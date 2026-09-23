//! `agentsync init`: `cmd_init` of `lib/helpers/init.sh`, which scaffolds
//! `.ai/` inside a backup transaction, adopts the tool config a project already
//! has, writes the CI gate, and runs the first sync.

use std::io::Write;
use std::path::Path;

use super::put;
use crate::config::project_config::{self, Selection};
use crate::output::prompts::Cancelled;
use crate::output::style::Style;
use crate::paths;
use crate::project::Project;
use crate::transaction::interrupt::{self, Interrupt};
use crate::{Error, config::catalog, transaction::backup, transaction::witness};

mod args;
mod discover;
mod report;
mod scaffold;

use args::{CONTENT_DEFAULT, CONTENT_VALID, merge_lists, normalize_csv, parse_args};
use discover::{backup_targets, detect_tools, existing_dest_files};
use report::plan;
use scaffold::{Failure, Scaffold, scaffold};

/// `prompt_multiselect`: title, options, preselected.
pub type Picker<'a> =
    &'a mut dyn FnMut(&str, &[String], &[String]) -> Result<Vec<String>, Cancelled>;

/// What `init` takes from the process and the terminal.
pub struct Env<'a> {
    pub version: &'a str,
    /// `$(pwd)`, spelled logically.
    pub cwd: String,
    pub config_path: Option<String>,
    pub backup_limit: Option<String>,
    pub backup_max_age: Option<String>,
    /// `is_tty`: stdin and stdout are both terminals.
    pub interactive: bool,
    /// `prompt_confirm`.
    pub confirm: &'a mut dyn FnMut(&str, bool) -> bool,
    pub multiselect: Picker<'a>,
    /// `bash "$system_dir/sync.sh"` for a root: its exit status.
    pub sync: &'a mut dyn FnMut(&str) -> u8,
}

pub(super) struct Run<'a, 'b> {
    pub(super) style: &'a Style,
    pub(super) env: &'a mut Env<'b>,
    pub(super) out: &'a mut dyn Write,
    pub(super) err: &'a mut dyn Write,
}

impl Run<'_, '_> {
    pub(super) fn say(&mut self, text: &str) -> Result<(), Error> {
        put(self.out, text.as_bytes())
    }

    pub(super) fn tell(&mut self, text: &str) -> Result<(), Error> {
        put(self.err, text.as_bytes())
    }
}

pub fn init(
    args: &[String],
    style: &Style,
    env: &mut Env,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut run = Run {
        style,
        env,
        out,
        err,
    };
    let options = match parse_args(args, &mut run)? {
        Ok(options) => options,
        Err(status) => return Ok(status),
    };

    if !matches!(options.outputs.as_str(), "committed" | "local") {
        run.tell(&format!(
            "{}: --outputs must be 'committed' or 'local' (got '{}')\n",
            style.red("Error"),
            options.outputs
        ))?;
        return Ok(1);
    }
    if !matches!(options.existing.as_str(), "adopt" | "replace") {
        run.tell(&format!(
            "{}: --existing must be 'adopt' or 'replace' (got '{}')\n",
            style.red("Error"),
            options.existing
        ))?;
        return Ok(1);
    }
    if !matches!(options.ci.as_str(), "" | "github") {
        run.tell(&format!(
            "{}: --ci only supports 'github' (got '{}')\n",
            style.red("Error"),
            options.ci
        ))?;
        return Ok(1);
    }

    let requested = options.target.clone().unwrap_or_else(|| ".".to_string());
    let target = if crate::paths::is_absolute(&requested) {
        paths::normalize(&requested)
    } else {
        paths::normalize(&format!("{}/{requested}", run.env.cwd))
    };
    if !Path::new(&target).is_dir() {
        run.tell(&format!(
            "{}: Directory not found: {requested}\n",
            style.red("Error")
        ))?;
        return Ok(1);
    }

    if let Some(project_root) = paths::ai_dir_enclosing_root(&target) {
        run.tell(&format!(
            "{}: Cannot init inside the .ai/ directory: {target}\nRun agentsync init from the project root (the parent of .ai/):\n  cd \"{project_root}\" && agentsync init\n",
            style.red("Error")
        ))?;
        return Ok(2);
    }

    let ai_dir = format!("{target}/.ai");

    let is_file = |path: &str| Path::new(path).is_file();
    let config = match project_config::select(&target, run.env.config_path.as_deref(), &is_file) {
        Selection::Found(path) => {
            let text = std::fs::read(&path).map_err(|e| Error::io(&path, e))?;
            Some((path, String::from_utf8_lossy(&text).into_owned()))
        }
        Selection::None => None,
        Selection::Missing(path) => {
            run.tell(&format!(
                "Error: {}\n",
                project_config::missing_message(&path)
            ))?;
            return Ok(1);
        }
    };
    let retention = match backup::configure(
        config
            .as_ref()
            .map(|(path, text)| (path.as_str(), text.as_str())),
        run.env.backup_limit.as_deref(),
        run.env.backup_max_age.as_deref(),
    ) {
        Ok(retention) => retention,
        Err(e) => {
            report_backup_error(&mut run, &e)?;
            return Ok(1);
        }
    };

    if Path::new(&ai_dir).join("src").is_dir() {
        run.say(&format!(
            "{}: .ai/src/ already exists in {target}\nSkipping init to avoid overwriting your content.\n\nRun {} to synchronize.\n",
            style.yellow("Warning"),
            style.cyan("agentsync sync")
        ))?;
        return Ok(0);
    }

    let mut content_list = normalize_csv(
        options
            .content
            .as_deref()
            .filter(|c| !c.is_empty())
            .unwrap_or(CONTENT_DEFAULT),
    );
    for token in &content_list {
        if !CONTENT_VALID.contains(&token.as_str()) {
            run.tell(&format!(
                "{}: Unknown --content section: {token}\nValid sections: agents rules skills commands subagents\n",
                style.red("Error")
            ))?;
            return Ok(1);
        }
    }

    let tools_from_flag = normalize_csv(options.tools.as_deref().unwrap_or(""));
    let tools_from_detect = if options.no_detect {
        Vec::new()
    } else {
        detect_tools(&target)
    };
    let mut tool_list = merge_lists(&tools_from_flag, &tools_from_detect);
    let mut detect_source = match (tools_from_flag.is_empty(), tools_from_detect.is_empty()) {
        (false, false) => "mixed",
        (false, true) => "flag",
        (true, false) => "detect",
        (true, true) => "none",
    };

    let mut outputs = options.outputs.clone();
    let mut existing_action = options.existing.clone();
    let mut ci = options.ci.clone();

    let interactive = run.env.interactive
        && !options.assume_yes
        && options.tools.is_none()
        && options.content.is_none()
        && !options.no_templates;

    if interactive {
        run.say(&format!(
            "\n{} — {}\n\n",
            style.bold("AgentSync init"),
            style.dim(&target)
        ))?;
        let available = catalog::base_tools();
        if !available.is_empty() {
            let title = if tool_list.is_empty() {
                format!("Tools to enable {}", style.dim("(none auto-detected):"))
            } else {
                format!(
                    "Tools to enable {}",
                    style.dim(&format!("(detected: {}):", tool_list.join(",")))
                )
            };
            match (run.env.multiselect)(&title, &available, &tool_list) {
                Ok(picked) => tool_list = picked,
                Err(Cancelled(_)) => {
                    run.tell(&format!("{}\n", style.yellow("Cancelled.")))?;
                    return Ok(130);
                }
            }
            detect_source = "interactive";
            run.say("\n")?;
        }
        let sections: Vec<String> = CONTENT_VALID.iter().map(|s| s.to_string()).collect();
        match (run.env.multiselect)("Content sections:", &sections, &content_list) {
            Ok(picked) => content_list = picked,
            Err(Cancelled(_)) => {
                run.tell(&format!("{}\n", style.yellow("Cancelled.")))?;
                return Ok(130);
            }
        }
        run.say("\n")?;
        run.say(&format!(
            "{}\n{}\n",
            style.dim("Generated files (CLAUDE.md, .claude/, .cursor/, …) can be committed, so"),
            style.dim("teammates get current rules from git pull and never run agentsync.")
        ))?;
        outputs = if (run.env.confirm)("Commit generated files?", true) {
            "committed".to_string()
        } else {
            "local".to_string()
        };
        run.say("\n")?;
    }

    let project = Project::at(&target)?;
    let existing = if tool_list.is_empty() {
        Vec::new()
    } else {
        existing_dest_files(&project, &target, &tool_list)?
    };

    if interactive && !existing.is_empty() {
        let mut text = format!(
            "{} {}\n",
            style.yellow(&format!(
                "Found {} existing tool config file(s)",
                existing.len()
            )),
            style.dim("— the first sync regenerates these paths:")
        );
        for line in existing.iter().take(10) {
            text.push_str(&format!("   {line}\n"));
        }
        if existing.len() > 10 {
            text.push_str(&format!(
                "   {}\n",
                style.dim(&format!("… and {} more", existing.len() - 10))
            ));
        }
        run.say(&text)?;
        existing_action = if (run.env.confirm)(
            "Copy them into .ai/src/ first, so sync reproduces them?",
            true,
        ) {
            "adopt".to_string()
        } else {
            "replace".to_string()
        };
        run.say("\n")?;
    }

    if interactive
        && ci.is_empty()
        && outputs == "committed"
        && Path::new(&target).join(".github").is_dir()
    {
        if (run.env.confirm)(
            "Add a GitHub Actions gate that runs 'agentsync check'?",
            true,
        ) {
            ci = "github".to_string();
        }
        run.say("\n")?;
    }

    run.say(&plan(
        style,
        &target,
        &tool_list,
        &content_list,
        detect_source,
        options.no_templates,
    ))?;

    if options.dry_run {
        run.say(&format!(
            "{}\n",
            style.dim("Dry run — nothing was written.")
        ))?;
        return Ok(0);
    }

    if interactive {
        if !(run.env.confirm)("Proceed?", true) {
            run.say(&format!("{}\n", style.yellow("Cancelled.")))?;
            return Ok(130);
        }
        run.say("\n")?;
    }

    run.say(&format!(
        "{} in {}\n\n",
        style.bold("Initializing AgentSync"),
        style.cyan(&target)
    ))?;

    let targets = backup_targets(&mut run, &project, &target, &tool_list)?;
    let backup_path = match backup::create(&target, "init", &targets, retention) {
        Ok(path) => path,
        Err(e) => {
            report_backup_error(&mut run, &e)?;
            run.tell(&format!(
                "{}: Could not back up init targets; no project files were changed.\n",
                style.red("Error")
            ))?;
            return Ok(1);
        }
    };
    let shown_backup = backup_path
        .strip_prefix(&format!("{target}/"))
        .unwrap_or(&backup_path)
        .to_string();

    let mut interrupt = Interrupt::arm();
    let scaffold = scaffold(
        &mut run,
        &mut interrupt,
        Scaffold {
            target: &target,
            ai_dir: &ai_dir,
            content: &content_list,
            tools: &tool_list,
            no_templates: options.no_templates,
            outputs: &outputs,
            adopt: existing_action == "adopt",
            existing: &existing,
            ci_github: ci == "github",
            detect_source,
            run_sync: options.run_sync,
            shown_backup: &shown_backup,
        },
    );
    let status = match scaffold {
        Ok(()) => 0,
        Err(failure) => {
            let status = match &failure {
                Failure::Io(e) => {
                    run.tell(&format!("{e}\n"))?;
                    1
                }
                Failure::Signal(sig) => interrupt::status(*sig),
            };
            run.tell(&format!(
                "{}: Init failed; restoring pre-init state...\n",
                style.yellow("Warning")
            ))?;
            match backup::restore(&target, &backup_path) {
                Ok(()) => {
                    if let Err(reason) = witness::seal(&target, &backup_path) {
                        run.tell(&format!(
                            "{}: Could not record the restored state ({reason}); rolling back backup {} cannot detect later changes.\n",
                            style.yellow("Warning"),
                            paths::leaf(&backup_path)
                        ))?;
                    }
                    run.tell(&format!("Restored pre-init state from {shown_backup}\n"))?;
                    prune(&mut run, &target, retention)?;
                }
                Err(e) => {
                    report_backup_error(&mut run, &e)?;
                    run.tell(&format!(
                        "{}: Automatic restore failed. Backup retained at {shown_backup}\n",
                        style.red("Error")
                    ))?;
                }
            }
            if let Failure::Signal(sig) = failure {
                interrupt.resend(sig);
            }
            return Ok(status);
        }
    };
    drop(interrupt);

    prune(&mut run, &target, retention)?;
    if let Err(reason) = witness::seal(&target, &backup_path) {
        run.tell(&format!(
            "{}: Could not record the post-init state ({reason}); rolling back backup {} cannot detect later changes.\n",
            style.yellow("Warning"),
            paths::leaf(&backup_path)
        ))?;
    }

    if options.run_sync && !tool_list.is_empty() {
        run.say(&format!("{}\n\n", style.bold("Running the first sync")))?;
        if (run.env.sync)(&target) != 0 {
            run.tell(&format!(
                "{}: first sync failed — fix the cause and run {}.\n",
                style.yellow("Warning"),
                style.cyan("agentsync sync")
            ))?;
            return Ok(0);
        }
        if outputs == "committed" {
            run.say(&format!(
                "{} {}\n\n",
                style.bold("Commit .ai/ and the generated files"),
                style.dim("— teammates then need only git pull.")
            ))?;
        }
    }
    Ok(status)
}

fn prune(run: &mut Run, target: &str, retention: backup::Retention) -> Result<(), Error> {
    let (limit, max_age) = (run.env.backup_limit.clone(), run.env.backup_max_age.clone());
    if let Err(e) = backup::prune(target, limit.as_deref(), max_age.as_deref(), retention) {
        report_backup_error(run, &e)?;
        let style = run.style;
        run.tell(&format!(
            "{}: Could not prune old AgentSync backups.\n",
            style.yellow("Warning")
        ))?;
    }
    Ok(())
}

/// `_backup_error`: `Error: <message>` on stderr, plain.
fn report_backup_error(run: &mut Run, error: &Error) -> Result<(), Error> {
    match error {
        Error::Backup(message) => run.tell(&format!("Error: {message}\n")),
        other => run.tell(&format!("{other}\n")),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::collections::VecDeque;
    use std::path::PathBuf;

    use super::*;
    use crate::cli::files_below;
    use crate::config::template_manifest::REL;
    use crate::paths::DiskText;

    pub(super) fn project(files: &[(&str, &str)]) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        for (rel, text) in files {
            let path = Path::new(&root).join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        (dir, root)
    }

    pub(super) struct Outcome {
        pub(super) status: u8,
        pub(super) out: String,
        pub(super) err: String,
        pub(super) synced: Vec<String>,
        pub(super) asked: Vec<String>,
        pub(super) picked: Vec<String>,
    }

    pub(super) struct Script {
        interactive: bool,
        confirms: Vec<bool>,
        picks: Vec<Result<Vec<String>, Cancelled>>,
        sync_status: u8,
    }

    pub(super) fn quiet() -> Script {
        Script {
            interactive: false,
            confirms: Vec::new(),
            picks: Vec::new(),
            sync_status: 0,
        }
    }

    fn strings(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    pub(super) fn call(cwd: &str, args: &[&str], script: Script) -> Outcome {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let mut synced = Vec::new();
        let mut asked = Vec::new();
        let mut picked = Vec::new();
        let mut confirms: VecDeque<bool> = script.confirms.into_iter().collect();
        let mut picks: VecDeque<Result<Vec<String>, Cancelled>> =
            script.picks.into_iter().collect();
        let status_code = script.sync_status;
        let mut confirm = |question: &str, _default: bool| {
            asked.push(question.to_string());
            confirms.pop_front().unwrap_or(true)
        };
        let mut multiselect = |title: &str, _options: &[String], preselected: &[String]| {
            picked.push(title.to_string());
            picks
                .pop_front()
                .unwrap_or_else(|| Ok(preselected.to_vec()))
        };
        let mut sync = |root: &str| {
            synced.push(root.to_string());
            status_code
        };
        let mut env = Env {
            version: "9.9.9",
            cwd: cwd.to_string(),
            config_path: None,
            backup_limit: None,
            backup_max_age: None,
            interactive: script.interactive,
            confirm: &mut confirm,
            multiselect: &mut multiselect,
            sync: &mut sync,
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = init(&args, &Style::plain(), &mut env, &mut out, &mut err).unwrap();
        Outcome {
            status,
            out: String::from_utf8(out).unwrap(),
            err: String::from_utf8(err).unwrap(),
            synced,
            asked,
            picked,
        }
    }

    pub(super) fn tree(root: &str) -> Vec<String> {
        let mut files = Vec::new();
        files_below(Path::new(root), &mut files);
        let mut rels: Vec<String> = files
            .iter()
            .map(|f| f.strip_prefix(root).unwrap().disk_text())
            .filter(|rel| !rel.starts_with(".ai/backups/"))
            .collect();
        rels.sort();
        rels
    }

    pub(super) fn backups(root: &str) -> Vec<PathBuf> {
        let mut found: Vec<PathBuf> = std::fs::read_dir(Path::new(root).join(".ai/backups"))
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.is_dir())
                    .collect()
            })
            .unwrap_or_default();
        found.sort();
        found
    }

    const PLAN_NONE: &str = "Plan:\n  Target:   {root}/.ai/\n  Content:  agents, rules, skills, commands, subagents\n  Tools:    (none — opt in later via 'agentsync enable')\n\n";
    const SUMMARY_FULL: &str = "\n   Created .ai/agent_sync.yaml     — project config (outputs: committed — teammates need only git pull)\n   Created .ai/src/AGENTS.md      — agent identity\n   Created .ai/src/rules/          — 3 rule(s)\n   Created .ai/src/skills/         — 7 skill(s)\n   Created .ai/src/commands/       — 2 command(s)\n   Created .ai/src/agents/         — 1 subagent(s)\n";
    const NEXT_NO_TOOLS: &str = "\n   No tools enabled. Run 'agentsync enable <slug>' to opt in.\n\nDone!\n\nNext steps:\n  1. Edit .ai/src/AGENTS.md — customize your agent's identity\n  2. Run agentsync generate    — print an AI prompt to tailor .ai/src/ to your codebase\n  3. Run agentsync list        — browse all available tools\n  4. Run agentsync enable <slug> — opt in to tools you use\n  5. Run agentsync sync        — distribute to enabled tools\n\nCustomize:\n  • agentsync add mcp <server>            — configure shared MCP servers\n  • agentsync customize <tool> <resource> — override settings/hooks per tool\n\n";

    pub(super) fn backup_line(root: &str) -> String {
        let snapshot = backups(root).pop().expect("one snapshot");
        format!(
            "Backup: .ai/backups/{}\n\n",
            snapshot.file_name().unwrap().disk_text()
        )
    }

    #[test]
    fn a_plain_init_scaffolds_backs_up_and_skips_a_second_run_like_bash() {
        let (_dir, root) = project(&[]);
        let run = call(&root, &["--no-detect"], quiet());
        assert_eq!(run.status, 0);
        assert_eq!(run.err, "");
        assert_eq!(
            run.out,
            format!(
                "{}Initializing AgentSync in {root}\n\n{SUMMARY_FULL}{NEXT_NO_TOOLS}{}",
                PLAN_NONE.replace("{root}", &root),
                backup_line(&root)
            )
        );
        assert!(run.synced.is_empty());
        let files = tree(&root);
        assert_eq!(files.len(), 21);
        assert!(files.contains(&".ai/.template-manifest".to_string()));
        assert!(files.contains(&".ai/src/skills/humanizer/scripts/strip-ai-chars.sh".to_string()));
        assert!(!Path::new(&root).join(".ai/src/tools").exists());
        let config = std::fs::read_to_string(Path::new(&root).join(".ai/agent_sync.yaml")).unwrap();
        assert!(config.starts_with("# AgentSync — Project Configuration\n# All keys are optional — remove any that you leave at the default.\n\nagentsync_version: \"9.9.9\"\nformat: 2\n\n# Tools:"));
        assert!(config.contains("\ntools:\n  enabled: []\n\n# Source paths"));
        assert!(config.ends_with("outputs: committed\n\n# .gitignore management (false leaves the managed block untouched).\ngitignore:\n  update: true\n"));
        assert_eq!(
            std::fs::read_to_string(Path::new(&root).join(REL))
                .unwrap()
                .lines()
                .count(),
            19
        );
        let snapshot = backups(&root).pop().unwrap();
        assert_eq!(
            std::fs::read_to_string(snapshot.join("targets.tsv")).unwrap(),
            "missing\t.ai/src\nmissing\t.ai/agent_sync.yaml\nmissing\t.ai/.template-manifest\n"
        );
        assert!(snapshot.join("after.tsv").is_file());
        assert!(
            std::fs::read_to_string(snapshot.join("metadata"))
                .unwrap()
                .contains("operation=init\n")
        );

        let again = call(&root, &["--tools", "claude", "--no-sync"], quiet());
        assert_eq!(
            (again.status, again.out),
            (
                0,
                format!(
                    "Warning: .ai/src/ already exists in {root}\nSkipping init to avoid overwriting your content.\n\nRun agentsync sync to synchronize.\n"
                )
            )
        );
    }

    #[test]
    fn the_first_sync_runs_for_enabled_tools_and_reports_committed_mode() {
        let (_dir, root) = project(&[]);
        let run = call(&root, &["--tools", "claude"], quiet());
        assert_eq!(run.synced, std::slice::from_ref(&root));
        assert!(
            run.out
                .contains("  5. Re-run agentsync sync     — after every change to .ai/src/\n")
        );
        assert!(run.out.ends_with(&format!("{}Running the first sync\n\nCommit .ai/ and the generated files — teammates then need only git pull.\n\n", backup_line(&root))));

        let (_dir, root) = project(&[]);
        let local = call(&root, &["--tools", "claude", "--outputs", "local"], quiet());
        assert!(local.out.ends_with("Running the first sync\n\n"));

        let (_dir, root) = project(&[]);
        let failed = call(
            &root,
            &["--tools", "claude"],
            Script {
                sync_status: 1,
                ..quiet()
            },
        );
        assert_eq!(
            (failed.status, failed.err.as_str()),
            (
                0,
                "Warning: first sync failed — fix the cause and run agentsync sync.\n"
            )
        );
        assert!(failed.out.ends_with("Running the first sync\n\n"));

        let (_dir, root) = project(&[]);
        let none = call(&root, &["--no-detect"], quiet());
        assert!(none.synced.is_empty());
        let (_dir, root) = project(&[]);
        let skipped = call(&root, &["--tools", "claude", "--no-sync"], quiet());
        assert!(skipped.synced.is_empty());
        assert!(
            skipped
                .out
                .contains("  5. Run agentsync sync        — distribute to enabled tools\n")
        );
    }

    #[test]
    fn a_scaffold_failure_restores_the_snapshot_like_bash() {
        let (_dir, root) = project(&[(".ai/agent_sync.yaml/sentinel", "keep\n")]);
        let run = call(&root, &["--no-detect"], quiet());
        assert_eq!(run.status, 1);
        assert_eq!(
            run.out,
            format!(
                "{}Initializing AgentSync in {root}\n\n",
                PLAN_NONE.replace("{root}", &root)
            )
        );
        let snapshot = backups(&root).pop().unwrap();
        assert_eq!(
            run.err,
            format!(
                "{root}/.ai/agent_sync.yaml: Is a directory (os error 21)\nWarning: Init failed; restoring pre-init state...\nRestored pre-init state from .ai/backups/{}\n",
                snapshot.file_name().unwrap().disk_text()
            )
        );
        assert_eq!(tree(&root), [".ai/agent_sync.yaml/sentinel"]);
        assert!(snapshot.join("after.tsv").is_file());
    }

    #[test]
    fn preexisting_configs_are_kept_and_validated_like_bash() {
        let (_dir, root) =
            project(&[(".ai/agent_sync.yaml", "tools:\n  enabled:\n    - claude\n")]);
        let run = call(&root, &["--no-detect", "--no-sync"], quiet());
        assert_eq!(run.status, 0);
        assert_eq!(
            std::fs::read_to_string(Path::new(&root).join(".ai/agent_sync.yaml")).unwrap(),
            "tools:\n  enabled:\n    - claude\n"
        );

        let (_dir, root) = project(&[("agent_sync.yaml", "tools:\n  enabled: []\n")]);
        let root_config = call(&root, &["--no-detect", "--no-sync"], quiet());
        assert_eq!(root_config.status, 0);
        assert!(!Path::new(&root).join(".ai/agent_sync.yaml").exists());

        let (_dir, root) = project(&[(".ai/agent_sync.yaml", "backup:\n  retention: typo\n")]);
        let typo = call(&root, &["--no-detect"], quiet());
        assert_eq!(
            (typo.status, typo.err),
            (
                1,
                format!(
                    "Error: Invalid backup.retention 'typo' in {root}/.ai/agent_sync.yaml; expected bounded or preserve\n"
                )
            )
        );
        assert!(!Path::new(&root).join(".ai/src").exists());
    }

    #[test]
    fn the_wizard_picks_tools_content_outputs_existing_and_ci_like_bash() {
        let (_dir, root) = project(&[
            (".github/x", ""),
            ("CLAUDE.md", "# Hand-written\n"),
            (".claude/rules/legacy.md", "# Legacy\n"),
        ]);
        let run = call(
            &root,
            &["--no-sync"],
            Script {
                interactive: true,
                confirms: vec![false, true, true, true],
                picks: vec![
                    Ok(strings(&["claude", "cursor"])),
                    Ok(strings(&["agents", "rules"])),
                ],
                sync_status: 0,
            },
        );
        assert_eq!(run.status, 0);
        assert_eq!(
            run.picked,
            ["Tools to enable (detected: claude):", "Content sections:"]
        );
        assert_eq!(
            run.asked,
            [
                "Commit generated files?",
                "Copy them into .ai/src/ first, so sync reproduces them?",
                "Proceed?"
            ]
        );
        assert!(run.out.starts_with(&format!(
            "\nAgentSync init — {root}\n\n\n\nGenerated files (CLAUDE.md, .claude/, .cursor/, …) can be committed, so\nteammates get current rules from git pull and never run agentsync.\n\nFound 2 existing tool config file(s) — the first sync regenerates these paths:\n   .claude/rules/legacy.md\n   CLAUDE.md\n\nPlan:\n  Target:   {root}/.ai/\n  Content:  agents, rules\n  Tools:    claude, cursor (interactive)\n  settings: claude.json\n  hooks:    cursor.json\n\n\nInitializing AgentSync in {root}\n\n\n   Adopted .claude/rules/legacy.md → .ai/src/rules/legacy.md\n   Adopted CLAUDE.md → .ai/src/AGENTS.md\n\n"
        )));
        assert!(
            run.out
                .contains("(outputs: local — every clone runs agentsync sync)")
        );
        assert!(
            run.out
                .contains("   Enabled 2 tool(s): claude, cursor (selected)\n")
        );
        assert!(!Path::new(&root).join(".github/workflows").exists());

        let (_dir, root) = project(&[(".github/x", "")]);
        let ci = call(
            &root,
            &["--no-sync"],
            Script {
                interactive: true,
                confirms: vec![true, true, true],
                picks: vec![Ok(strings(&["claude"])), Ok(strings(&["rules"]))],
                sync_status: 0,
            },
        );
        assert_eq!(
            ci.asked,
            [
                "Commit generated files?",
                "Add a GitHub Actions gate that runs 'agentsync check'?",
                "Proceed?"
            ]
        );
        assert!(ci.out.contains("\n\n\nPlan:\n"));
        assert!(
            Path::new(&root)
                .join(".github/workflows/agentsync-check.yml")
                .is_file()
        );

        let (_dir, root) = project(&[]);
        let declined = call(
            &root,
            &[],
            Script {
                interactive: true,
                confirms: vec![true, false],
                picks: Vec::new(),
                sync_status: 0,
            },
        );
        assert_eq!(declined.status, 130);
        assert!(declined.out.ends_with(&format!(
            "{}Cancelled.\n",
            PLAN_NONE.replace("{root}", &root)
        )));
        assert_eq!(
            declined.picked,
            ["Tools to enable (none auto-detected):", "Content sections:"]
        );
        assert!(!Path::new(&root).join(".ai").exists());

        let cancelled = call(
            &root,
            &[],
            Script {
                interactive: true,
                confirms: Vec::new(),
                picks: vec![Err(Cancelled(Vec::new()))],
                sync_status: 0,
            },
        );
        assert_eq!(
            (cancelled.status, cancelled.err.as_str()),
            (130, "Cancelled.\n")
        );
        assert_eq!(cancelled.out, format!("\nAgentSync init — {root}\n\n"));

        let dry = call(
            &root,
            &["--dry-run"],
            Script {
                interactive: true,
                confirms: vec![true],
                picks: vec![Ok(Vec::new()), Ok(strings(&["rules"]))],
                sync_status: 0,
            },
        );
        assert_eq!(dry.status, 0);
        assert!(dry.out.ends_with("  Content:  rules\n  Tools:    (none — opt in later via 'agentsync enable')\n\nDry run — nothing was written.\n"));
        assert_eq!(dry.asked, ["Commit generated files?"]);

        let flagged = call(
            &root,
            &["--yes"],
            Script {
                interactive: true,
                confirms: Vec::new(),
                picks: Vec::new(),
                sync_status: 0,
            },
        );
        assert!(flagged.picked.is_empty());
        assert!(flagged.asked.is_empty());
        assert_eq!(flagged.status, 0);
    }
}
