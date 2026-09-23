//! `agentsync simplify`: `cmd_simplify` of `lib/helpers/simplify.sh`, which
//! drops override fields equal to the base and byte-identical payload copies.

use crate::paths::DiskText;
use std::io::Write;
use std::path::{Path, PathBuf};

use super::customize::relative;
use super::put;
use crate::config::tool::Tool;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::project::Project;
use crate::{Error, config::catalog, config::yaml_edit, config::yaml_subset};

pub const HELP: Help = Help {
    command: "simplify",
    tagline: "drop override fields that match base",
    synopsis: &["simplify [<tool>] [--apply] [-y]"],
    description: &[
        "Removes fields from user overrides when they match the base.\nDry-run by default: pass --apply to persist.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            ("--apply", "Write changes to disk (default: preview)"),
            ("-y, --yes", "Auto-delete empty override files (no prompt)"),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &["simplify", "simplify cursor --apply", "simplify --apply -y"],
};

const KEYS: [&str; 31] = [
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
    "targets.skills.source",
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

type Ask<'a> = &'a mut dyn FnMut(&str, &mut dyn Write) -> String;

fn yes(answer: &str) -> bool {
    matches!(answer, "y" | "Y" | "yes" | "Yes")
}

fn read_text(path: &Path) -> String {
    std::fs::read(path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .unwrap_or_default()
}

/// `_simplify_file_has_content`.
fn has_content(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    let is_space = |c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r');
    read_text(path).split('\n').any(|line| {
        let stripped = line.trim_start_matches(is_space);
        if line.is_empty() || stripped.starts_with('#') {
            return false;
        }
        let key_end = stripped
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-'))
            .unwrap_or(stripped.len());
        let assignment = key_end > 0
            && stripped[key_end..]
                .strip_prefix(':')
                .is_some_and(|rest| rest.starts_with(is_space) && rest.chars().count() >= 2);
        let item = stripped
            .strip_prefix('-')
            .is_some_and(|rest| rest.starts_with(is_space));
        assignment || item
    })
}

pub fn simplify(
    args: &[String],
    discover: &dyn Fn() -> Result<Project, Error>,
    style: &Style,
    interactive: bool,
    ask: Ask,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let (mut apply, mut auto_yes, mut filter) = (false, false, String::new());
    for arg in args {
        match arg.as_str() {
            "--apply" => apply = true,
            "-y" | "--yes" => auto_yes = true,
            "-h" | "--help" => {
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
            value if filter.is_empty() => filter = value.to_string(),
            _ => {
                put(
                    err,
                    format!("{}: Only one tool at a time.\n", style.red("Error")).as_bytes(),
                )?;
                return Ok(1);
            }
        }
    }

    let project = discover()?;
    if apply && !project.tools_dir_in_project() {
        return super::refuse_outside_tools_dir(&project, style, err);
    }
    let mut matched = false;
    for slug in project.user_override_tools()? {
        if !filter.is_empty() && slug != filter {
            continue;
        }
        matched = true;
        simplify_tool(
            &project,
            &slug,
            apply,
            auto_yes,
            interactive,
            style,
            ask,
            out,
        )?;
    }
    if payload_overrides(
        &project,
        apply,
        auto_yes,
        &filter,
        interactive,
        style,
        ask,
        out,
    )? {
        matched = true;
    }
    if !matched {
        if !filter.is_empty() {
            put(
                err,
                format!(
                    "{}: No override found for '{filter}'.\n",
                    style.red("Error")
                )
                .as_bytes(),
            )?;
            return Ok(1);
        }
        put(
            out,
            format!(
                "\n  {}\n\n",
                style.dim("No user overrides — nothing to simplify.")
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }
    let footer = if apply {
        format!(
            "\n{}\n  Run {} to verify outputs are unchanged.\n\n",
            style.green("Done."),
            style.cyan("agentsync sync")
        )
    } else {
        format!("\n{}\n\n", style.dim("Dry run — pass --apply to persist."))
    };
    put(out, footer.as_bytes())?;
    Ok(0)
}

/// `_simplify_one_tool`.
#[allow(clippy::too_many_arguments)]
fn simplify_tool(
    project: &Project,
    slug: &str,
    apply: bool,
    auto_yes: bool,
    interactive: bool,
    style: &Style,
    ask: Ask,
    out: &mut dyn Write,
) -> Result<(), Error> {
    let user_file = project.user_tool_file(slug);
    if !user_file.is_file() {
        return Ok(());
    }
    let base = catalog::base_tool_yaml(slug);
    let rel = relative(project, &user_file);
    put(
        out,
        format!(
            "\n{}\n{}\n",
            style.bold(&format!("  {}", Tool::load(project, slug)?.display_name())),
            style.dim(&format!("  override: {rel}"))
        )
        .as_bytes(),
    )?;
    let user_text = read_text(&user_file);
    let (mut redundant, mut kept, mut user_only) = (Vec::new(), Vec::new(), Vec::new());
    for key in KEYS {
        let user = yaml_subset::value(&user_text, key);
        if user.is_empty() {
            continue;
        }
        let shipped = base.map(|t| yaml_subset::value(t, key)).unwrap_or_default();
        if !shipped.is_empty() && user == shipped {
            redundant.push((key, user));
        } else if shipped.is_empty() {
            user_only.push((key, user));
        } else {
            kept.push((key, user));
        }
    }
    if redundant.is_empty() {
        put(
            out,
            format!(
                "{}\n",
                style.dim("  No redundant fields — already minimal.")
            )
            .as_bytes(),
        )?;
        return Ok(());
    }
    let mut text = format!("  {}\n", style.yellow("Redundant (match base):"));
    for (key, value) in &redundant {
        text.push_str(&format!("    {} {key:<42}  {value}\n", style.dim("-")));
    }
    text.push('\n');
    for (title, list) in [
        ("  Kept (diverge from base):", &kept),
        ("  Kept (no base value):", &user_only),
    ] {
        if list.is_empty() {
            continue;
        }
        text.push_str(&format!("{}\n", style.dim(title)));
        for (key, value) in list {
            text.push_str(&format!("    {} {key:<42}  {value}\n", style.dim("=")));
        }
        text.push('\n');
    }
    if !apply {
        let hint = if kept.len() + user_only.len() == 0 {
            "  → would delete the override file (all fields match base).".to_string()
        } else {
            format!("  → would remove {} field(s).", redundant.len())
        };
        text.push_str(&format!("{}\n\n", style.dim(&hint)));
        return put(out, text.as_bytes());
    }
    put(out, text.as_bytes())?;
    for (key, _) in &redundant {
        yaml_edit::remove_key(&user_file, key)?;
    }
    put(
        out,
        format!(
            "  {} {} field(s).\n",
            style.green("Removed"),
            redundant.len()
        )
        .as_bytes(),
    )?;
    if !has_content(&user_file) {
        let delete = auto_yes
            || (interactive && yes(&ask(&style.bold("Delete empty override file? [y/N]"), out)));
        if delete {
            std::fs::remove_file(&user_file).map_err(|e| Error::io(&user_file, e))?;
            put(
                out,
                format!("  {} {rel}\n", style.green("Deleted")).as_bytes(),
            )?;
        } else {
            put(
                out,
                format!(
                    "{}\n",
                    style.dim("  Kept empty file — remove manually if desired.")
                )
                .as_bytes(),
            )?;
        }
    }
    put(out, b"\n")
}

fn sorted_entries(dir: &Path) -> Vec<(String, PathBuf)> {
    let mut entries: Vec<(String, PathBuf)> = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| (e.file_name().disk_text(), e.path()))
                .filter(|(name, _)| !name.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    entries.sort();
    entries
}

/// `_simplify_payload_overrides`: whether any payload was considered.
#[allow(clippy::too_many_arguments)]
fn payload_overrides(
    project: &Project,
    apply: bool,
    auto_yes: bool,
    filter: &str,
    interactive: bool,
    style: &Style,
    ask: Ask,
    out: &mut dyn Write,
) -> Result<bool, Error> {
    let src = project.root.join(".ai").join("src");
    let (mut redundant, mut kept, mut legacy) = (Vec::new(), Vec::new(), Vec::new());
    let mut matched = false;
    for (tool, dir) in sorted_entries(&src.join("tools")) {
        if !dir.is_dir() || (!filter.is_empty() && tool != filter) {
            continue;
        }
        let loaded = Tool::load(project, &tool)?;
        for resource in ["hooks", "mcp", "settings"] {
            for (name, file) in sorted_entries(&dir) {
                if !name.starts_with(&format!("{resource}.")) || !file.is_file() {
                    continue;
                }
                matched = true;
                let identical = loaded.base_payload(resource).is_some_and(|base| {
                    std::fs::read(&file).is_ok_and(|bytes| bytes == base.contents())
                });
                if identical {
                    redundant.push(file);
                } else {
                    kept.push(file);
                }
            }
        }
    }
    for resource in ["hooks", "mcp", "settings"] {
        for (name, file) in sorted_entries(&src.join(resource)) {
            if !file.is_file() {
                continue;
            }
            let tool = name
                .rsplit_once('.')
                .map_or(name.as_str(), |(stem, _)| stem);
            if !filter.is_empty() && tool != filter {
                continue;
            }
            matched = true;
            legacy.push(file);
        }
    }
    if redundant.is_empty() && kept.is_empty() && legacy.is_empty() {
        return Ok(matched);
    }

    let mut text = format!("\n{}\n\n", style.bold("  Payload overrides"));
    if !legacy.is_empty() {
        text.push_str(&format!(
            "  {}\n",
            style.yellow(
                "Legacy layout — move into .ai/src/tools/<tool>/ (flat layout is deprecated):"
            )
        ));
        for file in &legacy {
            text.push_str(&format!(
                "    {} {}\n",
                style.dim("·"),
                relative(project, file)
            ));
        }
        text.push_str(&format!(
            "\n{}\n{}\n\n",
            style.dim(&format!(
                "  Run {} to preview the migration,",
                style.cyan("agentsync migrate --legacy")
            )),
            style.dim(&format!(
                "  then {} to move these files.",
                style.cyan("agentsync migrate --apply")
            ))
        ));
    }
    if redundant.is_empty() && kept.is_empty() {
        put(out, text.as_bytes())?;
        return Ok(matched);
    }
    if redundant.is_empty() {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!(
                "  No byte-identical payload overrides — {} real customization(s).",
                kept.len()
            ))
        ));
        put(out, text.as_bytes())?;
        return Ok(matched);
    }
    text.push_str(&format!(
        "  {}\n",
        style.yellow("Byte-identical to base (safe to delete):")
    ));
    for file in &redundant {
        text.push_str(&format!(
            "    {} {}\n",
            style.dim("-"),
            relative(project, file)
        ));
    }
    text.push('\n');
    if !kept.is_empty() {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!(
                "  Kept (diverge from base or no base): {} file(s)",
                kept.len()
            ))
        ));
    }
    if !apply {
        text.push_str(&format!(
            "{}\n",
            style.dim(&format!(
                "  → would delete {} payload override(s).",
                redundant.len()
            ))
        ));
        put(out, text.as_bytes())?;
        return Ok(matched);
    }
    put(out, text.as_bytes())?;
    let (mut deleted, mut skipped) = (0usize, 0usize);
    for file in &redundant {
        let rel = relative(project, file);
        let delete = auto_yes
            || !interactive
            || yes(&ask(&style.bold(&format!("Delete {rel}? [y/N]")), out));
        if delete {
            std::fs::remove_file(file).map_err(|e| Error::io(file, e))?;
            if let Some(dir) = file.parent() {
                let _ = std::fs::remove_dir(dir);
            }
            put(
                out,
                format!("  {} {rel}\n", style.green("Deleted")).as_bytes(),
            )?;
            deleted += 1;
        } else {
            put(
                out,
                format!("{}\n", style.dim(&format!("  Kept {rel}"))).as_bytes(),
            )?;
            skipped += 1;
        }
    }
    put(
        out,
        format!(
            "\n{}\n",
            style.dim(&format!("  Removed {deleted}, kept {skipped}."))
        )
        .as_bytes(),
    )?;
    Ok(matched)
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;

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

    fn call(root: &str, args: &[&str], interactive: bool, answer: &str) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let discover = || Project::at(root);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = simplify(
            &args,
            &discover,
            &Style::plain(),
            interactive,
            &mut |prompt, out| {
                let _ = out.write_all(format!("  {prompt} ").as_bytes());
                answer.to_string()
            },
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
    fn a_dry_run_lists_redundant_and_kept_fields_like_bash() {
        let (_dir, root) = project();
        assert_eq!(
            call(&root, &["--help"], false, ""),
            (
                0,
                "\n  agentsync simplify — drop override fields that match base\n\n  USAGE\n    agentsync simplify [<tool>] [--apply] [-y]\n\n  DESCRIPTION\n    Removes fields from user overrides when they match the base.\n    Dry-run by default: pass --apply to persist.\n\n  OPTIONS\n    --apply      Write changes to disk (default: preview)\n    -y, --yes    Auto-delete empty override files (no prompt)\n    -h, --help   Show this help\n\n  EXAMPLES\n    agentsync simplify\n    agentsync simplify cursor --apply\n    agentsync simplify --apply -y\n\n".to_string(),
                String::new()
            )
        );
        assert_eq!(
            call(&root, &[], false, "").1,
            "\n  No user overrides — nothing to simplify.\n\n"
        );
        let file = format!("{root}/.ai/src/tools/cursor.yaml");
        std::fs::write(
            &file,
            "name: \"Cursor\"\nenabled: true\n\ntargets:\n  rules:\n    dest: \".cursor/rules\"\n    extension: \".mdcustom\"\n  custom:\n    x: 1\n",
        )
        .unwrap();
        let (status, out, _) = call(&root, &[], false, "");
        assert_eq!(status, 0);
        assert_eq!(
            out,
            format!(
                "\n  Cursor\n  override: .ai/src/tools/cursor.yaml\n  Redundant (match base):\n    - {:<42}  Cursor\n    - {:<42}  .cursor/rules\n\n  Kept (diverge from base):\n    = {:<42}  true\n    = {:<42}  .mdcustom\n\n  → would remove 2 field(s).\n\n\nDry run — pass --apply to persist.\n\n",
                "name", "targets.rules.dest", "enabled", "targets.rules.extension"
            )
        );
        assert_eq!(
            call(&root, &["nope"], false, "").2,
            "Error: No override found for 'nope'.\n"
        );

        let (_, applied, _) = call(&root, &["--apply"], false, "");
        assert!(applied.contains("  Removed 2 field(s).\n\n\nDone.\n  Run agentsync sync to verify outputs are unchanged.\n\n"));
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "enabled: true\n\ntargets:\n  rules:\n    extension: \".mdcustom\"\n  custom:\n    x: 1\n"
        );
    }

    #[test]
    fn an_emptied_override_is_kept_off_a_terminal_and_deleted_on_yes() {
        let (_dir, root) = project();
        let file = format!("{root}/.ai/src/tools/cursor.yaml");
        std::fs::write(&file, "name: \"Cursor\"\n").unwrap();
        let (_, kept, _) = call(&root, &["--apply"], false, "");
        assert!(kept.ends_with("  Removed 1 field(s).\n  Kept empty file — remove manually if desired.\n\n\nDone.\n  Run agentsync sync to verify outputs are unchanged.\n\n"));
        assert!(std::path::Path::new(&file).is_file());

        std::fs::write(&file, "name: \"Cursor\"\n").unwrap();
        let (_, deleted, _) = call(&root, &["--apply"], true, "y");
        assert!(deleted.contains("  Removed 1 field(s).\n  Delete empty override file? [y/N]   Deleted .ai/src/tools/cursor.yaml\n"));
        assert!(!std::path::Path::new(&file).exists());

        std::fs::create_dir_all(format!("{root}/.ai/src/tools/cursor")).unwrap();
        std::fs::write(
            format!("{root}/.ai/src/tools/cursor/hooks.json"),
            crate::config::catalog::base_payload("hooks", "cursor")
                .unwrap()
                .contents(),
        )
        .unwrap();
        let (_, payload, _) = call(&root, &["--apply"], true, "n");
        assert!(payload.contains("  Delete .ai/src/tools/cursor/hooks.json? [y/N]   Kept .ai/src/tools/cursor/hooks.json\n\n  Removed 0, kept 1.\n"));
        let (_, gone, _) = call(&root, &["--apply", "-y"], false, "");
        assert!(
            gone.contains("  Deleted .ai/src/tools/cursor/hooks.json\n\n  Removed 1, kept 0.\n")
        );
        assert!(!std::path::Path::new(&format!("{root}/.ai/src/tools/cursor")).exists());
    }
}
