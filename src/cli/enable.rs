//! `agentsync enable` and `agentsync disable`: `cmd_enable` and `cmd_disable`
//! of `lib/helpers/enable.sh`, editing `tools.enabled` with `yaml_edit`.

use crate::paths::DiskText;
use std::io::Write;
use std::path::{Path, PathBuf};

use super::put;
use crate::config::tool::Tool;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths;
use crate::project::Project;
use crate::{Error, config::catalog, config::edit_paths, config::payload, config::yaml_edit};

pub const ENABLE_HELP: Help = Help {
    command: "enable",
    tagline: "add tools to tools.enabled in agent_sync.yaml",
    synopsis: &["enable <slug> [<slug>...] [--no-scaffold|--scaffold] [--yes]"],
    description: &[
        "Add one or more tools to the tools.enabled list in agent_sync.yaml.\nAfter enabling, run agentsync sync to write that tool's outputs.",
        "Run agentsync list to see available tool slugs.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "--scaffold",
                "Always scaffold payload files (settings/hooks/mcp)",
            ),
            ("--no-scaffold", "Never scaffold; skip the payload prompt"),
            (
                "-y, --yes",
                "Accept any prompts (e.g. project-config creation)",
            ),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &[
        "enable claude",
        "enable claude cursor --no-scaffold",
        "enable codex --scaffold --yes",
    ],
};

pub const DISABLE_HELP: Help = Help {
    command: "disable",
    tagline: "remove tools from tools.enabled in agent_sync.yaml",
    synopsis: &["disable <slug> [<slug>...]"],
    description: &[
        "Remove one or more tools from the tools.enabled list in agent_sync.yaml.\nA per-tool override with enabled: true is set to false as well. After\ndisabling, run agentsync sync to clean up that tool's outputs.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[("-h, --help", "Show this help")],
    }],
    examples: &["disable cursor", "disable claude cursor"],
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scaffold {
    Auto,
    Always,
    Never,
}

/// `_enable_resolve_or_create_config`.
fn resolve_or_create_config(root: &Path) -> Result<PathBuf, Error> {
    let config = root.join(".ai").join("agent_sync.yaml");
    if config.is_file() {
        return Ok(config);
    }
    let legacy = root.join("agent_sync.yaml");
    if legacy.is_file() {
        return Ok(legacy);
    }
    let ai = root.join(".ai");
    std::fs::create_dir_all(&ai).map_err(|e| Error::io(&ai, e))?;
    std::fs::write(
        &config,
        "# AgentSync — Project Configuration\ntools:\n  enabled: []\n",
    )
    .map_err(|e| Error::io(&config, e))?;
    Ok(config)
}

fn tool_exists(project: &Project, slug: &str) -> Result<bool, Error> {
    Ok(catalog::base_tools().iter().any(|t| t == slug)
        || project.user_override_tools()?.iter().any(|t| t == slug))
}

/// The settings and hooks copies `_enable_scaffold_tool_dir` would write.
fn scaffoldable(project: &Project, tool: &Tool) -> Vec<(PathBuf, &'static [u8])> {
    let mut work = Vec::new();
    for resource in ["settings", "hooks"] {
        let (Some(base), Some(user)) = (
            tool.base_payload(resource),
            payload::override_path(project, tool, resource),
        ) else {
            continue;
        };
        if user.is_file()
            || payload::legacy_override_path(project, tool, resource).is_some_and(|p| p.is_file())
        {
            continue;
        }
        work.push((user, base.contents()));
    }
    work
}

