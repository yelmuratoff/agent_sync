//! The surface the Bash entry point answered itself: `print_usage` for `help`,
//! `--help`, `-h`, and no command; the `--help` interception for commands whose
//! own parser does not read it; and the unknown-command refusal.

use std::io::Write;

use super::customize::put;
use crate::output::style::Style;
use crate::{Error, engine_version};

const COMMANDS: [(&str, &str); 30] = [
    ("init", "Create .ai/ structure in current project"),
    ("sync", "Sync instructions to all enabled tools"),
    ("rollback", "Restore targets from the latest backup"),
    ("check", "Verify outputs are in sync with source"),
    ("list", "Show available tools and their status"),
    (
        "skills",
        "Inspect project skills and explicit external catalogs",
    ),
    ("enable", "Opt in to one or more tools"),
    ("disable", "Opt out of one or more tools"),
    ("add", "Scaffold a rule, skill, command, or subagent"),
    ("customize", "Create a per-field override for a tool"),
    ("simplify", "Remove override fields that match the base"),
    (
        "migrate",
        "Print and copy a prompt for upgrading an existing config",
    ),
    ("show", "Show effective config for a tool"),
    ("diff", "Show user overrides vs base defaults"),
    (
        "resolve",
        "Interactively reconcile overrides with base values",
    ),
    ("doctor", "Validate setup and surface warnings"),
    (
        "dedupe",
        "Remove source files that duplicate a parent .ai/src/",
    ),
    (
        "adopt",
        "Promote a manual edit in a generated file back into .ai/src/",
    ),
    (
        "profile",
        "Manage config-home profiles (work/personal variants)",
    ),
    (
        "generate",
        "Print a prompt to auto-generate project-specific rules",
    ),
    (
        "setup-hooks",
        "Install git hooks for automatic sync (--pre-commit optional)",
    ),
    (
        "shell-init",
        "Print a shell hook that auto-syncs on directory change",
    ),
    ("export", "Bundle .ai/src/ into a shareable archive"),
    ("import", "Import config from GitHub, archive, or directory"),
    ("refresh", "Pull new template files into existing .ai/src/"),
    (
        "update",
        "Update AgentSync to the latest version, or pin one: update <version>",
    ),
    (
        "upgrade-config",
        "Re-pin agentsync_version in agent_sync.yaml",
    ),
    ("release", "Bump version, tag, and push (maintainer)"),
    ("version", "Print version"),
    ("help", "Show this message"),
];

const SYNC_OPTIONS: &str = "    --only <tools>    Sync only these tools (comma-separated)
    --skip <tools>    Skip these tools (comma-separated)
    --profile <name>  Sync personal tools plus the named config-home profile
    --dry-run         Preview changes without writing
    --force           Overwrite destination files even if they were edited manually
    --if-stale        Sync only when source changed since the last sync (else no-op)
    --workspace       Run sync in every .ai/ below cwd (bottom-up alphabetical)
";

const EXAMPLES: &str = "    agentsync init
    agentsync list
    agentsync skills list
    agentsync skills show agentsync
    agentsync skills check
    agentsync skills catalog list --catalog cards.tsv
    agentsync enable claude cursor
    agentsync add rule testing
    agentsync add skill deploy
    agentsync customize cursor
    agentsync simplify
    agentsync simplify cursor --apply
    agentsync show cursor
    agentsync diff
    agentsync doctor
    agentsync resolve
    agentsync adopt .cursor/rules/core.mdc
    agentsync adopt --all
    agentsync profile add hub
    agentsync sync
    agentsync sync --only claude,cursor
    agentsync sync --profile hub
    agentsync sync --dry-run
    agentsync sync --if-stale
    agentsync rollback
    agentsync rollback --list
    agentsync check
    agentsync setup-hooks --pre-commit
    eval \"$(agentsync shell-init zsh)\"   # add to ~/.zshrc
    agentsync generate
    agentsync generate React + TypeScript + Next.js project with Prisma ORM
    agentsync migrate
    agentsync export
    agentsync import https://github.com/user/repo
    agentsync refresh
    agentsync refresh --only rules,skills
    agentsync refresh --dry-run
";

