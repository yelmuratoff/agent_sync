pub mod add;
pub mod adopt;
pub mod bundle;
pub mod check;
pub mod customize;
pub mod dedupe;
pub mod diff;
pub mod doctor;
pub mod enable;
pub mod generate;
pub mod init;
pub mod list;
pub mod migrate;
pub mod notice;
pub mod profile;
pub mod refresh;
pub mod release;
pub mod resolve;
pub mod rollback;
pub mod setup_hooks;
pub mod shell_init;
pub mod show;
pub mod simplify;
pub mod skills;
pub mod sync;
pub mod update;
pub mod upgrade_config;
pub mod usage;
pub mod workspace;

use crate::paths::DiskText;
use std::io::Write;

use crate::Error;
use crate::output::style::Style;
use crate::project::Project;

/// `tool_resolver_require_project_user_dir`: prints why and returns status 1.
pub(crate) fn refuse_outside_tools_dir(
    project: &Project,
    style: &Style,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    err.write_all(
        format!(
            "{}: source.tools resolves outside the project: {}\nAgentSync only reads that catalog; edit its tool overrides where they live.\n",
            style.red("Error"),
            project.user_tools_dir().disk_text()
        )
        .as_bytes(),
    )
    .map_err(|e| Error::io("<stderr>", e))?;
    Ok(1)
}

/// The command word `main` dispatches on. Each command parses its own options
/// as its Bash `cmd_*` did, so only the word is matched here: a parser owning
/// the options would consume a leading `--`. `usage::wants_usage` answers
/// `help` and the help flags before this runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Version,
    List,
    Skills,
    Check,
    Sync,
    Rollback,
    Update,
    UpdateCache,
    Catalog,
    Dedupe,
    Migrate,
    Generate,
    ShellInit,
    SetupHooks,
    Release,
    Export,
    Import,
    Add,
    Doctor,
    Init,
    Refresh,
    UpgradeConfig,
    Enable,
    Disable,
    Customize,
    Show,
    Diff,
    Simplify,
    Resolve,
    Profile,
    Adopt,
}

impl Command {
    /// The command `word` names, with the aliases the Bash `case` accepted:
    /// `ls`, `gen`, and the version flags as commands.
    pub fn parse(word: &str) -> Option<Self> {
        Some(match word {
            "version" | "--version" | "-v" => Self::Version,
            "list" | "ls" => Self::List,
            "skills" => Self::Skills,
            "check" => Self::Check,
            "sync" => Self::Sync,
            "rollback" => Self::Rollback,
            "update" => Self::Update,
            "__update-cache" => Self::UpdateCache,
            update::CATALOG_COMMAND => Self::Catalog,
            "dedupe" => Self::Dedupe,
            "migrate" => Self::Migrate,
            "generate" | "gen" => Self::Generate,
            "shell-init" => Self::ShellInit,
            "setup-hooks" => Self::SetupHooks,
            "release" => Self::Release,
            "export" => Self::Export,
            "import" => Self::Import,
            "add" => Self::Add,
            "doctor" => Self::Doctor,
            "init" => Self::Init,
            "refresh" => Self::Refresh,
            "upgrade-config" => Self::UpgradeConfig,
            "enable" => Self::Enable,
            "disable" => Self::Disable,
            "customize" => Self::Customize,
            "show" => Self::Show,
            "diff" => Self::Diff,
            "simplify" => Self::Simplify,
            "resolve" => Self::Resolve,
            "profile" => Self::Profile,
            "adopt" => Self::Adopt,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::Command;

    #[test]
    fn aliases_name_the_same_command() {
        assert_eq!(Command::parse("ls"), Some(Command::List));
        assert_eq!(Command::parse("gen"), Some(Command::Generate));
        assert_eq!(Command::parse("--version"), Some(Command::Version));
        assert_eq!(Command::parse("-v"), Some(Command::Version));
    }

    #[test]
    fn hidden_commands_parse() {
        assert_eq!(Command::parse("__update-cache"), Some(Command::UpdateCache));
        assert_eq!(Command::parse("__catalog"), Some(Command::Catalog));
    }

    #[test]
    fn unknown_words_and_help_are_not_commands() {
        assert_eq!(Command::parse(""), None);
        assert_eq!(Command::parse("help"), None);
        assert_eq!(Command::parse("--help"), None);
        assert_eq!(Command::parse("synch"), None);
    }
}