pub fn enable(
    args: &[String],
    discover: &dyn Fn() -> Result<Project, Error>,
    style: &Style,
    interactive: bool,
    confirm: &mut dyn FnMut(&str) -> bool,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut scaffold = Scaffold::Auto;
    let mut yes = false;
    let mut tools: Vec<String> = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--scaffold" => scaffold = Scaffold::Always,
            "--no-scaffold" => scaffold = Scaffold::Never,
            "--yes" | "-y" => yes = true,
            "--help" | "-h" => {
                put(out, ENABLE_HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            "--" => tools.extend(rest.by_ref().cloned()),
            flag if flag.starts_with('-') => {
                put(
                    err,
                    format!(
                        "{}: Unknown flag: {flag}\nUsage: {}\n",
                        style.red("Error"),
                        ENABLE_HELP.synopsis_line()
                    )
                    .as_bytes(),
                )?;
                return Ok(1);
            }
            slug => tools.push(slug.to_string()),
        }
    }
    if tools.is_empty() {
        put(
            err,
            format!(
                "{}: {}\n\nRun {} to see available tools.\n",
                style.red("Error"),
                ENABLE_HELP.synopsis_line(),
                style.cyan("agentsync list")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }

    let project = discover()?;
    if !project.tools_dir_in_project() {
        if scaffold == Scaffold::Always {
            return super::refuse_outside_tools_dir(&project, style, err);
        }
        scaffold = Scaffold::Never;
    }
    let config = resolve_or_create_config(&project.root)?;

    let (mut already, mut unknown, mut added) = (0usize, Vec::new(), Vec::new());
    for slug in &tools {
        if !tool_exists(&project, slug)? {
            unknown.push(slug.clone());
        } else if project.enabled_tools()?.contains(slug) {
            already += 1;
        } else {
            yaml_edit::list_append(&config, "tools.enabled", slug)?;
            added.push(slug.clone());
        }
    }

    if !added.is_empty() {
        put(
            out,
            format!(
                "\n{}\n",
                style.green(&format!("Enabled {} tool(s)", added.len()))
            )
            .as_bytes(),
        )?;
        for slug in &added {
            let tool = Tool::load(&project, slug)?;
            put(
                out,
                format!(
                    "    {} {} {}\n",
                    style.green("●"),
                    tool.display_name(),
                    style.dim(&format!("({slug})"))
                )
                .as_bytes(),
            )?;
        }
    }
    if already > 0 {
        put(
            out,
            format!(
                "\n{}\n",
                style.dim(&format!("{already} tool(s) were already enabled"))
            )
            .as_bytes(),
        )?;
    }
    if !unknown.is_empty() {
        put(
            out,
            format!("\n{}\n", style.yellow("Unknown tool(s):")).as_bytes(),
        )?;
        for slug in &unknown {
            put(out, format!("    {slug}\n").as_bytes())?;
        }
        put(
            out,
            format!(
                "\nRun {} to see available tool slugs.\n",
                style.cyan("agentsync list")
            )
            .as_bytes(),
        )?;
    }
    let status = if unknown.is_empty() { 0 } else { 1 };
    if added.is_empty() {
        return Ok(status);
    }
    for slug in &added {
        let tool = Tool::load(&project, slug)?;
        let work = scaffoldable(&project, &tool);
        let write = match scaffold {
            Scaffold::Always => true,
            Scaffold::Never => false,
            Scaffold::Auto if work.is_empty() => false,
            Scaffold::Auto if interactive && !yes => confirm(&format!(
                "Scaffold editable copies for {}?",
                tool.display_name()
            )),
            Scaffold::Auto => true,
        };
        if write {
            for (path, bytes) in &work {
                let dir = paths::parent(&path.disk_text());
                std::fs::create_dir_all(&dir).map_err(|e| Error::io(&dir, e))?;
                std::fs::write(path, bytes).map_err(|e| Error::io(path, e))?;
            }
        }
        put(out, edit_paths::block(&project, &tool, style).as_bytes())?;
    }
    put(
        out,
        format!("\nRun {} to apply.\n\n", style.cyan("agentsync sync")).as_bytes(),
    )?;
    Ok(status)
}

pub fn disable(
    args: &[String],
    discover: &dyn Fn() -> Result<Project, Error>,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        put(out, DISABLE_HELP.render(style).as_bytes())?;
        return Ok(0);
    }
    if args.is_empty() {
        put(
            err,
            format!("{}: {}\n", style.red("Error"), DISABLE_HELP.synopsis_line()).as_bytes(),
        )?;
        return Ok(1);
    }
    let project = discover()?;
    if !project.tools_dir_in_project() {
        for slug in args {
            if Tool::load(&project, slug)?.user_value("enabled") == "true" {
                return super::refuse_outside_tools_dir(&project, style, err);
            }
        }
    }
    let config = resolve_or_create_config(&project.root)?;

    let (mut removed, mut not_enabled) = (0usize, 0usize);
    for slug in args {
        if !project.enabled_tools()?.contains(slug) {
            not_enabled += 1;
            continue;
        }
        yaml_edit::list_remove(&config, "tools.enabled", slug)?;
        let user_file = project.user_tool_file(slug);
        if user_file.is_file() && Tool::load(&project, slug)?.user_value("enabled") == "true" {
            yaml_edit::set_scalar(&user_file, "enabled", "false")?;
        }
        removed += 1;
    }

    put(out, b"\n")?;
    if removed > 0 {
        put(
            out,
            format!("{}\n", style.yellow(&format!("Disabled {removed} tool(s)"))).as_bytes(),
        )?;
        let enabled = project.enabled_tools()?;
        for slug in args {
            if !enabled.contains(slug) {
                put(
                    out,
                    format!(
                        "    {} {} {}\n",
                        style.dim("○"),
                        Tool::load(&project, slug)?.display_name(),
                        style.dim(&format!("({slug})"))
                    )
                    .as_bytes(),
                )?;
            }
        }
        put(
            out,
            format!("\nRun {} to apply cleanup.\n", style.cyan("agentsync sync")).as_bytes(),
        )?;
    }
    if not_enabled > 0 && removed == 0 {
        put(
            out,
            format!("{}\n", style.dim("No matching tools were enabled.")).as_bytes(),
        )?;
    }
    put(out, b"\n")?;
    Ok(0)
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    struct Run {
        status: u8,
        out: String,
        err: String,
    }

    fn project() -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        std::fs::create_dir_all(root.join(".ai")).unwrap();
        std::fs::write(
            root.join(".ai/agent_sync.yaml"),
            "tools:\n  enabled:\n    - cursor\n",
        )
        .unwrap();
        (dir, root)
    }

    fn call(root: &std::path::Path, command: &str, args: &[&str]) -> Run {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let discover = || Project::at(root);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = if command == "enable" {
            enable(
                &args,
                &discover,
                &Style::plain(),
                false,
                &mut |_| true,
                &mut out,
                &mut err,
            )
        } else {
            disable(&args, &discover, &Style::plain(), &mut out, &mut err)
        }
        .unwrap();
        Run {
            status,
            out: String::from_utf8(out).unwrap(),
            err: String::from_utf8(err).unwrap(),
        }
    }

    #[test]
    fn enable_appends_scaffolds_and_reports_like_cmd_enable() {
        let (_dir, root) = project();
        let run = call(&root, "enable", &["claude", "cursor", "nope"]);
        assert_eq!(run.status, 1);
        assert_eq!(run.err, "");
        assert_eq!(
            run.out,
            "\nEnabled 1 tool(s)\n    ● Claude Code (claude)\n\n1 tool(s) were already enabled\n\nUnknown tool(s):\n    nope\n\nRun agentsync list to see available tool slugs.\n\n  Claude Code\n    Edit settings: .ai/src/tools/claude/settings.json\n    MCP:           agentsync add mcp <server>  (shared — not yet configured)\n\nRun agentsync sync to apply.\n\n"
        );
        assert_eq!(
            std::fs::read_to_string(root.join(".ai/agent_sync.yaml")).unwrap(),
            "tools:\n  enabled:\n    - cursor\n    - claude\n"
        );
        assert!(root.join(".ai/src/tools/claude/settings.json").is_file());

        let usage = call(&root, "enable", &[]);
        assert_eq!(usage.status, 1);
        assert_eq!(
            usage.err,
            "Error: agentsync enable <slug> [<slug>...] [--no-scaffold|--scaffold] [--yes]\n\nRun agentsync list to see available tools.\n"
        );
        let flag = call(&root, "enable", &["claude", "--bogus"]);
        assert_eq!(flag.status, 1);
        assert_eq!(
            flag.err,
            "Error: Unknown flag: --bogus\nUsage: agentsync enable <slug> [<slug>...] [--no-scaffold|--scaffold] [--yes]\n"
        );
    }

    #[test]
    fn disable_removes_flips_legacy_flags_and_lists_what_is_off() {
        let (_dir, root) = project();
        std::fs::create_dir_all(root.join(".ai/src/tools")).unwrap();
        std::fs::write(root.join(".ai/src/tools/kimi.yaml"), "enabled: true\n").unwrap();
        let run = call(&root, "disable", &["cursor", "kimi", "nope"]);
        assert_eq!(run.status, 0);
        assert_eq!(
            run.out,
            "\nDisabled 2 tool(s)\n    ○ Cursor (cursor)\n    ○ Kimi Code (kimi)\n    ○ nope (nope)\n\nRun agentsync sync to apply cleanup.\n\n"
        );
        assert_eq!(
            std::fs::read_to_string(root.join(".ai/src/tools/kimi.yaml")).unwrap(),
            "enabled: false\n"
        );
        assert_eq!(
            call(&root, "disable", &["cursor"]).out,
            "\nNo matching tools were enabled.\n\n"
        );
        assert_eq!(
            call(&root, "disable", &[]).err,
            "Error: agentsync disable <slug> [<slug>...]\n"
        );
    }

    #[test]
    fn enable_and_disable_help_render_in_the_shared_shape() {
        let (_dir, root) = project();
        let enable = call(&root, "enable", &["--help"]);
        assert_eq!((enable.status, enable.err.as_str()), (0, ""));
        assert_eq!(
            enable.out,
            "\n  agentsync enable — add tools to tools.enabled in agent_sync.yaml\n\n  USAGE\n    agentsync enable <slug> [<slug>...] [--no-scaffold|--scaffold] [--yes]\n\n  DESCRIPTION\n    Add one or more tools to the tools.enabled list in agent_sync.yaml.\n    After enabling, run agentsync sync to write that tool's outputs.\n\n    Run agentsync list to see available tool slugs.\n\n  OPTIONS\n    --scaffold      Always scaffold payload files (settings/hooks/mcp)\n    --no-scaffold   Never scaffold; skip the payload prompt\n    -y, --yes       Accept any prompts (e.g. project-config creation)\n    -h, --help      Show this help\n\n  EXAMPLES\n    agentsync enable claude\n    agentsync enable claude cursor --no-scaffold\n    agentsync enable codex --scaffold --yes\n\n"
        );

        let disable = call(&root, "disable", &["cursor", "-h"]);
        assert_eq!((disable.status, disable.err.as_str()), (0, ""));
        assert_eq!(
            disable.out,
            "\n  agentsync disable — remove tools from tools.enabled in agent_sync.yaml\n\n  USAGE\n    agentsync disable <slug> [<slug>...]\n\n  DESCRIPTION\n    Remove one or more tools from the tools.enabled list in agent_sync.yaml.\n    A per-tool override with enabled: true is set to false as well. After\n    disabling, run agentsync sync to clean up that tool's outputs.\n\n  OPTIONS\n    -h, --help   Show this help\n\n  EXAMPLES\n    agentsync disable cursor\n    agentsync disable claude cursor\n\n"
        );
        assert_eq!(
            std::fs::read_to_string(root.join(".ai/agent_sync.yaml")).unwrap(),
            "tools:\n  enabled:\n    - cursor\n"
        );
    }
}
