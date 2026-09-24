//! The environment and run state `sync.sh` reads and fills: `Env`, `BackupBounds`, `Selection`, `Run`.

use std::collections::BTreeSet;

use crate::engine::overlay::Sources;
use crate::{config::version, transaction::backup};

/// Environment `sync.sh` reads. `check` sets `skip_post_sync`, as
/// `lib/check.sh` exported `AGENTSYNC_SKIP_POST_SYNC=true`.
#[derive(Default)]
pub struct Env {
    pub config_path: Option<String>,
    pub skip_post_sync: Option<String>,
    pub allow_post_sync: Option<String>,
    /// The bounds `backup_configure` validates; `None` when the run takes no
    /// backup (`AGENTSYNC_INTERNAL_SKIP_BACKUP=true`, and `check`).
    pub backup: Option<BackupBounds>,
    /// `AGENTSYNC_EXTERNAL_SOURCE_ROOTS`.
    pub external_source_roots: Option<String>,
}

/// `AGENTSYNC_BACKUP_LIMIT` and `AGENTSYNC_BACKUP_MAX_AGE_DAYS` for a run that
/// takes a backup.
#[derive(Default)]
pub struct BackupBounds {
    pub limit: Option<String>,
    pub max_age: Option<String>,
}

/// `--only`, `--skip`, and `--profile`.
#[derive(Default)]
pub struct Selection {
    pub only: String,
    pub skip: String,
    pub profile: Option<String>,
}

impl Selection {
    /// `should_sync_tool`.
    pub fn includes(&self, slug: &str) -> bool {
        let listed = |csv: &str| format!(",{csv},").contains(&format!(",{slug},"));
        (self.only.is_empty() || listed(&self.only))
            && (self.skip.is_empty() || !listed(&self.skip))
    }
}

/// The globals `sync.sh` fills as it goes.
pub struct Run {
    pub config: Option<String>,
    pub config_path: Option<String>,
    pub(super) cleanup: String,
    pub update_gitignore: bool,
    pub outputs: &'static str,
    pub version_pin: version::Mode,
    pub retention: backup::Retention,
    pub(super) skip_post_sync: bool,
    pub(super) allow_post_sync: bool,
    pub sources: Sources,
    pub(super) base_sources: Sources,
    pub(super) profile_base_src: String,
    pub(super) selection: Selection,
    pub(super) profiles: Vec<String>,
    pub(super) enabled: BTreeSet<String>,
    pub(super) profile_tools: BTreeSet<String>,
    pub(super) protected: Vec<String>,
    pub backup_targets: Vec<String>,
    /// Repo-relative dests whose settings are merged by owned key.
    pub keyed_dests: BTreeSet<String>,
    pub gitignore_generated: Vec<String>,
    pub gitignore_profile: Vec<String>,
    pub(super) tools: Vec<String>,
    pub(super) printed: bool,
    pub synced: usize,
    pub skipped: usize,
    pub total: usize,
    pub skipped_names: Vec<String>,
}
