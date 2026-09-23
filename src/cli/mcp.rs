//! Inspection and explicit source creation from an MCP catalog.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::Error;
use crate::config::{mcp_catalog, payload, tool::Tool, yaml_subset};
use crate::engine::staging;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::paths;
use crate::project::Project;
use crate::transaction::{backup, witness};

pub const HELP: Help = Help {
    command: "mcp",
    tagline: "inspect an offline MCP catalog",
    synopsis: &[
        "mcp list --library <directory>",
        "mcp show <id> --library <directory>",
        "mcp validate [id] --library <directory>",
        "mcp render <id>[@variant] --library <directory>",
        "mcp use <id>[@variant] --tool <slug> [--apply] --library <directory>",
    ],
    description: &[
        "Reads bounded JSON manifests from an explicit library or the configured\nlibrary.mcp.path. It never starts servers or contacts endpoints.",
        "list prints ID and title. show prints the original manifest bytes.\nvalidate checks one entry or the complete library, including all variants.\nrender prints one selected connection as AgentSync MCP source JSON.",
        "use previews a new per-tool source; --apply creates it without replacing\nan existing source. Run agentsync sync separately to update client files.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "--library <directory>",
                "Explicit catalog path, absolute or relative to the project root",
            ),
            (
                "--tool <slug>",
                "Enabled tool receiving a per-tool MCP source",
            ),
            ("--apply", "Create the source after previewing"),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &[
        "mcp list --library catalog/mcp",
        "mcp show microsoft-learn --library catalog/mcp",
        "mcp validate --library catalog/mcp",
        "mcp render microsoft-learn@recommended --library catalog/mcp",
        "mcp use microsoft-learn --tool claude --library catalog/mcp",
    ],
};

#[derive(Clone, Copy)]
enum Action {
    Help,
    List,
    Show,
    Validate,
    Render,
    Use,
}

struct Args {
    action: Action,
    id: Option<String>,
    variant: Option<String>,
    tool: Option<String>,
    apply: bool,
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
    let library = match library_path(&project, args.library.clone()) {
        Ok(path) => path,
        Err(message) => return refuse(style, &message, err),
    };
    if matches!(args.action, Action::Render | Action::Use) {
        let rendered = match mcp_catalog::render(
            &library,
            args.id.as_deref().expect("render requires an id"),
            args.variant.as_deref().unwrap_or("default"),
        ) {
            Ok(rendered) => rendered,
            Err(message) => return refuse(style, &message, err),
        };
        if matches!(args.action, Action::Use) {
            return use_source(&project, &args, &rendered, style, out, err);
        }
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
        Action::Help | Action::Render | Action::Use => unreachable!(),
    }
    Ok(0)
}

