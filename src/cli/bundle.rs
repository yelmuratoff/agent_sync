//! `agentsync export` and `agentsync import`: `cmd_export` of
//! `lib/helpers/export.sh` and `cmd_import` of `lib/helpers/import.sh`, which
//! bundle a project's sources into a `tar.gz` and bring a bundle, a directory,
//! or a GitHub archive back in. Archives go through the `tar` and `curl`
//! executables, as Bash ran them.

use crate::paths::DiskText;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::{files_below, put};
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::{Error, config::yaml_subset};

/// `_BUNDLE_DIR_TARGETS`, in the order `init` creates them.
const DIR_TARGETS: [&str; 8] = [
    "rules", "skills", "commands", "agents", "settings", "mcp", "hooks", "tools",
];
const CONFIG: &str = ".ai/agent_sync.yaml";
const CONFIG_LEGACY: &str = "agent_sync.yaml";

/// What `import` takes from the process.
pub struct Env<'a> {
    /// The logical working directory a relative source is shown against.
    pub cwd: String,
    /// `[[ -t 0 ]]`: the confirmation is asked only when stdin is a terminal.
    pub interactive: bool,
    /// `PATH`, for the `command -v curl` check.
    pub path: Option<String>,
    /// `read -r answer` on stdin.
    pub read_line: &'a mut dyn FnMut() -> String,
}

