//! `agentsync refresh`: `cmd_refresh` of `lib/helpers/refresh.sh`, which pulls
//! updated templates into `.ai/src/` through a three-way diff against the
//! template manifest, so untouched files update silently and only true
//! conflicts wait for an answer.

mod args;
mod classify;
mod session;

use std::io::Write;
use std::path::{Path, PathBuf};

use super::put;
use crate::config::template_manifest::TemplateManifest;
use crate::output::style::Style;
use crate::{Error, config::catalog};

pub use args::HELP;
use args::{parse_args, resolve_scope};
use classify::{collect, load_overrides};
use session::Run;
pub(crate) use session::write_template;

/// Printed where Bash printed `$AGENTSYNC_HOME/lib/templates`; the binary
/// reads the embedded copy, so the line names the release it came from.
fn templates_display() -> String {
    format!("shipped with agentsync v{}", crate::engine_version())
}

/// What `refresh` takes from the terminal.
pub struct Env<'a> {
    /// `is_tty`: stdin and stdout are both terminals.
    pub interactive: bool,
    /// `read -r reply </dev/tty`, empty when the terminal cannot be read.
    pub read_line: &'a mut dyn FnMut() -> String,
}

pub fn refresh(
    args: &[String],
    root: &str,
    style: &Style,
    env: &mut Env,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let options = match parse_args(args, style, out, err)? {
        Ok(options) => options,
        Err(status) => return Ok(status),
    };

    let src_base = if Path::new(root).join(".ai/src").is_dir() {
        ".ai/src"
    } else if Path::new(root).join(".ai").is_dir() {
        ".ai"
    } else {
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
    };
    let user_base_shown = format!("{root}/{src_base}");
    let user_base = PathBuf::from(&user_base_shown);

    let categories = match resolve_scope(&options.only, &user_base_shown, style, err)? {
        Ok(categories) => categories,
        Err(status) => return Ok(status),
    };

    let manifest = TemplateManifest::load(Path::new(root))?;
    let has_manifest = !manifest.is_empty();
    let (declined, pinned) = load_overrides(root);
    let templates = catalog::template_files();
    let changes = collect(
        &templates,
        &user_base,
        &categories,
        options.include_agents_md,
        &manifest,
        &declined,
        &pinned,
        options.review,
    );

    let mut run = Run {
        style,
        env,
        user_base,
        manifest,
        out,
        err,
    };

    if options.status_only {
        run.print_status(&declined, &changes.deleted)?;
        return Ok(0);
    }

    let mut scope_label = categories.join(",");
    if options.include_agents_md {
        scope_label.push_str(",AGENTS.md");
    }
    let mut header = format!(
        "\n{}\n\n  {} {}\n  {}   {user_base_shown}\n  {}     {scope_label}\n",
        style.bold("  AgentSync Refresh"),
        style.dim("Templates:"),
        templates_display(),
        style.dim("Project:"),
        style.dim("Scope:")
    );
    if !has_manifest {
        header.push_str(&format!(
            "  {}  {}\n",
            style.dim("Manifest:"),
            style.yellow("none — falling back to two-way diff")
        ));
    }
    header.push('\n');
    run.say(&header)?;

    let visible_deleted = options.include_deleted && !changes.deleted.is_empty();

    if changes.new.is_empty()
        && changes.conflicts.is_empty()
        && changes.auto.is_empty()
        && !visible_deleted
    {
        let mut text = format!(
            "  {} {} file(s) match the current templates.\n",
            style.green("Already up to date!"),
            changes.unchanged
        );
        if !declined.is_empty() {
            text.push_str(&format!(
                "  {}\n",
                style.dim(&format!(
                    "Persistently declined (agent_sync.yaml): {} file(s).",
                    declined.len()
                ))
            ));
        }
        if !changes.deleted.is_empty() {
            text.push_str(&format!(
                "  {}\n",
                style.dim(&format!(
                    "Locally declined (.template-manifest):    {} file(s); --include-deleted to revisit.",
                    changes.deleted.len()
                ))
            ));
        }
        if !declined.is_empty() || !changes.deleted.is_empty() {
            text.push_str(&format!(
                "  {}\n",
                style.dim("Pass --status for the full list.")
            ));
        }
        if changes.silently_kept > 0 && !options.review {
            text.push_str(&format!(
                "  {}\n",
                style.dim(&format!(
                    "{} file(s) differ from the shipped template (local edits or earlier skips); pass --review to revisit.",
                    changes.silently_kept
                ))
            ));
        }
        run.say(&text)?;
        run.heal(&templates);
        if !options.dry_run {
            run.manifest.write(Path::new(root))?;
        }
        run.say("\n")?;
        return Ok(0);
    }

    let mut summary = format!("  {}\n", style.green("Summary:"));
    if !changes.new.is_empty() {
        summary.push_str(&format!(
            "    {} {} new template(s)\n",
            style.green("+"),
            changes.new.len()
        ));
    }
    if !changes.auto.is_empty() {
        summary.push_str(&format!(
            "    {} {} auto-update(s) — you hadn't touched them locally\n",
            style.cyan("↑"),
            changes.auto.len()
        ));
    }
    if !changes.conflicts.is_empty() {
        summary.push_str(&format!(
            "    {} {} conflict(s) — your version differs from the template\n",
            style.yellow("~"),
            changes.conflicts.len()
        ));
    }
    if visible_deleted {
        summary.push_str(&format!(
            "    {} {} previously declined — pass --include-deleted to revisit\n",
            style.dim("?"),
            changes.deleted.len()
        ));
    }
    if changes.silently_kept > 0 && !options.review {
        summary.push_str(&format!(
            "    {} {} silently kept (local edits or earlier skips) — pass --review to revisit\n",
            style.dim("·"),
            changes.silently_kept
        ));
    }
    if changes.unchanged > 0 {
        summary.push_str(&format!(
            "    {} {} unchanged\n",
            style.dim("·"),
            changes.unchanged
        ));
    }
    summary.push('\n');
    run.say(&summary)?;

    run.list_proposed(&changes, visible_deleted)?;

    if options.dry_run {
        run.say(&format!(
            "  {} — no files written.\n\n",
            style.yellow("Dry run")
        ))?;
        return Ok(0);
    }

    if !run.env.interactive
        && !options.assume_yes
        && changes.new.len() + changes.conflicts.len() > 0
    {
        put(
            run.err,
            format!(
                "  {}: Cannot run interactively (not a TTY).\n  Use {} to add new files and apply auto-updates\n  (conflicts are always skipped non-interactively).\n  Use {} to preview.\n",
                style.red("Error"),
                style.cyan("--yes"),
                style.cyan("--dry-run")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }

    let (mut added, mut updated, mut auto_applied, mut skipped) = (0, 0, 0, 0);
    let mut cancelled = false;

    for entry in &changes.auto {
        run.copy(entry)?;
        run.say(&format!(
            "  {} {}  {}\n",
            style.cyan("↑"),
            entry.rel,
            style.dim("(auto-updated; you hadn't touched it)")
        ))?;
        auto_applied += 1;
    }

    if visible_deleted {
        for entry in &changes.deleted {
            if cancelled {
                break;
            }
            if options.assume_yes {
                run.say(&format!(
                    "  {} {} {}\n",
                    style.dim("?"),
                    entry.rel,
                    style.dim("(previously declined — skipped under --yes; run interactively)")
                ))?;
                skipped += 1;
                continue;
            }
            match run.prompt_deleted(entry)? {
                'a' => {
                    run.copy(entry)?;
                    run.say(&format!("    {}\n", style.green("restored.")))?;
                    added += 1;
                }
                'q' => cancelled = true,
                _ => {
                    run.say(&format!("    {}\n", style.dim("still declined.")))?;
                    skipped += 1;
                }
            }
        }
    }

    if !changes.new.is_empty() && !cancelled {
        for entry in &changes.new {
            if cancelled {
                break;
            }
            if options.assume_yes {
                run.copy(entry)?;
                run.say(&format!("  {} {}\n", style.green("+"), entry.rel))?;
                added += 1;
                continue;
            }
            match run.prompt_new(entry)? {
                'a' => {
                    run.copy(entry)?;
                    run.say(&format!("    {}\n", style.green("added.")))?;
                    added += 1;
                }
                'q' => cancelled = true,
                _ => {
                    // Skip-as-decline: recorded so the file never reappears as NEW.
                    run.manifest.record(&entry.rel, &entry.hash);
                    run.say(&format!(
                        "    {}\n",
                        style.dim(
                            "declined (will not be offered again — use --include-deleted to revisit)."
                        )
                    ))?;
                    skipped += 1;
                }
            }
        }
    }

    if !changes.conflicts.is_empty() && !cancelled {
        for entry in &changes.conflicts {
            if cancelled {
                break;
            }
            if options.assume_yes {
                run.say(&format!(
                    "  {} {} {}\n",
                    style.yellow("~"),
                    entry.rel,
                    style.dim("(conflict — skipped; run interactively to review)")
                ))?;
                skipped += 1;
                continue;
            }
            match run.prompt_conflict(entry)? {
                'u' => {
                    run.copy(entry)?;
                    run.say(&format!("    {}\n", style.yellow("updated.")))?;
                    updated += 1;
                }
                'q' => cancelled = true,
                _ => {
                    // Recorded at the new template hash so the skip is remembered.
                    run.manifest.record(&entry.rel, &entry.hash);
                    run.say(&format!(
                        "    {}\n",
                        style.dim("skipped (remembered — agentsync refresh --review to revisit).")
                    ))?;
                    skipped += 1;
                }
            }
        }
    }

    run.heal(&templates);
    run.manifest.write(Path::new(root))?;

    let mut closing = String::from("\n");
    if cancelled {
        closing.push_str(&format!(
            "  {} Files already applied are kept.\n",
            style.yellow("Cancelled.")
        ));
    }
    closing.push_str(&format!(
        "  {} Added: {added} · Auto-updated: {auto_applied} · Updated: {updated} · Skipped: {skipped} · Unchanged: {}\n",
        style.green("Done."),
        changes.unchanged
    ));
    if added + auto_applied + updated > 0 {
        closing.push_str(&format!(
            "\n  Next: {} to distribute the updates to enabled tools.\n",
            style.cyan("agentsync sync")
        ));
    }
    closing.push('\n');
    run.say(&closing)?;
    Ok(0)
}

#[cfg(all(test, unix))]
mod tests {
    use std::collections::VecDeque;

    use super::*;
    use crate::config::template_manifest::REL;
    use crate::paths::DiskText;
    use crate::transaction::manifest::sha256_hex;

    /// A project `init` scaffolded: every template under `.ai/src/` and a
    /// manifest recording each hash.
    pub(super) fn seeded() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        let base = Path::new(&root).join(".ai/src");
        let mut manifest = TemplateManifest::default();
        for (rel, bytes) in catalog::template_files() {
            let path = base.join(&rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bytes).unwrap();
            manifest.record(&rel, &sha256_hex(bytes));
        }
        std::fs::write(
            Path::new(&root).join(".ai/agent_sync.yaml"),
            "tools:\n  enabled: []\n",
        )
        .unwrap();
        manifest.write(Path::new(&root)).unwrap();
        (dir, root)
    }

    pub(super) struct Outcome {
        pub(super) status: u8,
        pub(super) out: String,
        pub(super) err: String,
    }

    pub(super) fn call(root: &str, args: &[&str], interactive: bool, replies: &[&str]) -> Outcome {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let mut queue: VecDeque<String> = replies.iter().map(|r| r.to_string()).collect();
        let mut read_line = || queue.pop_front().unwrap_or_default();
        let mut env = Env {
            interactive,
            read_line: &mut read_line,
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = refresh(&args, root, &Style::plain(), &mut env, &mut out, &mut err).unwrap();
        Outcome {
            status,
            out: String::from_utf8(out).unwrap(),
            err: String::from_utf8(err).unwrap(),
        }
    }

    pub(super) fn manifest_text(root: &str) -> String {
        std::fs::read_to_string(Path::new(root).join(REL)).unwrap_or_default()
    }

    pub(super) fn drop_entry(root: &str, rel: &str) {
        let kept: String = manifest_text(root)
            .lines()
            .filter(|line| !line.starts_with(&format!("{rel}\t")))
            .map(|line| format!("{line}\n"))
            .collect();
        std::fs::write(Path::new(root).join(REL), kept).unwrap();
    }

    pub(super) fn set_entry(root: &str, rel: &str, hash: &str) {
        drop_entry(root, rel);
        let mut lines: Vec<String> = manifest_text(root).lines().map(str::to_string).collect();
        lines.push(format!("{rel}\t{hash}"));
        lines.sort();
        std::fs::write(
            Path::new(&root).join(REL),
            lines.iter().map(|l| format!("{l}\n")).collect::<String>(),
        )
        .unwrap();
    }

    pub(super) fn append(root: &str, rel: &str, text: &str) {
        let path = Path::new(root).join(".ai/src").join(rel);
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        file.write_all(text.as_bytes()).unwrap();
    }

    pub(super) fn header(root: &str, scope: &str) -> String {
        format!(
            "\n  AgentSync Refresh\n\n  Templates: {}\n  Project:   {root}/.ai/src\n  Scope:     {scope}\n\n",
            templates_display()
        )
    }

    pub(super) const NOT_A_TTY: &str = "  Error: Cannot run interactively (not a TTY).\n  Use --yes to add new files and apply auto-updates\n  (conflicts are always skipped non-interactively).\n  Use --dry-run to preview.\n";

    #[test]
    fn an_untouched_project_is_up_to_date_and_status_reports_nothing_declined() {
        let (_dir, root) = seeded();
        let before = manifest_text(&root);
        let run = call(&root, &["--yes"], false, &[]);
        assert_eq!(run.status, 0);
        assert_eq!(
            run.out,
            format!(
                "{}  Already up to date! 18 file(s) match the current templates.\n\n",
                header(&root, "rules,skills,commands,agents")
            )
        );
        assert_eq!(run.err, "");
        assert_eq!(manifest_text(&root), before);
        assert_eq!(
            call(&root, &["--status"], false, &[]).out,
            "\n  Declined templates\n  Nothing declined.\n\n"
        );

        std::fs::rename(
            Path::new(&root).join(".ai/src"),
            Path::new(&root).join("legacy"),
        )
        .unwrap();
        for entry in std::fs::read_dir(Path::new(&root).join("legacy")).unwrap() {
            let entry = entry.unwrap();
            std::fs::rename(
                entry.path(),
                Path::new(&root).join(".ai").join(entry.file_name()),
            )
            .unwrap();
        }
        let legacy = call(&root, &["--yes"], false, &[]);
        assert!(legacy.out.contains(&format!("  Project:   {root}/.ai\n")));
        assert!(legacy.out.contains("Already up to date! 18 file(s)"));

        std::fs::remove_dir_all(Path::new(&root).join(".ai")).unwrap();
        let gone = call(&root, &["--status"], false, &[]);
        assert_eq!(
            (gone.status, gone.out.as_str(), gone.err),
            (
                1,
                "",
                format!("Error: No .ai/ directory found in {root}\nRun agentsync init first.\n")
            )
        );
    }
}
