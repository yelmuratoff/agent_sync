//! `agentsync show`: `cmd_show` and `_show_payload` of `lib/helpers/customize.sh`.

use crate::paths::DiskText;
use std::io::Write;

use super::customize::{VALID_RESOURCES, unknown_resource};
use super::put;
use crate::config::payload::{self, Source};
use crate::config::tool::Tool;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths::ENGINE_ROOT;
use crate::project::Project;
use crate::{Error, config::catalog, config::yaml_subset, text};

pub const HELP: Help = Help {
    command: "show",
    tagline: "show effective config for a tool",
    synopsis: &["show <slug> [<resource>] [--base]"],
    description: &[
        "Print effective configuration for a tool. Each line is marked \"base\"\n(inherited from the shipped template) or \"user\" (overridden in\n.ai/src/tools/<slug>.yaml).",
    ],
    sections: &[
        Section {
            title: "ARGUMENTS",
            entries: &[
                ("<slug>", "Tool to show"),
                (
                    "<resource>",
                    "Payload resource: tool, hooks, mcp, settings\n(default: tool, the YAML config)",
                ),
            ],
        },
        Section {
            title: "OPTIONS",
            entries: &[
                (
                    "--base",
                    "Print the base template only, ignoring user overrides",
                ),
                ("-h, --help", "Show this help"),
            ],
        },
    ],
    examples: &["show cursor", "show cursor --base", "show claude hooks"],
};

const KEYS: [&str; 30] = [
    "name",
    "enabled",
    "targets.agents.dest",
    "targets.agents.source",
    "targets.rules.dest",
    "targets.rules.source",
    "targets.rules.extension",
    "targets.rules.header",
    "targets.rules.scoped_header",
    "targets.rules.append_imports",
    "targets.rules.merge_to_file",
    "targets.rules.inline_into_agents",
    "targets.rules.prepend_agents",
    "targets.skills.dest",
    "targets.skills.inline_into_agents",
    "targets.commands.dest",
    "targets.commands.format",
    "targets.commands.extension",
    "targets.commands.as_skills",
    "targets.commands.inline_into_agents",
    "targets.subagents.dest",
    "targets.subagents.format",
    "targets.subagents.extension",
    "targets.settings.source",
    "targets.settings.dest",
    "targets.mcp.source",
    "targets.mcp.dest",
    "targets.hooks.source",
    "targets.hooks.dest",
    "post_sync",
];

pub(crate) fn base_tool_shown(slug: &str) -> String {
    format!("{ENGINE_ROOT}/lib/templates/tools/{slug}.yaml")
}

pub(crate) fn read_text(path: &std::path::Path) -> Result<Option<String>, Error> {
    if !path.is_file() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|e| Error::io(path, e))?;
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