fn use_source(
    project: &Project,
    args: &Args,
    rendered: &[u8],
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let slug = args.tool.as_deref().expect("use requires a tool");
    let id = args.id.as_deref().expect("use requires an id");
    let variant = args.variant.as_deref().unwrap_or("default");
    if !project.tools_dir_in_project() {
        return refuse(style, "source.tools resolves outside the project root", err);
    }
    if !project.enabled_tools()?.contains(slug) {
        return refuse(style, "MCP target tool is not enabled in this project", err);
    }
    let tool = Tool::load(project, slug)?;
    if tool.value("targets.mcp.dest").is_empty() {
        return refuse(style, "MCP target tool has no MCP destination", err);
    }
    let format = tool.value("targets.mcp.format");
    if !matches!(
        format.as_str(),
        "" | "opencode_json" | "kimi_json" | "codex_toml"
    ) {
        return refuse(style, "MCP target tool uses an unsupported MCP format", err);
    }
    let rendered = if format == "kimi_json" {
        mcp_catalog::render_kimi_source(rendered, id)
    } else {
        rendered.to_vec()
    };
    let root = backup::canonical_root(&paths::from_disk(&project.root))?;
    let intended = project.user_tools_dir().join(slug).join("mcp.json");
    let disk_paths = paths::Paths::on_disk(&paths::from_disk(&project.root));
    let Some(resolved) =
        disk_paths.canonicalize_with_existing_ancestor(&paths::from_disk(&intended))
    else {
        return refuse(style, "Cannot resolve per-tool MCP source path", err);
    };
    let Some(rel) = resolved.strip_prefix(&format!("{root}/")) else {
        return refuse(
            style,
            "Per-tool MCP source resolves outside the project root",
            err,
        );
    };
    let rel = rel.to_string();
    let dest = PathBuf::from(backup::safe_target_path(&root, &rel, false)?);
    let override_dir = project.user_tools_dir().join(slug);
    let entries = match std::fs::read_dir(&override_dir) {
        Ok(entries) => Some(entries),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) if error.kind() == std::io::ErrorKind::NotADirectory => {
            return refuse(style, "Per-tool MCP source parent is not a directory", err);
        }
        Err(error) => return Err(Error::io(&override_dir, error)),
    };
    if let Some(entries) = entries {
        for entry in entries {
            let entry = entry.map_err(|e| Error::io(&override_dir, e))?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                return refuse(
                    style,
                    "Per-tool source directory has a non-UTF-8 entry",
                    err,
                );
            };
            if name.starts_with("mcp.") {
                return refuse(
                    style,
                    "Per-tool MCP source is already occupied or ambiguous",
                    err,
                );
            }
        }
    }
    if matches!(
        payload::effective_source(project, &tool, "mcp")?.0,
        Some(payload::Source::Disk(_))
    ) {
        return refuse(style, "An MCP source already exists for this tool", err);
    }
    if std::fs::symlink_metadata(&dest).is_ok() {
        return refuse(style, "Per-tool MCP source is already occupied", err);
    }
    let selection = format!("{id}@{variant}");
    if !args.apply {
        put(
            out,
            format!("Would create {rel} from {selection} for {slug}:\n").as_bytes(),
        )?;
        put(out, &rendered)?;
        put(out, b"Run with --apply to write it.\n")?;
        return Ok(0);
    }
    let config = project
        .config_path
        .as_ref()
        .map(|path| std::fs::read_to_string(path).map(|text| (path.clone(), text)))
        .transpose()
        .map_err(|e| Error::io(project.config_path.as_ref().expect("config path exists"), e))?;
    let limit = std::env::var("AGENTSYNC_BACKUP_LIMIT").ok();
    let age = std::env::var("AGENTSYNC_BACKUP_MAX_AGE_DAYS").ok();
    let retention = backup::configure(
        config
            .as_ref()
            .map(|(path, text)| (path.to_str().unwrap_or("<config>"), text.as_str())),
        limit.as_deref(),
        age.as_deref(),
    )?;
    let previous_latest =
        backup::latest(&root)?.map_or_else(String::new, |path| paths::leaf(&path));
    let snapshot = backup::create(&root, "mcp-use", &[resolved], retention)?;
    let written = (|| {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        staging::write_new_beside(&dest, &rendered)
    })();
    if let Err(error) = written {
        let store = format!("{root}/.ai/backups");
        if let Err(cleanup) = backup::discard_safety(&store, &snapshot, &previous_latest) {
            return refuse(
                style,
                &format!("Could not create MCP source: {error}; backup cleanup failed: {cleanup}"),
                err,
            );
        }
        return refuse(style, &format!("Could not create MCP source: {error}"), err);
    }
    if let Err(reason) = witness::seal(&root, &snapshot) {
        put(
            err,
            format!("Warning: Could not record MCP source backup state: {reason}\n").as_bytes(),
        )?;
    }
    if let Err(error) = backup::prune(&root, limit.as_deref(), age.as_deref(), retention) {
        put(
            err,
            format!("Warning: Could not prune backups: {error}\n").as_bytes(),
        )?;
    }
    put(out, format!("Created {rel} from {selection} for {slug}\nReview the source, then run agentsync sync to update client files.\n").as_bytes())?;
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
        Some("use") => Action::Use,
        _ => {
            return Err(
                "Usage: agentsync mcp <list|show|validate|render|use> [options]".to_string(),
            );
        }
    };
    let mut library = None;
    let mut id = None;
    let mut variant = None;
    let mut tool = None;
    let mut apply = false;
    let mut index = 1;
    while let Some(arg) = args.get(index) {
        match arg.as_str() {
            "-h" | "--help" => {
                return Ok(Args {
                    action: Action::Help,
                    id: None,
                    variant: None,
                    tool: None,
                    apply: false,
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
            "--tool" if matches!(action, Action::Use) => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| "--tool requires a slug".to_string())?;
                if !mcp_catalog::valid_id(value) || tool.replace(value.to_string()).is_some() {
                    return Err("--tool requires one valid tool slug".to_string());
                }
                index += 2;
            }
            "--apply" if matches!(action, Action::Use) && !apply => {
                apply = true;
                index += 1;
            }
            flag if flag.starts_with('-') => {
                return Err(format!(
                    "Unknown MCP option: {}",
                    mcp_catalog::escaped_title(flag)
                ));
            }
            value if !matches!(action, Action::List) && id.is_none() => {
                let (entry_id, selected_variant) = if matches!(action, Action::Render | Action::Use)
                {
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
    if matches!(action, Action::Show | Action::Render | Action::Use) && id.is_none() {
        return Err(if matches!(action, Action::Show) {
            "mcp show requires an id"
        } else if matches!(action, Action::Use) {
            "mcp use requires an id"
        } else {
            "mcp render requires an id"
        }
        .to_string());
    }
    if matches!(action, Action::Use) && tool.is_none() {
        return Err("mcp use requires --tool <slug>".to_string());
    }
    Ok(Args {
        action,
        id,
        variant,
        tool,
        apply,
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