/// `_resolve_source_paths`: the detected base and every source path, each
/// relative to the project root or as the config spelled it.
#[derive(Debug, Default, PartialEq)]
struct Sources {
    base: String,
    agents: String,
    dirs: Vec<(&'static str, String)>,
}

fn resolve_sources(root: &str) -> Sources {
    let mut config = format!("{root}/{CONFIG}");
    if !Path::new(&config).is_file() {
        config = format!("{root}/{CONFIG_LEGACY}");
    }
    let base = if Path::new(root).join(".ai/src").is_dir() {
        ".ai/src"
    } else if Path::new(root).join(".ai").is_dir() {
        ".ai"
    } else {
        ""
    };
    let mut sources = Sources {
        base: base.to_string(),
        ..Sources::default()
    };
    if !base.is_empty() && Path::new(root).join(base).join("AGENTS.md").is_file() {
        sources.agents = format!("{base}/AGENTS.md");
    }
    sources.dirs = DIR_TARGETS
        .iter()
        .map(|name| {
            let path = if !base.is_empty() && Path::new(root).join(base).join(name).is_dir() {
                format!("{base}/{name}")
            } else {
                String::new()
            };
            (*name, path)
        })
        .collect();
    if let Ok(bytes) = std::fs::read(&config) {
        let text = String::from_utf8_lossy(&bytes);
        let override_of = |key: &str| yaml_subset::value(&text, key);
        let agents = override_of("source.agents");
        if !agents.is_empty() {
            sources.agents = agents;
        }
        for (name, key) in [
            ("rules", "source.rules"),
            ("skills", "source.skills"),
            ("commands", "source.commands"),
            ("agents", "source.subagents"),
            ("tools", "source.tools"),
        ] {
            let value = override_of(key);
            if !value.is_empty()
                && let Some(entry) = sources.dirs.iter_mut().find(|(n, _)| *n == name)
            {
                entry.1 = value;
            }
        }
    }
    sources
}

fn count_files(dir: &Path) -> usize {
    let mut files = Vec::new();
    files_below(dir, &mut files);
    files.len()
}

pub const EXPORT_HELP: Help = Help {
    command: "export",
    tagline: "bundle source files into a shareable archive",
    synopsis: &["export [OPTIONS]"],
    description: &[],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            (
                "-o, --output <path>",
                "Output file path (default: ./agentsync-bundle.tar.gz)",
            ),
            ("--dry-run", "Preview what would be exported"),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &["export", "export -o my-config.tar.gz", "export --dry-run"],
};

/// `stat -f%z` rendered as `cmd_export` prints it.
fn human_size(size: Option<u64>) -> String {
    match size {
        Some(size) if size >= 1_048_576 => format!("{} MB", size / 1_048_576),
        Some(size) if size >= 1024 => format!("{} KB", size / 1024),
        Some(size) => format!("{size} B"),
        None => "? B".to_string(),
    }
}

/// `cmd_export`.
pub fn export(
    args: &[String],
    root: &str,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut output = String::new();
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--output" | "-o" => {
                let Some(value) = args.get(i + 1) else {
                    put(
                        err,
                        format!("{}: --output requires a path\n", style.red("Error")).as_bytes(),
                    )?;
                    return Ok(1);
                };
                output = value.clone();
                i += 2;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--help" | "-h" => {
                put(out, EXPORT_HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            other => {
                put(
                    err,
                    format!("{}: Unknown option: {other}\n", style.red("Error")).as_bytes(),
                )?;
                put(err, EXPORT_HELP.render(style).as_bytes())?;
                return Ok(1);
            }
        }
    }
    let sources = resolve_sources(root);
    if sources.base.is_empty() {
        put(
            err,
            format!(
                "{}: No .ai/ directory found in {root}\nRun {} first.\n",
                style.red("Error"),
                style.cyan("agentsync init")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    if output.is_empty() {
        output = format!("{root}/agentsync-bundle.tar.gz");
    }
    put(
        out,
        format!("\n{}\n\n", style.bold("  AgentSync Export")).as_bytes(),
    )?;

    let mut items: Vec<String> = Vec::new();
    let mut labels: Vec<String> = Vec::new();
    if !sources.agents.is_empty() && Path::new(root).join(&sources.agents).is_file() {
        items.push(sources.agents.clone());
        labels.push(
            sources
                .agents
                .rsplit('/')
                .next()
                .unwrap_or(&sources.agents)
                .to_string(),
        );
    }
    for (name, path) in &sources.dirs {
        if path.is_empty() {
            continue;
        }
        let dir = Path::new(root).join(path);
        if !dir.is_dir() {
            continue;
        }
        let count = count_files(&dir);
        if count > 0 {
            items.push(path.clone());
            labels.push(format!("{name}/ ({count} files)"));
        }
    }
    if Path::new(root).join(CONFIG).is_file() {
        items.push(CONFIG.to_string());
        labels.push("agent_sync.yaml".to_string());
    } else if Path::new(root).join(CONFIG_LEGACY).is_file() {
        items.push(CONFIG_LEGACY.to_string());
        labels.push(format!("agent_sync.yaml {}", style.dim("(legacy)")));
    }
    if items.is_empty() {
        put(
            out,
            format!(
                "  {} — source directories are empty.\n\n",
                style.yellow("Nothing to export")
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }
    let mut text = format!("  {}\n", style.green("Contents:"));
    for label in &labels {
        text.push_str(&format!("    {} {label}\n", style.dim("•")));
    }
    text.push('\n');
    if dry_run {
        text.push_str(&format!(
            "  {} — no files written.\n  Would create: {}\n\n",
            style.yellow("Dry run"),
            style.cyan(&output)
        ));
        put(out, text.as_bytes())?;
        return Ok(0);
    }
    put(out, text.as_bytes())?;
    out.flush().map_err(|e| Error::io("<stdout>", e))?;
    let status = Command::new("tar")
        .arg("-czf")
        .arg(&output)
        .args(&items)
        .current_dir(root)
        .stdin(Stdio::null())
        .status();
    if !status.map(|s| s.success()).unwrap_or(false) {
        put(
            err,
            format!("  {}: Failed to create archive.\n", style.red("Error")).as_bytes(),
        )?;
        return Ok(1);
    }
    let archive = if crate::paths::is_absolute(&output) {
        PathBuf::from(&output)
    } else {
        Path::new(root).join(&output)
    };
    let size = std::fs::metadata(&archive).ok().map(|m| m.len());
    let base_name = output.rsplit('/').next().unwrap_or(&output).to_string();
    put(
        out,
        format!(
            "  {} → {} ({})\n\n  Share this file and import with:\n    {} {}\n\n",
            style.green("Exported!"),
            style.cyan(&output),
            human_size(size),
            style.cyan("agentsync import"),
            style.dim(&base_name)
        )
        .as_bytes(),
    )
    .map(|()| 0)
}

pub const IMPORT_HELP: Help = Help {
    command: "import",
    tagline: "import config from GitHub, archive, or directory",
    synopsis: &["import <source> [OPTIONS]"],
    description: &[],
    sections: &[
        Section {
            title: "SOURCES",
            entries: &[
                ("GitHub URL", "https://github.com/user/repo"),
                ("Archive file", "path/to/agentsync-bundle.tar.gz"),
                ("Local directory", "path/to/project/"),
            ],
        },
        Section {
            title: "OPTIONS",
            entries: &[
                (
                    "-b, --branch <name>",
                    "Git branch to download (default: main)",
                ),
                (
                    "--only <targets>",
                    "Import only specific targets (comma-separated)\nTargets: rules,skills,commands,agents,settings,mcp,hooks,tools",
                ),
                ("--force", "Overwrite without confirmation"),
                ("--dry-run", "Preview changes without writing"),
                ("-h, --help", "Show this help"),
            ],
        },
    ],
    examples: &[
        "import https://github.com/user/repo",
        "import https://github.com/user/repo/tree/develop",
        "import agentsync-bundle.tar.gz",
        "import ../other-project/",
        "import https://github.com/user/repo --only rules,skills",
        "import bundle.tar.gz --dry-run",
    ],
};

/// `_import_is_github_url`: `^https?://(www\.)?github\.com/[^/]+/[^/]+`.
fn github_segments(source: &str) -> Option<(&str, &str)> {
    let rest = source
        .strip_prefix("https://")
        .or_else(|| source.strip_prefix("http://"))?;
    let rest = rest.strip_prefix("www.").unwrap_or(rest);
    let rest = rest.strip_prefix("github.com/")?;
    let (owner, rest) = rest.split_once('/')?;
    let repo = rest.split('/').next().unwrap_or("");
    (!owner.is_empty() && !repo.is_empty()).then_some((owner, repo))
}

/// A scratch directory under the system temp dir, removed on drop as the run
/// directory was.
pub(crate) struct Scratch(pub(crate) PathBuf);

impl Scratch {
    pub(crate) fn create(prefix: &str) -> Result<Self, Error> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("{prefix}.{}.{nanos}", std::process::id()));
        std::fs::create_dir_all(&dir).map_err(|e| Error::io(&dir, e))?;
        Ok(Self(dir))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `cp -R <src>/. <dest>/`: every entry below `src`, directories made as met.
fn copy_tree(src: &Path, dest: &Path) -> Result<(), Error> {
    std::fs::create_dir_all(dest).map_err(|e| Error::io(dest, e))?;
    let entries = std::fs::read_dir(src).map_err(|e| Error::io(src, e))?;
    for entry in entries.filter_map(|e| e.ok()) {
        let from = entry.path();
        let to = dest.join(entry.file_name());
        let meta = std::fs::symlink_metadata(&from).map_err(|e| Error::io(&from, e))?;
        if meta.is_dir() {
            copy_tree(&from, &to)?;
        } else if meta.is_file() {
            std::fs::copy(&from, &to).map_err(|e| Error::io(&from, e))?;
        }
    }
    Ok(())
}

/// `tar -xzf <archive> -C <dir>`, tar's own diagnostics passing through.
fn extract(archive: &Path, into: &Path) -> bool {
    Command::new("tar")
        .arg("-xzf")
        .arg(archive)
        .arg("-C")
        .arg(into)
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// `curl -sfL --max-time 30 -o <file> <url>`, silenced as Bash silenced it.
fn download(url: &str, to: &Path) -> bool {
    Command::new("curl")
        .args(["-sfL", "--max-time", "30", "-o"])
        .arg(to)
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn curl_on_path(path: Option<&str>) -> bool {
    path.is_some_and(|path| std::env::split_paths(path).any(|dir| dir.join("curl").is_file()))
}

/// `_import_find_ai_src`: `.ai/src` over `.ai`, directly or one level down.
fn find_ai_src(search_root: &Path) -> Option<PathBuf> {
    let direct = |dir: &Path| -> Option<PathBuf> {
        let src = dir.join(".ai/src");
        if src.is_dir() {
            return Some(src);
        }
        let ai = dir.join(".ai");
        ai.is_dir().then_some(ai)
    };
    if let Some(found) = direct(search_root) {
        return Some(found);
    }
    let mut names: Vec<String> = std::fs::read_dir(search_root)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().disk_text())
        .filter(|name| !name.starts_with('.'))
        .collect();
    names.sort();
    names
        .into_iter()
        .find_map(|name| direct(&search_root.join(name)))
}

fn same_bytes(a: &Path, b: &Path) -> bool {
    match (std::fs::read(a), std::fs::read(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// `cp <src> <dest>`: an existing destination keeps its mode, a new one takes
/// the source's.
fn copy_file(src: &Path, dest: &Path) -> Result<(), Error> {
    if dest.is_file() {
        let bytes = std::fs::read(src).map_err(|e| Error::io(src, e))?;
        std::fs::write(dest, bytes).map_err(|e| Error::io(dest, e))
    } else {
        std::fs::copy(src, dest)
            .map(|_| ())
            .map_err(|e| Error::io(src, e))
    }
}

enum Change {
    New(String),
    Update(String),
    Dir(String),
}

#[derive(Default)]
struct Counts {
    new: usize,
    updated: usize,
    skipped: usize,
}

/// `_import_diff_file`.
fn diff_file(src: &Path, dest: &Path, label: &str, changes: &mut Vec<Change>, counts: &mut Counts) {
    if dest.is_file() {
        if same_bytes(src, dest) {
            counts.skipped += 1;
        } else {
            changes.push(Change::Update(label.to_string()));
            counts.updated += 1;
        }
    } else {
        changes.push(Change::New(label.to_string()));
        counts.new += 1;
    }
}

/// `_import_diff_dir`.
fn diff_dir(src: &Path, dest: &Path, label: &str, changes: &mut Vec<Change>, counts: &mut Counts) {
    let (mut new, mut updated, mut skipped) = (0usize, 0usize, 0usize);
    let mut files = Vec::new();
    files_below(src, &mut files);
    for file in files {
        let rel = file.strip_prefix(src).unwrap_or(&file);
        let target = dest.join(rel);
        if target.is_file() {
            if same_bytes(&file, &target) {
                skipped += 1;
            } else {
                updated += 1;
            }
        } else {
            new += 1;
        }
    }
    if new + updated > 0 {
        let mut detail = Vec::new();
        if new > 0 {
            detail.push(format!("{new} new"));
        }
        if updated > 0 {
            detail.push(format!("{updated} updated"));
        }
        if skipped > 0 {
            detail.push(format!("{skipped} unchanged"));
        }
        changes.push(Change::Dir(format!("{label} ({})", detail.join(", "))));
        counts.new += new;
        counts.updated += updated;
        counts.skipped += skipped;
    } else {
        counts.skipped += skipped;
    }
}

/// `--only`: the targets the comma list names, in target order; `AGENTS`
/// names `AGENTS.md`.
fn filter_targets(targets: &[&'static str], only: &str) -> Vec<&'static str> {
    let selected: Vec<&str> = only
        .split('\n')
        .next()
        .unwrap_or("")
        .split(',')
        .map(|item| {
            item.trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c'))
        })
        .collect();
    targets
        .iter()
        .copied()
        .filter(|target| {
            selected.iter().any(|item| {
                *target == *item || target.strip_suffix(".md").unwrap_or(target) == *item
            })
        })
        .collect()
}

/// `cmd_import`.
pub fn import(
    args: &[String],
    root: &str,
    style: &Style,
    env: &mut Env,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut source = String::new();
    let mut dry_run = false;
    let mut force = false;
    let mut only = String::new();
    let mut branch = String::new();
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--force" => {
                force = true;
                i += 1;
            }
            "--only" | "--branch" | "-b" => {
                let Some(value) = args.get(i + 1) else {
                    let flag = if arg == "--only" {
                        "--only"
                    } else {
                        "--branch"
                    };
                    put(
                        err,
                        format!("{}: {flag} requires a value\n", style.red("Error")).as_bytes(),
                    )?;
                    return Ok(1);
                };
                if arg == "--only" {
                    only = value.clone();
                } else {
                    branch = value.clone();
                }
                i += 2;
            }
            "--help" | "-h" => {
                put(out, IMPORT_HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            flag if flag.starts_with('-') => {
                put(
                    err,
                    format!("{}: Unknown option: {flag}\n", style.red("Error")).as_bytes(),
                )?;
                put(err, IMPORT_HELP.render(style).as_bytes())?;
                return Ok(1);
            }
            positional => {
                if source.is_empty() {
                    source = positional.to_string();
                } else {
                    put(
                        err,
                        format!(
                            "{}: Unexpected argument: {positional}\n",
                            style.red("Error")
                        )
                        .as_bytes(),
                    )?;
                    return Ok(1);
                }
                i += 1;
            }
        }
    }
    if source.is_empty() {
        put(
            err,
            format!("{}: No source specified.\n", style.red("Error")).as_bytes(),
        )?;
        put(err, IMPORT_HELP.render(style).as_bytes())?;
        return Ok(1);
    }
    put(
        out,
        format!("\n{}\n\n", style.bold("  AgentSync Import")).as_bytes(),
    )?;
    out.flush().map_err(|e| Error::io("<stdout>", e))?;
    let scratch = Scratch::create("agentsync-import")?;
    let tmp = scratch.0.as_path();
    let error = style.red("Error");

    let label;
    if let Some((owner, repo)) = github_segments(&source) {
        label = format!("GitHub: {source}");
        if !curl_on_path(env.path.as_deref()) {
            put(
                err,
                format!("  {error}: curl is required for GitHub import.\n").as_bytes(),
            )?;
            return Ok(1);
        }
        let url = source.strip_suffix(".git").unwrap_or(&source);
        let url = url.strip_suffix('/').unwrap_or(url);
        let (owner, repo) = github_segments(url).unwrap_or((owner, repo));
        let repo_path = format!("{owner}/{repo}");
        if branch.is_empty()
            && let Some((_, after)) = url.split_once("/tree/")
        {
            branch = after.split('/').next().unwrap_or("").to_string();
        }
        if branch.is_empty() {
            branch = "main".to_string();
        }
        put(
            out,
            format!(
                "  Downloading {} (branch: {branch})...\n",
                style.cyan(&repo_path)
            )
            .as_bytes(),
        )?;
        out.flush().map_err(|e| Error::io("<stdout>", e))?;
        let archive = tmp.join("repo.tar.gz");
        let archive_url = |branch: &str| {
            format!("https://github.com/{repo_path}/archive/refs/heads/{branch}.tar.gz")
        };
        if !download(&archive_url(&branch), &archive) {
            if branch == "main" {
                put(
                    out,
                    format!(
                        "  {}\n",
                        style.dim("Branch 'main' not found, trying 'master'...")
                    )
                    .as_bytes(),
                )?;
                out.flush().map_err(|e| Error::io("<stdout>", e))?;
                branch = "master".to_string();
                if !download(&archive_url(&branch), &archive) {
                    put(
                        err,
                        format!(
                            "  {error}: Failed to download repository.\n  Check the URL and your network connection.\n"
                        )
                        .as_bytes(),
                    )?;
                    return Ok(1);
                }
            } else {
                put(
                    err,
                    format!("  {error}: Failed to download branch '{branch}'.\n").as_bytes(),
                )?;
                return Ok(1);
            }
        }
        if !extract(&archive, tmp) {
            put(
                err,
                format!("  {error}: Failed to extract archive.\n").as_bytes(),
            )?;
            return Ok(1);
        }
        put(
            out,
            format!("  {}\n", style.green("Downloaded.")).as_bytes(),
        )?;
    } else if Path::new(&source).is_file()
        && (source.ends_with(".tar.gz") || source.ends_with(".tgz"))
    {
        let base_name = source.rsplit('/').next().unwrap_or(&source).to_string();
        label = format!("Archive: {base_name}");
        put(
            out,
            format!("  Extracting {}...\n", style.cyan(&base_name)).as_bytes(),
        )?;
        out.flush().map_err(|e| Error::io("<stdout>", e))?;
        if !extract(Path::new(&source), tmp) {
            put(
                err,
                format!("  {error}: Failed to extract archive.\n").as_bytes(),
            )?;
            return Ok(1);
        }
        put(out, format!("  {}\n", style.green("Extracted.")).as_bytes())?;
    } else if Path::new(&source).is_dir() {
        label = format!("Directory: {source}");
        let Ok(canonical) = std::fs::canonicalize(&source) else {
            put(
                err,
                format!("  {error}: Cannot access directory: {source}\n").as_bytes(),
            )?;
            return Ok(1);
        };
        let shown = crate::paths::normalize(&if crate::paths::is_absolute(&source) {
            source.clone()
        } else {
            format!("{}/{source}", env.cwd)
        });
        let shown = if std::fs::canonicalize(&shown).ok().as_deref() == Some(canonical.as_path()) {
            shown
        } else {
            canonical.disk_text()
        };
        put(
            out,
            format!("  Reading from {}...\n", style.cyan(&shown)).as_bytes(),
        )?;
        let src_dir = Path::new(&shown);
        if src_dir.join(".ai").is_dir() {
            copy_tree(&src_dir.join(".ai"), &tmp.join(".ai"))?;
        }
        if !tmp.join(CONFIG).is_file() && src_dir.join(CONFIG_LEGACY).is_file() {
            std::fs::create_dir_all(tmp.join(".ai")).map_err(|e| Error::io(tmp, e))?;
            std::fs::copy(src_dir.join(CONFIG_LEGACY), tmp.join(CONFIG))
                .map_err(|e| Error::io(src_dir.join(CONFIG_LEGACY), e))?;
        }
    } else {
        put(
            err,
            format!(
                "  {error}: Cannot recognize source: {source}\n  Expected: GitHub URL, .tar.gz file, or directory path.\n"
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    put(
        out,
        format!("  {} {label}\n\n", style.dim("Source:")).as_bytes(),
    )?;

    let Some(src_root) = find_ai_src(tmp) else {
        put(
            err,
            format!(
                "  {error}: No .ai/src/ (or .ai/) directory found in source.\n  The source must contain a structure created by {}.\n",
                style.cyan("agentsync init")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    };
    let src_project_root = if src_root.ends_with("src") {
        src_root
            .parent()
            .and_then(Path::parent)
            .map(Path::to_path_buf)
    } else {
        src_root.parent().map(Path::to_path_buf)
    }
    .unwrap_or_else(|| tmp.to_path_buf());
    let imported_config = [CONFIG, CONFIG_LEGACY]
        .iter()
        .map(|rel| src_project_root.join(rel))
        .find(|path| path.is_file());

    let local = resolve_sources(root);
    let dest_base_rel = if local.base.is_empty() {
        ".ai/src".to_string()
    } else {
        local.base.clone()
    };
    let dest_base = Path::new(root).join(&dest_base_rel);

    let mut targets: Vec<&'static str> = vec!["AGENTS.md"];
    targets.extend(DIR_TARGETS);
    if !only.is_empty() {
        targets = filter_targets(&targets, &only);
    }

    let mut changes = Vec::new();
    let mut counts = Counts::default();
    for target in &targets {
        let src_path = src_root.join(target);
        let dest_path = dest_base.join(target);
        if src_path.is_file() {
            diff_file(&src_path, &dest_path, target, &mut changes, &mut counts);
        } else if src_path.is_dir() {
            diff_dir(&src_path, &dest_path, target, &mut changes, &mut counts);
        }
    }
    let config_dest = Path::new(root).join(CONFIG);
    let mut config_action = "";
    if let Some(imported) = &imported_config {
        if config_dest.is_file() {
            if !same_bytes(imported, &config_dest) {
                config_action = "update";
                counts.updated += 1;
            }
        } else {
            config_action = "new";
            counts.new += 1;
        }
    }
    if changes.is_empty() && config_action.is_empty() {
        put(
            out,
            format!(
                "  {} Nothing to import.\n\n",
                style.green("Already up to date!")
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }

    let mut text = format!("  {}\n", style.green("Changes:"));
    for change in &changes {
        match change {
            Change::New(name) => text.push_str(&format!(
                "    {} {name} {}\n",
                style.green("+"),
                style.dim("(new)")
            )),
            Change::Update(name) => text.push_str(&format!(
                "    {} {name} {}\n",
                style.yellow("~"),
                style.dim("(update)")
            )),
            Change::Dir(name) => text.push_str(&format!("    {} {name}\n", style.cyan("↳"))),
        }
    }
    if config_action == "new" {
        text.push_str(&format!(
            "    {} agent_sync.yaml {}\n",
            style.green("+"),
            style.dim("(new)")
        ));
    }
    if config_action == "update" {
        text.push_str(&format!(
            "    {} agent_sync.yaml {}\n",
            style.yellow("~"),
            style.dim("(update)")
        ));
    }
    text.push_str(&format!(
        "\n  {} {} new, {} updated, {} unchanged\n\n",
        style.dim("Summary:"),
        counts.new,
        counts.updated,
        counts.skipped
    ));
    if dry_run {
        text.push_str(&format!(
            "  {} — no files written.\n\n",
            style.yellow("Dry run")
        ));
        put(out, text.as_bytes())?;
        return Ok(0);
    }
    put(out, text.as_bytes())?;

    if !force && counts.updated > 0 && env.interactive {
        put(out, b"  Proceed? [Y/n] ")?;
        out.flush().map_err(|e| Error::io("<stdout>", e))?;
        let answer = (env.read_line)();
        if answer.starts_with(['N', 'n']) {
            put(out, b"  Cancelled.\n\n")?;
            return Ok(0);
        }
    }

    std::fs::create_dir_all(&dest_base).map_err(|e| Error::io(&dest_base, e))?;
    for target in &targets {
        let src_path = src_root.join(target);
        let dest_path = dest_base.join(target);
        if src_path.is_file() {
            copy_file(&src_path, &dest_path)?;
        } else if src_path.is_dir() {
            std::fs::create_dir_all(&dest_path).map_err(|e| Error::io(&dest_path, e))?;
            let mut files = Vec::new();
            files_below(&src_path, &mut files);
            for file in files {
                let rel = file.strip_prefix(&src_path).unwrap_or(&file);
                let dest_file = dest_path.join(rel);
                if let Some(parent) = dest_file.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
                }
                copy_file(&file, &dest_file)?;
            }
        }
    }
    if !config_action.is_empty()
        && let Some(imported) = &imported_config
    {
        if let Some(parent) = config_dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        copy_file(imported, &config_dest)?;
    }
    put(
        out,
        format!(
            "  {} {} new, {} updated files.\n\n  Next steps:\n    1. Review imported files in {}\n    2. Run {} to distribute to all tools\n\n",
            style.green("Imported!"),
            counts.new,
            counts.updated,
            style.cyan(&dest_base_rel),
            style.cyan("agentsync sync")
        )
        .as_bytes(),
    )
    .map(|()| 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn export_help_has_the_shared_shape() {
        assert_eq!(
            EXPORT_HELP.render(&Style::plain()),
            "\n  agentsync export — bundle source files into a shareable archive\n\n  USAGE\n    agentsync export [OPTIONS]\n\n  OPTIONS\n    -o, --output <path>   Output file path (default: ./agentsync-bundle.tar.gz)\n    --dry-run             Preview what would be exported\n    -h, --help            Show this help\n\n  EXAMPLES\n    agentsync export\n    agentsync export -o my-config.tar.gz\n    agentsync export --dry-run\n\n"
        );
    }

    #[test]
    fn import_help_has_the_shared_shape() {
        assert_eq!(
            IMPORT_HELP.render(&Style::plain()),
            "\n  agentsync import — import config from GitHub, archive, or directory\n\n  USAGE\n    agentsync import <source> [OPTIONS]\n\n  SOURCES\n    GitHub URL        https://github.com/user/repo\n    Archive file      path/to/agentsync-bundle.tar.gz\n    Local directory   path/to/project/\n\n  OPTIONS\n    -b, --branch <name>   Git branch to download (default: main)\n    --only <targets>      Import only specific targets (comma-separated)\n                          Targets: rules,skills,commands,agents,settings,mcp,hooks,tools\n    --force               Overwrite without confirmation\n    --dry-run             Preview changes without writing\n    -h, --help            Show this help\n\n  EXAMPLES\n    agentsync import https://github.com/user/repo\n    agentsync import https://github.com/user/repo/tree/develop\n    agentsync import agentsync-bundle.tar.gz\n    agentsync import ../other-project/\n    agentsync import https://github.com/user/repo --only rules,skills\n    agentsync import bundle.tar.gz --dry-run\n\n"
        );
    }

    #[test]
    fn only_filters_the_targets_in_target_order() {
        let targets: Vec<&'static str> = {
            let mut all = vec!["AGENTS.md"];
            all.extend(DIR_TARGETS);
            all
        };
        assert_eq!(
            filter_targets(&targets, " AGENTS , bogus "),
            vec!["AGENTS.md"]
        );
        assert_eq!(
            filter_targets(&targets, "skills,rules"),
            vec!["rules", "skills"]
        );
        assert_eq!(
            filter_targets(&targets, "AGENTS.md,tools"),
            vec!["AGENTS.md", "tools"]
        );
        assert!(filter_targets(&targets, "nothing").is_empty());
    }

    #[test]
    fn github_urls_are_recognised_like_import_is_github_url() {
        assert_eq!(
            github_segments("https://github.com/user/repo"),
            Some(("user", "repo"))
        );
        assert_eq!(
            github_segments("https://www.github.com/user/repo/tree/x"),
            Some(("user", "repo"))
        );
        assert_eq!(
            github_segments("http://github.com/a/b.git"),
            Some(("a", "b.git"))
        );
        assert_eq!(github_segments("https://github.com/user"), None);
        assert_eq!(github_segments("https://gitlab.com/a/b"), None);
        assert_eq!(github_segments("bundle.tar.gz"), None);
    }

    #[test]
    fn sizes_read_like_the_exported_line() {
        assert_eq!(human_size(Some(543)), "543 B");
        assert_eq!(human_size(Some(46_000)), "44 KB");
        assert_eq!(human_size(Some(2_000_000)), "1 MB");
        assert_eq!(human_size(None), "? B");
    }

    #[cfg(unix)]
    fn write(root: &Path, rel: &str, text: &str) {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    /// The four-file project of `tiny_probe.sh`.
    #[cfg(unix)]
    fn tiny_project() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        write(dir.path(), ".ai/src/AGENTS.md", "# Agents\n");
        write(dir.path(), ".ai/src/rules/a.md", "# A rule\n");
        write(dir.path(), ".ai/src/skills/x/SKILL.md", "# Skill\n");
        write(dir.path(), "custom/cmds/c.md", "# Command\n");
        write(
            dir.path(),
            ".ai/agent_sync.yaml",
            "source:\n  commands: custom/cmds\n",
        );
        (dir, root)
    }

    #[cfg(unix)]
    #[test]
    fn sources_are_resolved_like_resolve_source_paths() {
        let (dir, root) = tiny_project();
        let sources = resolve_sources(&root);
        assert_eq!(sources.base, ".ai/src");
        assert_eq!(sources.agents, ".ai/src/AGENTS.md");
        assert_eq!(
            sources.dirs,
            vec![
                ("rules", ".ai/src/rules".to_string()),
                ("skills", ".ai/src/skills".to_string()),
                ("commands", "custom/cmds".to_string()),
                ("agents", String::new()),
                ("settings", String::new()),
                ("mcp", String::new()),
                ("hooks", String::new()),
                ("tools", String::new()),
            ]
        );
        let legacy = tempfile::tempdir().unwrap();
        write(legacy.path(), ".ai/AGENTS.md", "# Old\n");
        write(legacy.path(), ".ai/rules/r.md", "# R\n");
        let sources = resolve_sources(&legacy.path().disk_text());
        assert_eq!(sources.base, ".ai");
        assert_eq!(sources.agents, ".ai/AGENTS.md");
        assert_eq!(sources.dirs[0], ("rules", ".ai/rules".to_string()));
        assert_eq!(
            resolve_sources(&dir.path().join("custom").disk_text()).base,
            ""
        );
    }

    #[cfg(unix)]
    fn run_export(root: &str, args: &[&str]) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = export(&args, root, &Style::plain(), &mut out, &mut err).unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[cfg(unix)]
    fn run_import(root: &str, args: &[&str]) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut read_line = || String::new();
        let mut env = Env {
            cwd: root.to_string(),
            interactive: false,
            path: None,
            read_line: &mut read_line,
        };
        let status = import(&args, root, &Style::plain(), &mut env, &mut out, &mut err).unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[cfg(unix)]
    #[test]
    fn a_dry_run_export_lists_the_sources_like_cmd_export() {
        let (_dir, root) = tiny_project();
        let (status, out, err) = run_export(&root, &["--dry-run"]);
        assert_eq!((status, err.as_str()), (0, ""));
        assert_eq!(
            out,
            format!(
                "\n  AgentSync Export\n\n  Contents:\n    • AGENTS.md\n    • rules/ (1 files)\n    • skills/ (1 files)\n    • commands/ (1 files)\n    • agent_sync.yaml\n\n  Dry run — no files written.\n  Would create: {root}/agentsync-bundle.tar.gz\n\n"
            )
        );
        let (status, out, err) = run_export(&root, &["--bogus"]);
        assert_eq!((status, out.as_str()), (1, ""));
        assert_eq!(
            err,
            format!(
                "Error: Unknown option: --bogus\n{}",
                EXPORT_HELP.render(&Style::plain())
            )
        );
        let (status, _, err) = run_export(&root, &["-o"]);
        assert_eq!(
            (status, err.as_str()),
            (1, "Error: --output requires a path\n")
        );
        let empty = tempfile::tempdir().unwrap();
        let empty_root = empty.path().disk_text();
        let (status, _, err) = run_export(&empty_root, &[]);
        assert_eq!(status, 1);
        assert_eq!(
            err,
            format!("Error: No .ai/ directory found in {empty_root}\nRun agentsync init first.\n")
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_directory_import_copies_then_reports_up_to_date_like_cmd_import() {
        let (_source, source_root) = tiny_project();
        let target = tempfile::tempdir().unwrap();
        let target_root = std::fs::canonicalize(target.path()).unwrap().disk_text();
        let (status, out, err) = run_import(&target_root, &[&source_root]);
        assert_eq!((status, err.as_str()), (0, ""));
        assert_eq!(
            out,
            format!(
                "\n  AgentSync Import\n\n  Reading from {source_root}...\n  Source: Directory: {source_root}\n\n  Changes:\n    + AGENTS.md (new)\n    ↳ rules (1 new)\n    ↳ skills (1 new)\n    + agent_sync.yaml (new)\n\n  Summary: 4 new, 0 updated, 0 unchanged\n\n  Imported! 4 new, 0 updated files.\n\n  Next steps:\n    1. Review imported files in .ai/src\n    2. Run agentsync sync to distribute to all tools\n\n"
            )
        );
        assert_eq!(
            std::fs::read_to_string(target.path().join(".ai/src/skills/x/SKILL.md")).unwrap(),
            "# Skill\n"
        );
        assert!(!target.path().join(".ai/src/commands").exists());
        let (status, out, _) = run_import(&target_root, &[&source_root]);
        assert_eq!(status, 0);
        assert!(out.ends_with("  Source: Directory: {source_root}\n\n  Already up to date! Nothing to import.\n\n".replace("{source_root}", &source_root).as_str()));
        write(
            Path::new(&source_root),
            ".ai/src/rules/a.md",
            "# A rule, edited\n",
        );
        write(Path::new(&source_root), ".ai/src/rules/b.md", "# B\n");
        let (status, out, _) = run_import(
            &target_root,
            &[&source_root, "--only", "rules", "--dry-run"],
        );
        assert_eq!(status, 0);
        assert!(out.ends_with(
            "  Changes:\n    ↳ rules (1 new, 1 updated)\n\n  Summary: 1 new, 1 updated, 0 unchanged\n\n  Dry run — no files written.\n\n"
        ));
        let (status, out, err) = run_import(&target_root, &["nothing.txt"]);
        assert_eq!((status, out.as_str()), (1, "\n  AgentSync Import\n\n"));
        assert_eq!(
            err,
            "  Error: Cannot recognize source: nothing.txt\n  Expected: GitHub URL, .tar.gz file, or directory path.\n"
        );
    }
}