pub fn show(
    args: &[String],
    discover: &dyn Fn() -> Result<Project, Error>,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut show_base = false;
    let (mut slug, mut resource) = (String::new(), String::new());
    for arg in args {
        match arg.as_str() {
            "--base" => show_base = true,
            "--help" | "-h" => {
                put(out, HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            flag if flag.starts_with('-') => {
                put(
                    err,
                    format!("{}: Unknown flag: {flag}\n", style.red("Error")).as_bytes(),
                )?;
                return Ok(1);
            }
            value if slug.is_empty() => slug = value.to_string(),
            value if resource.is_empty() => resource = value.to_string(),
            _ => {
                put(
                    err,
                    format!("{}: Too many arguments.\n", style.red("Error")).as_bytes(),
                )?;
                return Ok(1);
            }
        }
    }
    if slug.is_empty() {
        put(
            err,
            format!(
                "{}: {}\n  <resource>: {} (default: tool)\n",
                style.red("Error"),
                HELP.synopsis_line(),
                VALID_RESOURCES.join(" ")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let resource = if resource.is_empty() {
        "tool".to_string()
    } else {
        resource
    };
    if !VALID_RESOURCES.contains(&resource.as_str()) {
        return unknown_resource(style, &resource, err);
    }
    let project = discover()?;
    if resource != "tool" {
        return show_payload(&project, &slug, &resource, show_base, style, out, err);
    }

    let base = catalog::base_tool_yaml(&slug);
    let user_file = project.user_tool_file(&slug);
    if show_base {
        let Some(base) = base else {
            put(
                err,
                format!("{}: No base template for '{slug}'.\n", style.red("Error")).as_bytes(),
            )?;
            return Ok(1);
        };
        put(
            out,
            format!(
                "\n{} {}\n\n",
                style.bold("  Base template"),
                style.dim(&base_tool_shown(&slug))
            )
            .as_bytes(),
        )?;
        put(out, &text::sed_indent(base.as_bytes()))?;
        put(out, b"\n")?;
        return Ok(0);
    }
    let user_text = read_text(&user_file)?;
    if base.is_none() && user_text.is_none() {
        put(
            err,
            format!(
                "{}: Unknown tool '{slug}'.\nRun {} to see available tools.\n",
                style.red("Error"),
                style.cyan("agentsync list")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let label = if project.enabled_tools()?.contains(&slug) {
        style.green("enabled")
    } else {
        style.dim("disabled")
    };
    let tool = Tool::load(&project, &slug)?;
    let mut text = format!(
        "\n{}  [{label}]\n",
        style.bold(&format!("  {}", tool.display_name()))
    );
    if user_text.is_some() {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!("  override: {}", user_file.disk_text()))
        ));
    }
    if base.is_some() {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!("  base:     {}", base_tool_shown(&slug)))
        ));
    }
    text.push('\n');
    for key in KEYS {
        let user = user_text
            .as_deref()
            .map(|t| yaml_subset::value(t, key))
            .unwrap_or_default();
        let shipped = base.map(|t| yaml_subset::value(t, key)).unwrap_or_default();
        if !user.is_empty() {
            text.push_str(&format!(
                "    {}  {key:<42}  {user}\n",
                style.yellow("★ user")
            ));
        } else if !shipped.is_empty() {
            text.push_str(&format!(
                "    {}  {key:<42}  {shipped}\n",
                style.dim("base  ")
            ));
        }
    }
    text.push('\n');
    put(out, text.as_bytes())?;
    Ok(0)
}

/// `_show_payload`.
fn show_payload(
    project: &Project,
    slug: &str,
    resource: &str,
    show_base: bool,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let tool = Tool::load(project, slug)?;
    let base = payload::base_source(&tool, resource);
    let user_file = payload::override_path(project, &tool, resource).filter(|p| p.is_file());
    let legacy = payload::legacy_override_path(project, &tool, resource).filter(|p| p.is_file());
    let (effective, warn) = payload::effective_source(project, &tool, resource)?;
    if let Some(path) = &warn {
        put(
            err,
            payload::legacy_warning(project, path, style).as_bytes(),
        )?;
    }

    if show_base {
        let Some(base) = base else {
            put(
                err,
                format!(
                    "{}: No base {resource} template for '{slug}'.\n",
                    style.red("Error")
                )
                .as_bytes(),
            )?;
            return Ok(1);
        };
        put(
            out,
            format!(
                "\n{} {}\n\n",
                style.bold(&format!("  Base {resource}")),
                style.dim(&base.shown())
            )
            .as_bytes(),
        )?;
        put(out, &text::sed_indent(&base.bytes()?))?;
        put(out, b"\n")?;
        return Ok(0);
    }
    let Some(effective) = effective else {
        put(
            err,
            format!(
                "{}: No {resource} source for '{slug}' (neither override nor base).\nRun {} to see available tools.\n",
                style.red("Error"),
                style.cyan("agentsync list")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    };
    let is = |path: &Option<std::path::PathBuf>| matches!((&effective, path), (Source::Disk(e), Some(p)) if e == p);
    let label = if is(&user_file) {
        style.yellow("★ user override")
    } else if is(&legacy) {
        style.yellow("★ user override (legacy layout)")
    } else {
        style.dim("base")
    };
    let mut text = format!(
        "\n{}\n{}\n",
        style.bold(&format!(
            "  {} — {resource}  [{label}]",
            tool.display_name()
        )),
        style.dim(&format!("  effective: {}", effective.shown()))
    );
    if let Some(user) = &user_file {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!("  override:  {}", user.disk_text()))
        ));
    }
    if let (Some(legacy), None) = (&legacy, &user_file) {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!("  legacy:    {}", legacy.disk_text()))
        ));
    }
    if let Some(base) = &base {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!("  base:      {}", base.shown()))
        ));
    }
    text.push('\n');
    put(out, text.as_bytes())?;
    put(out, &text::sed_indent(&effective.bytes()?))?;
    put(out, b"\n")?;
    Ok(0)
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn call(root: &str, args: &[&str]) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let discover = || Project::at(root);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = show(&args, &discover, &Style::plain(), &mut out, &mut err).unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    fn project() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        std::fs::create_dir_all(format!("{root}/.ai/src/tools")).unwrap();
        std::fs::write(
            format!("{root}/.ai/agent_sync.yaml"),
            "tools:\n  enabled:\n    - cursor\n",
        )
        .unwrap();
        (dir, root)
    }

    #[test]
    fn help_and_the_missing_slug_refusal_share_one_synopsis() {
        let (_dir, root) = project();
        assert_eq!(
            call(&root, &["--help"]),
            (
                0,
                "\n  agentsync show — show effective config for a tool\n\n  USAGE\n    agentsync show <slug> [<resource>] [--base]\n\n  DESCRIPTION\n    Print effective configuration for a tool. Each line is marked \"base\"\n    (inherited from the shipped template) or \"user\" (overridden in\n    .ai/src/tools/<slug>.yaml).\n\n  ARGUMENTS\n    <slug>       Tool to show\n    <resource>   Payload resource: tool, hooks, mcp, settings\n                 (default: tool, the YAML config)\n\n  OPTIONS\n    --base       Print the base template only, ignoring user overrides\n    -h, --help   Show this help\n\n  EXAMPLES\n    agentsync show cursor\n    agentsync show cursor --base\n    agentsync show claude hooks\n\n".to_string(),
                String::new()
            )
        );
        assert_eq!(
            call(&root, &[]),
            (
                1,
                String::new(),
                "Error: agentsync show <slug> [<resource>] [--base]\n  <resource>: tool hooks mcp settings (default: tool)\n".to_string()
            )
        );
    }

    #[test]
    fn show_marks_user_and_base_values() {
        let (_dir, root) = project();
        std::fs::write(
            format!("{root}/.ai/src/tools/cursor.yaml"),
            "targets:\n  rules:\n    dest: \".custom/rules\"\n",
        )
        .unwrap();
        let (status, out, _) = call(&root, &["cursor"]);
        assert_eq!(status, 0);
        assert!(out.starts_with(&format!(
            "\n  Cursor  [enabled]\n  override: {root}/.ai/src/tools/cursor.yaml\n  base:     /<agentsync>/lib/templates/tools/cursor.yaml\n\n    base    {:<42}  Cursor\n",
            "name"
        )));
        assert!(out.contains(&format!(
            "    ★ user  {:<42}  .custom/rules\n",
            "targets.rules.dest"
        )));
        assert!(out.ends_with("\n\n"));
        assert_eq!(
            call(&root, &["nope"]),
            (
                1,
                String::new(),
                "Error: Unknown tool 'nope'.\nRun agentsync list to see available tools.\n"
                    .to_string()
            )
        );
    }

    #[test]
    fn show_labels_the_effective_payload_and_warns_about_legacy_layout() {
        let (_dir, root) = project();
        assert_eq!(
            call(&root, &["cursor", "hooks"]).1,
            "\n  Cursor — hooks  [base]\n  effective: /<agentsync>/lib/templates/hooks/cursor.json\n  base:      /<agentsync>/lib/templates/hooks/cursor.json\n\n    {\n      \"version\": 1,\n      \"hooks\": {}\n    }\n\n"
        );
        std::fs::create_dir_all(format!("{root}/.ai/src/hooks")).unwrap();
        std::fs::write(format!("{root}/.ai/src/hooks/cursor.json"), "{}\n").unwrap();
        let (status, out, err) = call(&root, &["cursor", "hooks"]);
        assert_eq!(status, 0);
        assert_eq!(
            err,
            "!  Legacy payload override layout detected: .ai/src/hooks/cursor.json\n   Move to .ai/src/tools/<tool>/<resource>.<ext> (canonical since 0.11).\n   Migrate with: agentsync migrate --legacy\n"
        );
        assert_eq!(
            out,
            format!(
                "\n  Cursor — hooks  [★ user override (legacy layout)]\n  effective: {root}/.ai/src/hooks/cursor.json\n  legacy:    {root}/.ai/src/hooks/cursor.json\n  base:      /<agentsync>/lib/templates/hooks/cursor.json\n\n    {{}}\n\n"
            )
        );
    }
}
