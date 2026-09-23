use std::io::Write;

use crate::config::yaml_subset;
use crate::engine::render::{self, Env};
use crate::engine::session::Session;
use crate::engine::workspace::Workspace;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths::Paths;
use crate::{Error, paths};

pub const HELP: Help = Help {
    command: "skills",
    tagline: "inspect skills used by this project",
    synopsis: &[
        "skills list [--profile <name>]",
        "skills check [--profile <name>]",
    ],
    description: &[
        "Reads the effective source.skills tree, including shared and bundled\nskills. --profile applies the same profile overlay as sync. No project\nfiles are changed.",
        "check validates the required name and description in SKILL.md\nfrontmatter. It does not change whether sync accepts a skill.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "--profile <name>",
                "Inspect this configured profile's skills",
            ),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &["skills list", "skills check", "skills list --profile work"],
};

#[derive(Clone, Copy)]
enum Action {
    List,
    Check,
}

pub fn run(
    args: &[String],
    root: &str,
    env: &Env,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let Some((action, profile)) = parse(args) else {
        if args
            .iter()
            .any(|arg| matches!(arg.as_str(), "-h" | "--help"))
        {
            write(out, &HELP.render(style))?;
            return Ok(0);
        }
        write(
            err,
            "Error: expected skills list|check [--profile <name>]\n",
        )?;
        return Ok(1);
    };
    let mut session = Session::new(Workspace::on_disk(root), Paths::on_disk(root));
    let source = match render::skill_source(&mut session, env, profile.as_deref()) {
        Ok(source) => source,
        Err(_) => {
            for (_, line) in session.log.lines() {
                write(err, &format!("{line}\n"))?;
            }
            return Ok(1);
        }
    };
    for (_, line) in session.log.lines() {
        if line.starts_with("[WARNING]") {
            write(err, &format!("{line}\n"))?;
        }
    }
    let mut count = 0;
    let mut issues = 0;
    if matches!(action, Action::List) {
        write(out, "name\tdescription\tpath\n")?;
    }
    for name in session.ws.glob(&source.effective) {
        let dir = format!("{}/{name}", source.effective);
        if !session.ws.is_dir(&dir) {
            continue;
        }
        count += 1;
        let file = format!("{dir}/SKILL.md");
        let origin = source
            .origins
            .iter()
            .map(|dir| format!("{dir}/{name}/SKILL.md"))
            .find(|file| session.ws.is_file(file))
            .or_else(|| {
                source
                    .origins
                    .iter()
                    .map(|dir| format!("{dir}/{name}/SKILL.md"))
                    .find(|file| session.ws.is_dir(&paths::parent(file)))
            })
            .unwrap_or_else(|| file.clone());
        let shown = if origin.starts_with(paths::ENGINE_ROOT) {
            format!("bundled:skills/{name}/SKILL.md")
        } else {
            session.display(&origin)
        };
        let metadata = if session.ws.is_file(&file) {
            let bytes = session.ws.read(&file)?;
            parse_metadata(&bytes, &name)
        } else {
            Err("missing SKILL.md".to_string())
        };
        match action {
            Action::List => {
                let description = metadata.as_ref().map(String::as_str).unwrap_or_default();
                write(
                    out,
                    &format!("{}\t{}\t{}\n", cell(&name), cell(description), cell(&shown)),
                )?;
            }
            Action::Check => match metadata {
                Ok(_) => {}
                Err(message) => {
                    issues += 1;
                    write(out, &format!("{}: {}\n", cell(&shown), cell(&message)))?;
                }
            },
        }
    }
    if matches!(action, Action::Check) {
        write(out, &format!("Checked {count} skills: {issues} issue(s)\n"))?;
    }
    Ok(u8::from(issues > 0))
}

fn parse(args: &[String]) -> Option<(Action, Option<String>)> {
    let action = match args.first()?.as_str() {
        "list" => Action::List,
        "check" => Action::Check,
        _ => return None,
    };
    match &args[1..] {
        [] => Some((action, None)),
        [flag, name] if flag == "--profile" && !name.is_empty() && !name.starts_with('-') => {
            Some((action, Some(name.clone())))
        }
        _ => None,
    }
}

fn parse_metadata(bytes: &[u8], directory: &str) -> Result<String, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "SKILL.md is not UTF-8".to_string())?;
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return Err("missing YAML frontmatter".to_string());
    }
    let frontmatter: Vec<&str> = lines
        .by_ref()
        .take_while(|line| line.trim() != "---")
        .collect();
    if !text.lines().skip(1).any(|line| line.trim() == "---") {
        return Err("unclosed YAML frontmatter".to_string());
    }
    let frontmatter = frontmatter.join("\n");
    let name = yaml_subset::value(&frontmatter, "name");
    if name.is_empty() {
        return Err("missing name".to_string());
    }
    if name != directory {
        return Err(format!(
            "name '{name}' does not match directory '{directory}'"
        ));
    }
    if name.len() > 64
        || !name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
        || name.starts_with('-')
        || name.ends_with('-')
    {
        return Err("name must be 1–64 lowercase letters, digits, or hyphens".to_string());
    }
    let raw = yaml_subset::value(&frontmatter, "description");
    let description = if matches!(raw.as_str(), ">" | ">-" | "|" | "|-") {
        let mut folded = Vec::new();
        let mut collecting = false;
        for line in frontmatter.lines() {
            if collecting {
                if line.starts_with([' ', '\t']) {
                    folded.push(line.trim());
                } else {
                    break;
                }
            } else if line.starts_with("description:") {
                collecting = true;
            }
        }
        folded.join(" ")
    } else {
        raw
    };
    if description.trim().is_empty() || description.chars().count() > 1024 {
        return Err("description must be 1–1024 characters".to_string());
    }
    Ok(description)
}

fn cell(value: &str) -> String {
    value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

fn write(out: &mut dyn Write, text: &str) -> Result<(), Error> {
    out.write_all(text.as_bytes())
        .map_err(|e| Error::io("<output>", e))
}
