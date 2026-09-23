use std::ffi::OsString;
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use agentsync::cli::{self, Command};
use agentsync::engine::render::Env;
use agentsync::output::log::{Sink, Stream};
use agentsync::output::style::Style;
use agentsync::project::Project;
use agentsync::{Error, engine_version, output::prompts, paths};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match run(args) {
        Ok(status) => ExitCode::from(status),
        Err(e) if e.is_broken_pipe() => ExitCode::SUCCESS,
        Err(e) => {
            // Bash decides colour from stdout even for stderr lines; same here.
            eprintln!("{}: {e}", Style::for_stdout().red("Error"));
            ExitCode::from(1)
        }
    }
}

fn run(args: Vec<OsString>) -> Result<u8, Error> {
    let first = args.first().and_then(|a| a.to_str()).unwrap_or("");
    if cli::notice::wants_notice(first) {
        check_for_updates()?;
    }
    let words: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    if cli::usage::wants_usage(&words) {
        return print_usage();
    }
    let Some(command) = Command::parse(first) else {
        let word = words.first().map(String::as_str).unwrap_or_default();
        return cli::usage::unknown_command(word, &Style::for_stdout(), &mut std::io::stderr());
    };
    let rest = &words[1..];
    let style = Style::for_stdout();
    match command {
        Command::Version => print_version(),
        Command::Skills => {
            let root = notice_root()?;
            let env = sync_env();
            cli::skills::run(
                rest,
                &root,
                &env.render,
                &style,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Mcp => cli::mcp::run(rest, &style, &mut std::io::stdout(), &mut std::io::stderr()),
        Command::Catalog => {
            let mut out = std::io::stdout().lock();
            out.write_all(cli::update::catalog_dump().as_bytes())
                .map(|()| 0)
                .map_err(|e| Error::io("<stdout>", e))
        }
        Command::UpdateCache => {
            if let Some(cache) = args.get(1) {
                cli::notice::refresh_cache(Path::new(cache));
            }
            Ok(0)
        }
        Command::Update => {
            let exe = current_exe().map_err(|e| Error::io("<exe>", e))?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let mut env = cli::update::Env {
                exe,
                project_dir: notice_root()?,
                today: agentsync::config::snapshot::utc_date(now),
                width: cli::update::terminal_width(),
                fetch: &mut cli::update::curl_fetch,
                extract: &mut cli::update::tar_extract,
                ask: &mut cli::update::ask_binary,
            };
            cli::update::update(
                rest,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Dedupe => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let cwd = paths::logical_root(None, &cwd, var("PWD").as_deref());
            cli::dedupe::dedupe(
                rest,
                &cwd,
                &project_root,
                &style,
                prompts::is_tty()
                    .then_some(&mut prompts::read_terminal as &mut dyn FnMut() -> String),
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Migrate => {
            let prompt_root = match path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty())
            {
                Some(root) => root,
                None => {
                    let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
                    paths::logical_root(None, &cwd, var("PWD").as_deref())
                }
            };
            let path_var = var("PATH");
            let mut env = cli::migrate::Env {
                version: engine_version(),
                prompt_root,
                no_clipboard: var("AGENTSYNC_NO_CLIPBOARD").as_deref() == Some("1"),
                stdout_tty: std::io::stdout().is_terminal(),
                interactive: prompts::is_tty(),
                confirm: &mut |question: &str, default_yes: bool| {
                    prompts::confirm(question, default_yes)
                },
                copy: &mut |text: &str| cli::migrate::copy_to_clipboard(text, path_var.as_deref()),
            };
            cli::migrate::migrate(
                rest,
                &Project::discover,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Generate => {
            let mut read_line = || {
                let mut line = String::new();
                match std::io::stdin().read_line(&mut line) {
                    Ok(0) | Err(_) => None,
                    Ok(_) => Some(line.trim_end_matches(['\n', '\r']).to_string()),
                }
            };
            let mut env = cli::generate::Env {
                stdin_tty: std::io::stdin().is_terminal(),
                stdout_tty: std::io::stdout().is_terminal(),
                clipboard: clipboard_command(),
                read_line: &mut read_line,
            };
            cli::generate::generate(
                rest,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::ShellInit => cli::shell_init::shell_init(
            rest,
            var("SHELL").as_deref(),
            &style,
            log_colors(),
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::SetupHooks => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
            let root = match env_root {
                Some(root) => root,
                None => paths::logical_root(None, &cwd, var("PWD").as_deref()),
            };
            cli::setup_hooks::setup_hooks(
                rest,
                &root,
                &style,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Release => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let mut read_line = || {
                let mut line = String::new();
                match std::io::stdin().read_line(&mut line) {
                    Ok(0) | Err(_) => None,
                    Ok(_) => Some(line.trim_end_matches('\n').to_string()),
                }
            };
            let mut env = cli::release::Env {
                cwd: paths::logical_root(None, &cwd, var("PWD").as_deref()),
                install_dir: var("AGENTSYNC_HOME")
                    .filter(|home| Path::new(home).join(".git").is_dir()),
                read_line: &mut read_line,
            };
            cli::release::release(
                rest,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Export => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
            let root = paths::logical_root(env_root.as_deref(), &cwd, var("PWD").as_deref());
            cli::bundle::export(
                rest,
                &root,
                &style,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Import => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let logical_cwd = paths::logical_root(None, &cwd, var("PWD").as_deref());
            let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
            let root = paths::logical_root(env_root.as_deref(), &cwd, var("PWD").as_deref());
            let mut read_line = || {
                let mut line = String::new();
                let _ = std::io::stdin().read_line(&mut line);
                line.trim_end_matches(['\n', '\r']).to_string()
            };
            let mut env = cli::bundle::Env {
                cwd: logical_cwd,
                interactive: std::io::stdin().is_terminal(),
                path: var("PATH"),
                read_line: &mut read_line,
            };
            cli::bundle::import(
                rest,
                &root,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Add => {
            let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let root = paths::logical_root(env_root.as_deref(), &cwd, var("PWD").as_deref());
            cli::add::add(
                rest,
                &root,
                &style,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Doctor => {
            let env = cli::doctor::Env {
                version: engine_version(),
                external_roots: external_roots_var(),
            };
            cli::doctor::doctor(
                rest,
                &Project::discover,
                &style,
                &env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Init => {
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let cwd = paths::logical_root(None, &cwd, var("PWD").as_deref());
            let sync_env = sync_env();
            let colors = log_colors();
            let mut sync = |root: &str| cli::sync::run(root, &[], &sync_env, colors, streams());
            let mut confirm =
                |question: &str, default_yes: bool| prompts::confirm(question, default_yes);
            let mut multiselect = |title: &str, options: &[String], preselected: &[String]| {
                prompts::multiselect_on_terminal(title, options, preselected, &style)
            };
            let mut env = cli::init::Env {
                version: engine_version(),
                cwd,
                config_path: path_var("AGENTSYNC_CONFIG_PATH"),
                backup_limit: var("AGENTSYNC_BACKUP_LIMIT"),
                backup_max_age: var("AGENTSYNC_BACKUP_MAX_AGE_DAYS"),
                interactive: prompts::is_tty(),
                confirm: &mut confirm,
                multiselect: &mut multiselect,
                sync: &mut sync,
            };
            cli::init::init(
                rest,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Refresh => {
            let root = match path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty()) {
                Some(root) => root,
                None => {
                    let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
                    paths::logical_root(None, &cwd, var("PWD").as_deref())
                }
            };
            let mut env = cli::refresh::Env {
                interactive: prompts::is_tty(),
                read_line: &mut prompts::read_terminal,
            };
            cli::refresh::refresh(
                rest,
                &root,
                &style,
                &mut env,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::UpgradeConfig => {
            let root = project_root()?;
            cli::upgrade_config::run(
                rest,
                Path::new(&root),
                engine_version(),
                &style,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            )
        }
        Command::Enable => cli::enable::enable(
            rest,
            &Project::discover,
            &style,
            prompts::is_tty(),
            &mut |question: &str| prompts::confirm(question, true),
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Disable => cli::enable::disable(
            rest,
            &Project::discover,
            &style,
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Show => cli::show::show(
            rest,
            &Project::discover,
            &style,
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Adopt => cli::adopt::adopt(
            rest,
            &Project::discover,
            &style,
            prompts::is_tty(),
            &mut |question: &str| prompts::confirm(question, false),
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Profile => cli::profile::profile(
            rest,
            &Project::discover,
            &style,
            prompts::is_tty(),
            &mut |question: &str| prompts::confirm(question, false),
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Diff => cli::diff::diff(
            rest,
            &Project::discover,
            &style,
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Resolve => cli::resolve::resolve(
            rest,
            &Project::discover,
            &style,
            prompts::is_tty(),
            &mut |prompt: &str, out: &mut dyn Write| {
                let _ = write!(out, "        {prompt} ");
                let _ = out.flush();
                prompts::read_terminal()
            },
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Simplify => cli::simplify::simplify(
            rest,
            &Project::discover,
            &style,
            prompts::is_tty(),
            &mut |prompt: &str, out: &mut dyn Write| {
                let _ = write!(out, "  {prompt} ");
                let _ = out.flush();
                prompts::read_terminal()
            },
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::Customize => cli::customize::customize(
            rest,
            &Project::discover,
            &style,
            std::io::stdin().is_terminal(),
            &mut |prompt: &str| {
                eprint!("{prompt}");
                let _ = std::io::stderr().flush();
                let mut line = String::new();
                let _ = std::io::stdin().read_line(&mut line);
                line.trim_matches([' ', '\t', '\n']).to_string()
            },
            &mut std::io::stdout(),
            &mut std::io::stderr(),
        ),
        Command::List => {
            let mut out = std::io::stdout().lock();
            cli::list::run(rest, &Project::discover, &style, &mut out)
        }
        Command::Check => {
            let root = project_root()?;
            let env = Env {
                config_path: path_var("AGENTSYNC_CONFIG_PATH"),
                skip_post_sync: Some("true".to_string()),
                allow_post_sync: None,
                backup: None,
                external_source_roots: external_roots_var(),
            };
            let mut out = std::io::stdout().lock();
            let mut err = std::io::stderr().lock();
            cli::check::run(rest, &root, &env, &style, &mut out, &mut err)
        }
        Command::Sync if rest.iter().any(|a| a == "--workspace") => {
            let forwarded: Vec<String> = rest
                .iter()
                .filter(|a| *a != "--workspace")
                .cloned()
                .collect();
            let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
            let cwd = paths::logical_root(None, &cwd, var("PWD").as_deref());
            Ok(cli::workspace::run(
                &cwd,
                &forwarded,
                &sync_env(),
                &style,
                log_colors(),
                &streams,
            ))
        }
        Command::Sync => {
            let root = project_root()?;
            Ok(cli::sync::run(
                &root,
                rest,
                &sync_env(),
                log_colors(),
                streams(),
            ))
        }
        Command::Rollback => {
            let supplied_root =
                match path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty()) {
                    Some(root) => root,
                    None => {
                        let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
                        paths::logical_root(None, &cwd, var("PWD").as_deref())
                    }
                };
            let env = cli::rollback::Env {
                config_path: path_var("AGENTSYNC_CONFIG_PATH"),
                backup_limit: var("AGENTSYNC_BACKUP_LIMIT"),
                backup_max_age: var("AGENTSYNC_BACKUP_MAX_AGE_DAYS"),
            };
            let mut confirm = |question: &str| prompts::confirm(question, false);
            Ok(cli::rollback::run(
                &supplied_root,
                rest,
                &env,
                &style,
                &mut confirm,
                &mut std::io::stdout(),
                &mut std::io::stderr(),
            ))
        }
    }
}
fn var(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

/// An environment variable holding one path, translated from Git Bash's
/// spelling on Windows.
fn path_var(name: &str) -> Option<String> {
    var(name).map(|path| paths::from_msys(&path, var("MSYSTEM").as_deref()))
}

/// `AGENTSYNC_EXTERNAL_SOURCE_ROOTS`, colon-separated as Bash reads it; on
/// Windows each entry is translated and the list rejoined with `;`, the
/// separator `Paths::trust_external_roots` splits there.
fn external_roots_var() -> Option<String> {
    let raw = var("AGENTSYNC_EXTERNAL_SOURCE_ROOTS")?;
    if !cfg!(windows) {
        return Some(raw);
    }
    let msystem = var("MSYSTEM");
    // A drive letter splits into `C` and `/Users/…`; put those back together.
    let mut entries: Vec<String> = Vec::new();
    for piece in raw.split(':') {
        match entries.last_mut() {
            Some(last)
                if last.len() == 1
                    && last.bytes().all(|b| b.is_ascii_alphabetic())
                    && piece.starts_with('/') =>
            {
                last.push(':');
                last.push_str(piece);
            }
            _ => entries.push(piece.to_string()),
        }
    }
    Some(
        entries
            .iter()
            .map(|entry| paths::from_msys(entry, msystem.as_deref()))
            .collect::<Vec<_>>()
            .join(";"),
    )
}

fn sync_env() -> cli::sync::Env {
    let skip_backup = var("AGENTSYNC_INTERNAL_SKIP_BACKUP").as_deref() == Some("true");
    cli::sync::Env {
        render: Env {
            config_path: path_var("AGENTSYNC_CONFIG_PATH"),
            skip_post_sync: var("AGENTSYNC_SKIP_POST_SYNC"),
            allow_post_sync: var("AGENTSYNC_ALLOW_POST_SYNC"),
            backup: (!skip_backup).then(|| agentsync::engine::render::BackupBounds {
                limit: var("AGENTSYNC_BACKUP_LIMIT"),
                max_age: var("AGENTSYNC_BACKUP_MAX_AGE_DAYS"),
            }),
            external_source_roots: external_roots_var(),
        },
        skip_backup,
        backup_limit: var("AGENTSYNC_BACKUP_LIMIT"),
        backup_max_age: var("AGENTSYNC_BACKUP_MAX_AGE_DAYS"),
    }
}

/// The clipboard command `_output_prompt` names in its tip: the first of
/// `pbcopy`, `wl-copy`, `xclip`, `xsel` on `PATH`, with the flags Bash printed.
fn clipboard_command() -> Option<String> {
    let path = std::env::var_os("PATH")?;
    let on_path = |name: &str| std::env::split_paths(&path).any(|dir| dir.join(name).is_file());
    [
        ("pbcopy", "pbcopy"),
        ("wl-copy", "wl-copy"),
        ("xclip", "xclip -selection clipboard"),
        ("xsel", "xsel --clipboard --input"),
    ]
    .iter()
    .find(|(name, _)| on_path(name))
    .map(|(_, command)| command.to_string())
}

/// `_use_colors` of `logging.sh`, on the stream the log is written to: stderr
/// is a terminal and `NO_COLOR` is empty.
fn log_colors() -> bool {
    use std::io::IsTerminal;
    std::io::stderr().is_terminal() && var("NO_COLOR").is_none_or(|v| v.is_empty())
}

/// Log lines to the process streams as `echo` writes them. A closed stdout does
/// not stop the run: the transaction finishes, as it would with nobody reading.
fn streams() -> Sink {
    Box::new(|stream, line| {
        let _ = match stream {
            Stream::Out => writeln!(std::io::stdout(), "{line}"),
            Stream::Err => writeln!(std::io::stderr(), "{line}"),
        };
    })
}

/// `REPO_ROOT` as `lib/check.sh` derives it: `AGENTSYNC_REPO_ROOT`, else the
/// working directory, spelled logically.
fn project_root() -> Result<String, Error> {
    let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
    let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
    let root = paths::logical_root(
        env_root.as_deref(),
        &cwd,
        std::env::var("PWD").ok().as_deref(),
    );
    if !std::path::Path::new(&root).is_dir() {
        return Err(Error::ProjectRootNotFound(PathBuf::from(
            env_root.unwrap_or(root),
        )));
    }
    Ok(root)
}

/// The running binary with symlinks resolved.
fn current_exe() -> std::io::Result<PathBuf> {
    std::env::current_exe()?.canonicalize()
}

/// `${AGENTSYNC_REPO_ROOT:-$PWD}`, spelled logically.
fn notice_root() -> Result<String, Error> {
    let env_root = path_var("AGENTSYNC_REPO_ROOT").filter(|root| !root.is_empty());
    let cwd = std::env::current_dir().map_err(|e| Error::io(".", e))?;
    Ok(paths::logical_root(
        env_root.as_deref(),
        &cwd,
        var("PWD").as_deref(),
    ))
}

/// `check_for_updates`: on a terminal, unless `AGENTSYNC_NO_UPDATE_CHECK` is
/// set, the project-format notice, the banner from the cache beside the
/// install's `bin/`, and a detached `__update-cache` run that refreshes the
/// cache for the next time.
fn check_for_updates() -> Result<(), Error> {
    if !std::io::stdout().is_terminal()
        || var("AGENTSYNC_NO_UPDATE_CHECK").is_some_and(|v| !v.is_empty())
    {
        return Ok(());
    }
    let style = Style::for_stdout();
    let root = notice_root()?;
    let mut out = std::io::stdout().lock();
    out.write_all(cli::notice::format_notice(Path::new(&root), &style).as_bytes())
        .map_err(|e| Error::io("<stdout>", e))?;
    let Some(cache) = current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.join(cli::notice::CACHE_FILE)))
    else {
        return Ok(());
    };
    if let Ok(text) = std::fs::read_to_string(&cache) {
        out.write_all(cli::notice::update_banner(&text, engine_version(), &style).as_bytes())
            .map_err(|e| Error::io("<stdout>", e))?;
    }
    out.flush().map_err(|e| Error::io("<stdout>", e))?;
    if let Ok(exe) = std::env::current_exe() {
        let _ = std::process::Command::new(exe)
            .arg("__update-cache")
            .arg(&cache)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
    Ok(())
}

fn print_usage() -> Result<u8, Error> {
    let mut out = std::io::stdout().lock();
    out.write_all(cli::usage::usage(&Style::for_stdout()).as_bytes())
        .map(|()| 0)
        .map_err(|e| Error::io("<stdout>", e))
}

fn print_version() -> Result<u8, Error> {
    let mut out = std::io::stdout().lock();
    writeln!(out, "agentsync v{}", engine_version())
        .map(|()| 0)
        .map_err(|e| Error::io("<stdout>", e))
}
