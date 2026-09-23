//! Read-only commands for an explicitly selected MCP catalog.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::Error;
use crate::config::{mcp_catalog, yaml_subset};
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths;
use crate::project::Project;

pub const HELP: Help = Help {
    command: "mcp",
    tagline: "inspect an offline MCP catalog",
    synopsis: &[
        "mcp list --library <directory>",
        "mcp show <id> --library <directory>",
        "mcp validate [id] --library <directory>",
        "mcp render <id>[@variant] --library <directory>",
    ],
    description: &[
        "Reads bounded JSON manifests from an explicit library or the configured\nlibrary.mcp.path. It never starts servers, contacts endpoints, or changes\nproject or client configuration.",
        "list prints ID and title. show prints the original manifest bytes.\nvalidate checks one entry or the complete library, including all variants.\nrender prints one selected connection as AgentSync MCP source JSON.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "--library <directory>",
                "Explicit catalog path, absolute or relative to the project root",
            ),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &[
        "mcp list --library catalog/mcp",
        "mcp show microsoft-learn --library catalog/mcp",
        "mcp validate --library catalog/mcp",
        "mcp render microsoft-learn@recommended --library catalog/mcp",
    ],
};

#[derive(Clone, Copy)]
enum Action {
    Help,
    List,
    Show,
    Validate,
    Render,
}

struct Args {
    action: Action,
    id: Option<String>,
    variant: Option<String>,
    library: Option<PathBuf>,
}

pub fn run(
    args: &[String],
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let args = match parse(args) {
        Ok(args) => args,
        Err(message) => return refuse(style, &message, err),
    };
    if matches!(args.action, Action::Help) {
        put(out, HELP.render(style).as_bytes())?;
        return Ok(0);
    }
    let project = Project::discover()?;
    let library = match library_path(&project, args.library) {
        Ok(path) => path,
        Err(message) => return refuse(style, &message, err),
    };
    if matches!(args.action, Action::Render) {
        let rendered = match mcp_catalog::render(
            &library,
            args.id.as_deref().expect("render requires an id"),
            args.variant.as_deref().unwrap_or("default"),
        ) {
            Ok(rendered) => rendered,
            Err(message) => return refuse(style, &message, err),
        };
        put(out, &rendered)?;
        return Ok(0);
    }
    let entries = match mcp_catalog::read(&library, args.id.as_deref()) {
        Ok(entries) => entries,
        Err(message) => return refuse(style, &message, err),
    };
    match args.action {
        Action::List => {
            let mut text = String::new();
            for entry in &entries {
                text.push_str(&entry.id);
                text.push('\t');
                text.push_str(&mcp_catalog::escaped_title(&entry.title));
                text.push('\n');
            }
            put(out, text.as_bytes())?;
        }
        Action::Show => put(out, &entries[0].raw)?,
        Action::Validate => put(out, b"MCP library is valid\n")?,
        Action::Help | Action::Render => unreachable!(),
    }
    Ok(0)
}

fn library_path(project: &Project, explicit: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        let path = paths::from_msys(
            &path.to_string_lossy(),
            std::env::var("MSYSTEM").ok().as_deref(),
        );
        let path = PathBuf::from(path);
        return Ok(if path.is_absolute() {
            path
        } else {
            project.root.join(path)
        });
    }
    let Some(config) = &project.config_path else {
        return Err("No MCP library selected; pass --library".to_string());
    };
    let text = std::fs::read_to_string(config).map_err(|e| {
        format!(
            "Cannot read project config {}: {e}",
            mcp_catalog::escaped_title(&config.to_string_lossy())
        )
    })?;
    let path = yaml_subset::value(&text, "library.mcp.path");
    if path.is_empty() {
        return Err("No MCP library selected; pass --library".to_string());
    }
    let path = paths::from_msys(&path, std::env::var("MSYSTEM").ok().as_deref());
    let path = Path::new(&path);
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        project.root.join(path)
    };
    let root = std::fs::canonicalize(&project.root)
        .map_err(|e| format!("Cannot resolve project root: {e}"))?;
    let resolved = std::fs::canonicalize(&path).map_err(|e| {
        format!(
            "Cannot resolve configured MCP library {}: {e}",
            mcp_catalog::escaped_title(&path.to_string_lossy())
        )
    })?;
    if !resolved.starts_with(&root) {
        return Err("Configured MCP library is outside the project root".to_string());
    }
    Ok(resolved)
}

fn parse(args: &[String]) -> Result<Args, String> {
    let action = match args.first().map(String::as_str) {
        None | Some("help" | "-h" | "--help") => Action::Help,
        Some("list") => Action::List,
        Some("show") => Action::Show,
        Some("validate") => Action::Validate,
        Some("render") => Action::Render,
        _ => return Err("Usage: agentsync mcp <list|show|validate|render> [options]".to_string()),
    };
    let mut library = None;
    let mut id = None;
    let mut variant = None;
    let mut index = 1;
    while let Some(arg) = args.get(index) {
        match arg.as_str() {
            "-h" | "--help" => {
                return Ok(Args {
                    action: Action::Help,
                    id: None,
                    variant: None,
                    library: None,
                });
            }
            "--library" => {
                let value = args
                    .get(index + 1)
                    .filter(|value| !value.is_empty() && !value.starts_with('-'))
                    .ok_or_else(|| "--library requires a non-empty path".to_string())?;
                if library.replace(PathBuf::from(value)).is_some() {
                    return Err("--library may be supplied only once".to_string());
                }
                index += 2;
            }
            flag if flag.starts_with('-') => {
                return Err(format!(
                    "Unknown MCP option: {}",
                    mcp_catalog::escaped_title(flag)
                ));
            }
            value if !matches!(action, Action::List) && id.is_none() => {
                let (entry_id, selected_variant) = if matches!(action, Action::Render) {
                    value
                        .split_once('@')
                        .map_or((value, None), |(id, variant)| (id, Some(variant)))
                } else {
                    (value, None)
                };
                if !mcp_catalog::valid_id(entry_id) {
                    return Err(format!(
                        "Unsafe MCP library id: {}",
                        mcp_catalog::escaped_title(entry_id)
                    ));
                }
                if let Some(selected_variant) = selected_variant {
                    if !mcp_catalog::valid_id(selected_variant) {
                        return Err(format!(
                            "Unsafe MCP variant id: {}",
                            mcp_catalog::escaped_title(selected_variant)
                        ));
                    }
                    variant = Some(selected_variant.to_string());
                }
                id = Some(entry_id.to_string());
                index += 1;
            }
            value => {
                return Err(format!(
                    "Unexpected MCP argument: {}",
                    mcp_catalog::escaped_title(value)
                ));
            }
        }
    }
    if matches!(action, Action::Show | Action::Render) && id.is_none() {
        return Err(if matches!(action, Action::Show) {
            "mcp show requires an id"
        } else {
            "mcp render requires an id"
        }
        .to_string());
    }
    Ok(Args {
        action,
        id,
        variant,
        library,
    })
}

fn refuse(style: &Style, message: &str, err: &mut dyn Write) -> Result<u8, Error> {
    put(
        err,
        format!("{}: {message}\n", style.red("Error")).as_bytes(),
    )?;
    Ok(1)
}

fn put(out: &mut dyn Write, text: &[u8]) -> Result<(), Error> {
    out.write_all(text).map_err(|e| Error::io("<output>", e))
}