/// `print_usage`.
pub fn usage(style: &Style) -> String {
    let mut text = format!(
        "\n{} v{}\n{}\n\n  {}\n    agentsync <command> [options]\n\n  {}\n",
        style.bold("  AgentSync"),
        engine_version(),
        style.dim("  Sync AI agent instructions to every tool from one source."),
        style.green("USAGE"),
        style.green("COMMANDS"),
    );
    for (name, summary) in COMMANDS {
        text.push_str(&format!(
            "    {}{}{summary}\n",
            style.cyan(name),
            " ".repeat(15 - name.len())
        ));
    }
    text.push_str(&format!("\n  {}\n", style.green("SYNC OPTIONS")));
    text.push_str(SYNC_OPTIONS);
    text.push_str(&format!("\n  {}\n", style.green("EXAMPLES")));
    text.push_str(EXAMPLES);
    text.push_str(&format!(
        "\n  {}\n{}\n\n",
        style.green("DOCS"),
        style.dim("    https://github.com/yelmuratoff/agent")
    ));
    text
}

/// Whether `args` is answered with the usage: no command, an empty one
/// (`${1:-help}`), `help`, `--help`, or `-h`. Later arguments are ignored;
/// every command answers its own `--help`.
pub fn wants_usage(args: &[String]) -> bool {
    let command = args.first().map(String::as_str).unwrap_or("");
    matches!(command, "" | "help" | "--help" | "-h")
}

/// The `*)` arm of `main`: the refusal and the usage on stderr, status 1.
pub fn unknown_command(command: &str, style: &Style, err: &mut dyn Write) -> Result<u8, Error> {
    put(
        err,
        format!(
            "{}: Unknown command: {command}\n\n{}",
            style.red("Error"),
            usage(style)
        )
        .as_bytes(),
    )?;
    Ok(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn the_usage_matches_print_usage() {
        let text = usage(&Style::plain());
        assert!(text.starts_with(&format!(
            "\n  AgentSync v{}\n  Sync AI agent instructions to every tool from one source.\n\n  USAGE\n    agentsync <command> [options]\n\n  COMMANDS\n    init           Create .ai/ structure in current project\n",
            engine_version()
        )));
        assert!(text.contains(
            "\n    upgrade-config Re-pin agentsync_version in agent_sync.yaml\n    release        Bump version, tag, and push (maintainer)\n    version        Print version\n    help           Show this message\n\n  SYNC OPTIONS\n    --only <tools>"
        ));
        assert!(text.contains("\n    eval \"$(agentsync shell-init zsh)\"   # add to ~/.zshrc\n"));
        assert!(text.ends_with(
            "    agentsync refresh --dry-run\n\n  DOCS\n    https://github.com/yelmuratoff/agent\n\n"
        ));
        assert_eq!(text.lines().count(), 90);
    }

    #[test]
    fn a_terminal_gets_the_cli_colors_escapes() {
        let text = usage(&Style::colored());
        assert!(text.starts_with(&format!(
            "\n\x1b[1m  AgentSync\x1b[0m v{}\n\x1b[2m  Sync AI agent instructions to every tool from one source.\x1b[0m\n\n  \x1b[32mUSAGE\x1b[0m\n",
            engine_version()
        )));
        assert!(text.contains("\n    \x1b[36mshell-init\x1b[0m     Print a shell hook"));
        assert!(text.ends_with("\x1b[2m    https://github.com/yelmuratoff/agent\x1b[0m\n\n"));
    }

    #[test]
    fn usage_is_wanted_like_main_in_the_dispatcher() {
        for args in [
            &[][..],
            &[""],
            &["help"],
            &["help", "sync"],
            &["--help"],
            &["-h", "--bogus"],
        ] {
            assert!(wants_usage(&words(args)), "{args:?}");
        }
        for args in [
            &["HELP"][..],
            &["sync", "--help"],
            &["rollback", "-h"],
            &["check", "--help"],
            &["ls", "-h"],
            &["resolve", "--help", "claude"],
            &["enable", "--help"],
            &["version", "--help"],
        ] {
            assert!(!wants_usage(&words(args)), "{args:?}");
        }
    }

    #[test]
    fn an_unknown_command_is_refused_with_the_usage_on_stderr() {
        let mut err = Vec::new();
        let status = unknown_command("nonexistent", &Style::plain(), &mut err).unwrap();
        assert_eq!(status, 1);
        let err = String::from_utf8(err).unwrap();
        assert_eq!(
            err,
            format!(
                "Error: Unknown command: nonexistent\n\n{}",
                usage(&Style::plain())
            )
        );
    }
}
