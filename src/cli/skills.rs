use std::io::Write;

use crate::config::skill_metadata;
use crate::engine::filters;
use crate::engine::render::{self, Env};
use crate::engine::session::Session;
use crate::engine::workspace::Workspace;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths::Paths;
use crate::{Error, paths};

mod catalog;

pub const HELP: Help = Help {
    command: "skills",
    tagline: "inspect skills used by this project",
    synopsis: &[
        "skills list [--profile <name>] [--include <globs>] [--exclude <globs>]",
        "skills show <name> [--profile <name>]",
        "skills check [--profile <name>]",
        "skills catalog list --catalog <file> [--source <alias=local-repo>]...",
        "skills catalog show <id> --catalog <file> [--source <alias=local-repo>]...",
    ],
    description: &[
        "Reads the effective source.skills tree, including shared and bundled\nskills. --profile applies the same profile overlay as sync. No project\nfiles are changed.",
        "show displays the skill's declared metadata and optional annotations.\nThose annotations and requirements are not verified by AgentSync.",
        "check verifies the required fields and supported scalar forms. For\nfull Agent Skills validation, use skills-ref validate <skill-dir>.\nIt does not change whether sync accepts a skill.",
        "catalog inspects explicitly declared external skills. Its curator\nnotes are unverified; pinned local Git metadata is read only when a source\nmapping is supplied. It never installs or runs a skill.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "--profile <name>",
                "Inspect this configured profile's skills",
            ),
            ("--include <globs>", "List only matching skill names"),
            ("--exclude <globs>", "Exclude matching skill names"),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &[
        "skills list",
        "skills show deploy",
        "skills check",
        "skills list --profile work --include 'review*'",
        "skills catalog list --catalog cards.tsv",
    ],
};

enum Action {
    List,
    Check,
    Show(String),
}

struct Args {
    action: Action,
    profile: Option<String>,
    include: String,
    exclude: String,
}

pub fn run(
    args: &[String],
    root: &str,
    env: &Env,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    if args.first().is_some_and(|arg| arg == "catalog") {
        return catalog::run(&args[1..], style, out, err);
    }
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "-h" | "--help"))
    {
        write(out, &HELP.render(style))?;
        return Ok(0);
    }
    let parsed = match parse(args) {
        Ok(parsed) => parsed,
        Err(message) => {
            write(err, &format!("Error: {message}\n"))?;
            return Ok(1);
        }
    };
    let mut session = Session::new(Workspace::on_disk(root), Paths::on_disk(root));
    let source = match render::skill_source(&mut session, env, parsed.profile.as_deref()) {
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
    if matches!(parsed.action, Action::List) {
        write(out, "name\tdescription\tpath\n")?;
    }
    for name in session.ws.glob(&source.effective) {
        let dir = format!("{}/{name}", source.effective);
        if !session.ws.is_dir(&dir) {
            continue;
        }
        if let Action::Show(target) = &parsed.action
            && &name != target
        {
            continue;
        }
        if matches!(parsed.action, Action::List)
            && !filters::matches(&name, &parsed.include, &parsed.exclude)
        {
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
            skill_metadata::read(&bytes, &name)
        } else {
            Err("missing SKILL.md".to_string())
        };
        match &parsed.action {
            Action::List => {
                let description = metadata
                    .as_ref()
                    .map(|metadata| metadata.description.as_str())
                    .unwrap_or_default();
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
            Action::Show(_) => match metadata {
                Ok(metadata) => {
                    write(out, &format!("Name: {}\n", cell(&metadata.name)))?;
                    write(
                        out,
                        &format!("Description: {}\n", cell(&metadata.description)),
                    )?;
                    if let Some(value) = metadata.compatibility {
                        write(
                            out,
                            &format!("Compatibility (declared): {}\n", cell(&value)),
                        )?;
                    }
                    if let Some(value) = metadata.license {
                        write(out, &format!("License: {}\n", cell(&value)))?;
                    }
                    for (label, value) in [
                        ("Use when", metadata.use_when),
                        ("Not for", metadata.not_for),
                        ("Requirements", metadata.requirements),
                    ] {
                        if let Some(value) = value {
                            write(
                                out,
                                &format!("{label} (annotation, unverified): {}\n", cell(&value)),
                            )?;
                        }
                    }
                    write(out, &format!("Path: {}\n", cell(&shown)))?;
                }
                Err(message) => {
                    write(
                        err,
                        &format!("Error: {}: {}\n", cell(&shown), cell(&message)),
                    )?;
                    return Ok(1);
                }
            },
        }
    }
    if matches!(parsed.action, Action::Check) {
        write(out, &format!("Checked {count} skills: {issues} issue(s)\n"))?;
    }
    if let Action::Show(name) = &parsed.action
        && count == 0
    {
        write(err, &format!("Error: unknown skill: {}\n", cell(name)))?;
        return Ok(1);
    }
    Ok(u8::from(issues > 0))
}

fn parse(args: &[String]) -> Result<Args, String> {
    let action = match args.first().map(String::as_str) {
        Some("show") => {
            let Some(name) = args.get(1).filter(|name| !name.starts_with('-')) else {
                return Err("skills show requires a name".to_string());
            };
            Action::Show(name.clone())
        }
        Some("list") => Action::List,
        Some("check") => Action::Check,
        _ => return Err("expected skills list|show|check".to_string()),
    };
    let mut parsed = Args {
        action,
        profile: None,
        include: String::new(),
        exclude: String::new(),
    };
    let start = if matches!(parsed.action, Action::Show(_)) {
        2
    } else {
        1
    };
    let mut options = args[start..].iter();
    while let Some(option) = options.next() {
        let Some(value) = options
            .next()
            .filter(|value| !value.is_empty() && !value.starts_with('-'))
        else {
            return Err(format!("{option} requires a value"));
        };
        match option.as_str() {
            "--profile" if parsed.profile.is_none() => parsed.profile = Some(value.clone()),
            "--include" if matches!(parsed.action, Action::List) => {
                append_globs(&mut parsed.include, value)
            }
            "--exclude" if matches!(parsed.action, Action::List) => {
                append_globs(&mut parsed.exclude, value)
            }
            _ => return Err(format!("unknown option: {option}")),
        }
    }
    Ok(parsed)
}

fn append_globs(slot: &mut String, value: &str) {
    if !slot.is_empty() {
        slot.push(' ');
    }
    slot.push_str(value);
}

fn cell(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_control()
                || matches!(c, '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}')
            {
                ' '
            } else {
                c
            }
        })
        .collect()
}

fn write(out: &mut dyn Write, text: &str) -> Result<(), Error> {
    out.write_all(text.as_bytes())
        .map_err(|e| Error::io("<output>", e))
}
