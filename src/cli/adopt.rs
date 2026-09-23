//! `agentsync adopt`: `cmd_adopt` of `lib/helpers/adopt.sh`, which promotes a
//! manual edit in a generated file back into its source.

use crate::paths::DiskText;
use std::io::Write;
use std::path::Path;
use std::process::Command;

use super::put;
use crate::config::payload::{self, Source};
use crate::config::tool::Tool;
use crate::output::help::{Help, Section};
use crate::output::log::Log;
use crate::output::style::Style;
use crate::paths::{self, Paths};
use crate::project::Project;
use crate::transaction::manifest::{self, Manifest};
use crate::{Error, config::catalog, config::template_manifest, config::yaml_subset};

type Discover<'a> = &'a dyn Fn() -> Result<Project, Error>;
type Confirm<'a> = &'a mut dyn FnMut(&str) -> bool;

pub const HELP: Help = Help {
    command: "adopt",
    tagline: "promote a manual edit back into .ai/src/",
    synopsis: &["adopt <dest-file> [OPTIONS]", "adopt --all [OPTIONS]"],
    description: &[
        "Promote a manual edit in a destination file back into .ai/src/ as the\nnew canonical content. Refuses transformed targets (merged rules,\ninlined skills, format-converted commands/subagents).",
        "With --all, adopt every drifted (manually-edited) tracked output at\nonce, skipping refused targets and same-source conflicts.",
    ],
    sections: &[Section {
        title: "OPTIONS",
        entries: &[
            ("-a, --all", "Adopt every drifted output (no <dest-file>)"),
            ("--dry-run", "Show the plan without writing"),
            ("-y, --yes", "Skip confirmation (required outside a TTY)"),
            ("-h, --help", "Show this help"),
        ],
    }],
    examples: &[
        "adopt CLAUDE.md",
        "adopt .claude/rules/core.md --dry-run",
        "adopt --all --yes",
    ],
};

/// `SOURCE_*` as `_adopt_discover_sources` sets them.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Sources {
    pub agents: String,
    pub rules: String,
    pub skills: String,
    pub commands: String,
    pub subagents: String,
}

/// `_adopt_discover_sources`: the `.ai/src/` layout, else the flat `.ai/`
/// one, then the project's `source.<key>` or root-level `<key>`.
pub fn discover_sources(project: &Project) -> Result<Sources, Error> {
    let root = &project.root;
    let pick = |name: &str, file: bool| {
        [format!(".ai/src/{name}"), format!(".ai/{name}")]
            .into_iter()
            .find(|rel| {
                let path = root.join(rel);
                if file { path.is_file() } else { path.is_dir() }
            })
            .unwrap_or_default()
    };
    let mut sources = Sources {
        agents: pick("AGENTS.md", true),
        rules: pick("rules", false),
        skills: pick("skills", false),
        commands: pick("commands", false),
        subagents: pick("agents", false),
    };
    let Some(config_path) = project.config_path.as_ref().filter(|p| p.is_file()) else {
        return Ok(sources);
    };
    let config = std::fs::read(config_path)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
        .map_err(|e| Error::io(config_path, e))?;
    for (key, slot) in [
        ("agents", &mut sources.agents),
        ("rules", &mut sources.rules),
        ("skills", &mut sources.skills),
        ("commands", &mut sources.commands),
        ("subagents", &mut sources.subagents),
    ] {
        let mut value = yaml_subset::value(&config, &format!("source.{key}"));
        if value.is_empty() {
            value = yaml_subset::value(&config, key);
        }
        if !value.is_empty() {
            *slot = value;
        }
    }
    Ok(sources)
}

/// A destination mapped to the source it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Adoption {
    pub tool: String,
    pub resource: &'static str,
    pub dest_rel: String,
    pub dest_abs: String,
    pub source_abs: String,
    pub source_rel: String,
}

/// What `_adopt_resolve_dest` needs besides the destination.
pub struct Resolver<'a> {
    pub project: &'a Project,
    pub paths: Paths,
    pub sources: Sources,
    tools: Vec<String>,
    blocked_agents: Vec<(String, String)>,
    style: &'a Style,
    warned_legacy: bool,
}

impl<'a> Resolver<'a> {
    pub fn new(project: &'a Project, sources: Sources, style: &'a Style) -> Result<Self, Error> {
        let root = project.root.disk_text();
        let mut tools = catalog::base_tools();
        tools.extend(project.user_override_tools()?);
        tools.sort();
        tools.dedup();
        Ok(Self {
            project,
            paths: Paths::on_disk(&root),
            sources,
            tools,
            blocked_agents: Vec::new(),
            style,
            warned_legacy: false,
        })
    }

    fn for_adopt(mut self) -> Result<Self, Error> {
        let enabled = self.project.enabled_tools()?;
        self.tools.sort_by_key(|slug| !enabled.contains(slug));
        for slug in &enabled {
            let tool = Tool::load(self.project, slug)?;
            if tool.flag("targets.agents.adoptable") == Some(false)
                && let Some(dest) = self.dest_for(&tool, "agents")
            {
                self.blocked_agents.push((dest, slug.clone()));
            }
        }
        Ok(self)
    }

    fn root(&self) -> String {
        self.project.root.disk_text()
    }

    fn strip_root(&self, abs: &str) -> String {
        abs.strip_prefix(&format!("{}/", self.root()))
            .unwrap_or(abs)
            .to_string()
    }

    /// `_adopt_resolve_dest`: the adoption, or the refusal reason.
    pub fn resolve(
        &mut self,
        raw: &str,
        err: &mut dyn Write,
    ) -> Result<Result<Adoption, String>, Error> {
        let abs = self.paths.absolute(raw);
        let Some(canonical) = self.paths.canonicalize_with_existing_ancestor(&abs) else {
            return Ok(Err(format!("Cannot resolve path: {raw}")));
        };
        if !paths::is_within(&canonical, &self.paths.root_canonical) {
            return Ok(Err(format!("Path is outside the project: {raw}")));
        }
        if !Path::new(&abs).is_file() {
            return Ok(Err(format!("Destination file not found: {raw}")));
        }
        let dest_rel = self.strip_root(&abs);
        if let Some((_, slug)) = self.blocked_agents.iter().find(|(dest, _)| dest == &abs) {
            return Ok(Err(format!(
                "{slug} has generated content in {dest_rel}. Edit the source AGENTS.md and rules instead."
            )));
        }
        for slug in self.tools.clone() {
            let tool = Tool::load(self.project, &slug)?;
            if let Some(found) = self.try_tool(&tool, &abs, &dest_rel, err)? {
                return Ok(found);
            }
        }
        Ok(Err(format!(
            "{dest_rel} is not a recognised AgentSync output (no enabled tool produces it)."
        )))
    }

    fn dest_for(&self, tool: &Tool, key: &str) -> Option<String> {
        if tool.flag(&format!("targets.{key}.enabled")) == Some(false) {
            return None;
        }
        let raw = tool.value(&format!("targets.{key}.dest"));
        if raw.is_empty() {
            return None;
        }
        self.paths.resolve_dest(
            &raw,
            &format!("targets.{key}.dest for {}", tool.slug),
            &mut Log::default(),
        )
    }

    fn adoption(&self, tool: &Tool, resource: &'static str, dest: (&str, &str)) -> Adoption {
        Adoption {
            tool: tool.slug.clone(),
            resource,
            dest_abs: dest.0.to_string(),
            dest_rel: dest.1.to_string(),
            source_abs: String::new(),
            source_rel: String::new(),
        }
    }

    /// `_adopt_try_tool`: `None` when the tool produces no such output.
    fn try_tool(
        &mut self,
        tool: &Tool,
        abs: &str,
        dest_rel: &str,
        err: &mut dyn Write,
    ) -> Result<Option<Result<Adoption, String>>, Error> {
        let dest = (abs, dest_rel);
        if self.dest_for(tool, "agents").as_deref() == Some(abs) {
            if tool.flag("targets.agents.adoptable") == Some(false) {
                return Ok(Some(Err(format!(
                    "{} has generated content in {}. Edit the source AGENTS.md and rules instead.",
                    tool.slug, dest_rel
                ))));
            }
            return Ok(Some(
                self.agents_source(tool, self.adoption(tool, "agents", dest)),
            ));
        }
        if self.dest_for(tool, "settings").as_deref() == Some(abs) {
            if tool.value("targets.mcp.format") == "codex_toml"
                && let Some(mcp) = self.payload_source(tool, "mcp", err)?
            {
                let settings = self
                    .payload_source(tool, "settings", err)?
                    .map(|source| self.strip_root(&source.shown()))
                    .unwrap_or_default();
                return Ok(Some(Err(format!(
                    "Codex config.toml is a multi-source output. Edit {settings} and {} separately.",
                    self.strip_root(&mcp.shown())
                ))));
            }
            if tool.value("targets.mcp.format") == "opencode_json"
                && let Some(mcp) = self.payload_source(tool, "mcp", err)?
            {
                let settings = self
                    .payload_source(tool, "settings", err)?
                    .map(|source| self.strip_root(&source.shown()))
                    .unwrap_or_default();
                return Ok(Some(Err(format!(
                    "OpenCode opencode.json is a multi-source output. Edit {settings} and {} separately.",
                    self.strip_root(&mcp.shown())
                ))));
            }
            return Ok(Some(
                self.payload_target(tool, self.adoption(tool, "settings", dest))?,
            ));
        }
        for resource in ["mcp", "hooks"] {
            if self.dest_for(tool, resource).as_deref() == Some(abs) {
                return Ok(Some(
                    self.payload_target(tool, self.adoption(tool, resource, dest))?,
                ));
            }
        }
        let mut best: Option<(&'static str, String)> = None;
        for key in ["rules", "skills", "commands", "subagents"] {
            let Some(dir) = self.dest_for(tool, key) else {
                continue;
            };
            let inside = abs.starts_with(&format!("{dir}/"));
            if inside && dir.len() > best.as_ref().map_or(0, |(_, d)| d.len()) {
                best = Some((key, dir));
            }
        }
        Ok(best.map(|(key, dir)| self.dir_source(tool, self.adoption(tool, key, dest), &dir)))
    }

    /// `resolve_payload_source`, printing its legacy-layout warning once.
    fn payload_source(
        &mut self,
        tool: &Tool,
        resource: &str,
        err: &mut dyn Write,
    ) -> Result<Option<Source>, Error> {
        let (source, legacy) = payload::effective_source(self.project, tool, resource)?;
        if let Some(path) = legacy
            && !self.warned_legacy
        {
            self.warned_legacy = true;
            put(
                err,
                payload::legacy_warning(self.project, &path, self.style).as_bytes(),
            )?;
        }
        Ok(source)
    }

    /// `_adopt_resolve_agents_source`.
    fn agents_source(&self, tool: &Tool, mut found: Adoption) -> Result<Adoption, String> {
        let over = tool.value("targets.agents.source");
        let raw = if over.is_empty() {
            self.sources.agents.clone()
        } else {
            over
        };
        if raw.is_empty() {
            return Err(format!(
                "No agents source resolved for {} — set source.agents in agent_sync.yaml or place AGENTS.md in .ai/src/.",
                found.tool
            ));
        }
        if crate::paths::is_absolute(&raw) {
            found.source_rel = self.strip_root(&raw);
            found.source_abs = raw;
        } else {
            found.source_abs = format!("{}/{raw}", self.root());
            found.source_rel = raw;
        }
        Ok(found)
    }

    /// `_adopt_resolve_payload_target`.
    fn payload_target(
        &self,
        tool: &Tool,
        mut found: Adoption,
    ) -> Result<Result<Adoption, String>, Error> {
        let resource = found.resource;
        let existing = match payload::find_new_override(self.project, &tool.slug, resource)? {
            Some(path) => Some(path),
            None => payload::legacy_override_path(self.project, tool, resource)
                .filter(|path| path.is_file()),
        };
        let root = self.root();
        let chosen = if let Some(path) = existing {
            Some(path.disk_text())
        } else {
            let declared = if self.project.user_tool_file(&tool.slug).is_file() {
                tool.user_value(&format!("targets.{resource}.source"))
            } else {
                String::new()
            };
            let declared_abs = if declared.is_empty() || crate::paths::is_absolute(&declared) {
                declared
            } else {
                format!("{root}/{declared}")
            };
            if declared_abs.starts_with(&format!("{root}/")) {
                Some(declared_abs)
            } else {
                payload::override_path(self.project, tool, resource).map(|path| path.disk_text())
            }
        };
        let Some(abs) = chosen else {
            return Ok(Err(format!(
                "No base template for {} {resource} — cannot pick a canonical override path.",
                tool.slug
            )));
        };
        found.source_rel = self.strip_root(&abs);
        found.source_abs = abs;
        Ok(Ok(found))
    }

    /// `_adopt_resolve_dir_source`.
    fn dir_source(
        &self,
        tool: &Tool,
        mut found: Adoption,
        dest_dir: &str,
    ) -> Result<Adoption, String> {
        let key = found.resource;
        let slug = &tool.slug;
        let value = |path: &str| tool.value(path);
        let refusal = match key {
            "rules" if value("targets.rules.merge_to_file") == "true" => Some(format!(
                "{slug} merges rules into a single file. Edit the source rules in {}/ instead.",
                self.sources.rules
            )),
            "rules" if value("targets.rules.inline_into_agents") == "true" => Some(format!(
                "{slug} inlines rules into AGENTS.md. Edit the source rules in {}/ instead.",
                self.sources.rules
            )),
            "rules"
                if !value("targets.rules.header").is_empty()
                    || !value("targets.rules.scoped_header").is_empty() =>
            {
                Some(format!(
                    "{slug} injects a frontmatter header on sync. Adopting would propagate it to other tools' rule files. Edit {}/ instead.",
                    self.sources.rules
                ))
            }
            "skills" if value("targets.skills.inline_into_agents") == "true" => Some(format!(
                "{slug} inlines a skill index into AGENTS.md. Edit {}/ instead.",
                self.sources.skills
            )),
            "commands" if value("targets.commands.format") == "toml" => Some(format!(
                "{slug} serializes commands as TOML. Conversion is not reversible — edit {}/ instead.",
                self.sources.commands
            )),
            "subagents" => {
                let format = value("targets.subagents.format");
                matches!(format.as_str(), "toml" | "amazonq_json" | "opencode_md").then(|| {
                    format!(
                        "{slug} serializes subagents as {format}. Conversion is not reversible — edit {}/ instead.",
                        self.sources.subagents
                    )
                })
            }
            _ => None,
        };
        if let Some(reason) = refusal {
            return Err(reason);
        }

        let over = value(&format!("targets.{key}.source"));
        let fallback = match key {
            "rules" => &self.sources.rules,
            "skills" => &self.sources.skills,
            "commands" => &self.sources.commands,
            _ => &self.sources.subagents,
        };
        let raw = if over.is_empty() {
            fallback.clone()
        } else {
            over
        };
        let src_root = if raw.is_empty() {
            None
        } else {
            self.paths.resolve_source(
                &raw,
                &format!("targets.{key}.source for {slug}"),
                &mut Log::default(),
            )
        };
        let Some(src_root) = src_root else {
            return Err(format!("No source directory resolved for {slug} {key}."));
        };

        let mut rel_inside = found
            .dest_abs
            .strip_prefix(&format!("{dest_dir}/"))
            .unwrap_or(&found.dest_abs)
            .to_string();
        if key != "skills" {
            let ext = value(&format!("targets.{key}.extension"));
            if !ext.is_empty()
                && let Some(stem) = rel_inside.strip_suffix(&ext)
            {
                rel_inside = format!("{stem}.md");
            }
        }
        found.source_abs = format!("{src_root}/{rel_inside}");
        found.source_rel = self.strip_root(&found.source_abs);
        Ok(found)
    }
}

pub fn adopt(
    args: &[String],
    discover: Discover,
    style: &Style,
    interactive: bool,
    confirm: Confirm,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let (mut dry_run, mut assume_yes, mut all) = (false, false, false);
    let mut dest = String::new();
    for arg in args {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--yes" | "-y" => assume_yes = true,
            "--all" | "-a" => all = true,
            "--help" | "-h" => {
                put(out, HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            flag if flag.starts_with('-') => {
                put(
                    err,
                    format!("{}: unknown flag: {flag}\n", style.red("Error")).as_bytes(),
                )?;
                return Ok(2);
            }
            _ if !dest.is_empty() => {
                put(
                    err,
                    format!(
                        "{}: adopt accepts a single destination file\n",
                        style.red("Error")
                    )
                    .as_bytes(),
                )?;
                return Ok(2);
            }
            value => dest = value.to_string(),
        }
    }
    if all && !dest.is_empty() {
        put(
            err,
            format!("{}: adopt --all takes no <dest-file>\n", style.red("Error")).as_bytes(),
        )?;
        return Ok(2);
    }
    if !all && dest.is_empty() {
        put(
            err,
            format!(
                "{}: missing <dest-file>\n{}",
                style.red("Error"),
                HELP.render(style)
            )
            .as_bytes(),
        )?;
        return Ok(2);
    }

    let project = match discover() {
        Ok(project) => project,
        Err(Error::ConfigPathNotFound(path)) => {
            put(
                err,
                format!(
                    "{}: AGENTSYNC_CONFIG_PATH is set but file not found: {}\n",
                    style.red("Error"),
                    path.disk_text()
                )
                .as_bytes(),
            )?;
            return Ok(2);
        }
        Err(other) => return Err(other),
    };
    if !project.tools_dir_in_project() {
        return super::refuse_outside_tools_dir(&project, style, err);
    }
    let sources = discover_sources(&project)?;
    let root = project.root.disk_text();
    let loaded = Manifest::load(&root)?;
    if loaded.is_none() && all {
        put(
            err,
            format!(
                "{}: no .ai/.sync-manifest yet — run {} first, or adopt one file at a time.\n",
                style.red("Error"),
                style.cyan("agentsync sync")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let mut resolver = Resolver::new(&project, sources, style)?.for_adopt()?;
    let mut run = Run {
        style,
        root: &root,
        interactive,
        confirm,
        out,
        err,
    };
    match loaded {
        Some(manifest) if all => adopt_all(&mut run, &mut resolver, &manifest, dry_run, assume_yes),
        manifest => adopt_one(
            &mut run,
            &mut resolver,
            manifest.as_ref(),
            &dest,
            dry_run,
            assume_yes,
        ),
    }
}

struct Run<'a> {
    style: &'a Style,
    root: &'a str,
    interactive: bool,
    confirm: Confirm<'a>,
    out: &'a mut dyn Write,
    err: &'a mut dyn Write,
}

fn hash(path: &str) -> Option<String> {
    template_manifest::hash(Path::new(path))
}

/// `cp <dest> <source>` after `ensure_dir`: an existing source keeps its mode,
/// a new one takes the destination's mode under the umask.
pub(crate) fn copy_into_source(found: &Adoption) -> Result<(), Error> {
    let source = Path::new(&found.source_abs);
    if let Some(parent) = source.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
    }
    let bytes = std::fs::read(&found.dest_abs).map_err(|e| Error::io(&found.dest_abs, e))?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let mode = std::fs::metadata(&found.dest_abs)
            .map_err(|e| Error::io(&found.dest_abs, e))?
            .permissions()
            .mode();
        options.mode(mode & 0o7777);
    }
    options
        .open(source)
        .and_then(|mut file| file.write_all(&bytes))
        .map_err(|e| Error::io(source, e))
}

/// Whether to go on: refuses off a terminal without `--yes`, then asks.
fn confirmed(run: &mut Run, assume_yes: bool, question: &str) -> Result<Option<u8>, Error> {
    let style = run.style;
    if assume_yes {
        return Ok(None);
    }
    if !run.interactive {
        put(
            run.err,
            format!(
                "{}: refusing to adopt non-interactively without --yes.\n",
                style.red("Error")
            )
            .as_bytes(),
        )?;
        return Ok(Some(1));
    }
    if !(run.confirm)(question) {
        put(run.out, format!("{}\n", style.dim("Cancelled.")).as_bytes())?;
        return Ok(Some(0));
    }
    Ok(None)
}

fn verify_hint(style: &Style) -> String {
    format!(
        "{} {} {}\n",
        style.dim("Run"),
        style.cyan("agentsync sync"),
        style.dim("to verify everything is consistent.")
    )
}

/// `diff -u --label <source> --label <dest> <source> <dest> | head -n 40`.
fn plan_diff(found: &Adoption) -> String {
    let Ok(output) = Command::new("diff")
        .args([
            "-u",
            "--label",
            &found.source_rel,
            "--label",
            &found.dest_rel,
            &found.source_abs,
            &found.dest_abs,
        ])
        .output()
    else {
        return String::new();
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let head: String = text.split_inclusive('\n').take(40).collect();
    head.trim_end_matches('\n').to_string()
}

fn adopt_one(
    run: &mut Run,
    resolver: &mut Resolver,
    manifest: Option<&Manifest>,
    dest: &str,
    dry_run: bool,
    assume_yes: bool,
) -> Result<u8, Error> {
    let style = run.style;
    let found = match resolver.resolve(dest, run.err)? {
        Ok(found) => found,
        Err(reason) => {
            put(
                run.err,
                format!("{}: {reason}\n", style.red("Cannot adopt")).as_bytes(),
            )?;
            return Ok(1);
        }
    };
    if let Some(manifest) = manifest
        && !manifest.paths().contains(&found.dest_rel)
    {
        put(
            run.err,
            format!(
                "{}: {} is not tracked in the manifest.\n  AgentSync only adopts files it produced. Run sync first to register the file.\n",
                style.red("Cannot adopt"),
                found.dest_rel
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let Some(current) = hash(&found.dest_abs) else {
        put(
            run.err,
            format!("{}: cannot hash {}\n", style.red("Error"), found.dest_rel).as_bytes(),
        )?;
        return Ok(1);
    };
    let source_exists = Path::new(&found.source_abs).is_file();
    if source_exists && hash(&found.source_abs).as_deref() == Some(current.as_str()) {
        put(
            run.out,
            format!(
                "{}\n",
                style.dim(&format!(
                    "Nothing to adopt: {} already matches the source.",
                    found.dest_rel
                ))
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }

    let mut plan = format!(
        "\n{}\n    {}     {}\n    {} {}\n    {}     {} {}\n    {}       {} {}\n\n",
        style.bold("  Adopt plan"),
        style.dim("tool:"),
        style.cyan(&found.tool),
        style.dim("resource:"),
        found.resource,
        style.dim("from:"),
        style.yellow(&found.dest_rel),
        style.dim("(destination — your edit)"),
        style.dim("to:"),
        style.green(&found.source_rel),
        style.dim("(source)")
    );
    if !source_exists {
        plan.push_str(&format!(
            "    {}\n\n",
            style.dim("(creating new source file)")
        ));
    } else {
        let diff = plan_diff(&found);
        if !diff.is_empty() {
            for line in diff.split('\n') {
                plan.push_str(&format!("    {line}\n"));
            }
            plan.push('\n');
        }
    }
    put(run.out, plan.as_bytes())?;

    if dry_run {
        put(
            run.out,
            format!("{}\n", style.dim("Dry-run — nothing written.")).as_bytes(),
        )?;
        return Ok(0);
    }
    if let Some(status) = confirmed(run, assume_yes, "Apply this adoption?")? {
        return Ok(status);
    }
    copy_into_source(&found)?;
    let mut done = format!("\n{} Wrote {}\n", style.green("✓"), found.source_rel);
    if manifest.is_some() {
        manifest::update_entry(run.root, &found.dest_rel, &current)?;
        done.push_str(&format!(
            "{} Updated .ai/.sync-manifest\n",
            style.green("✓")
        ));
    }
    done.push('\n');
    done.push_str(&verify_hint(style));
    put(run.out, done.as_bytes())?;
    Ok(0)
}

fn adopt_all(
    run: &mut Run,
    resolver: &mut Resolver,
    manifest: &Manifest,
    dry_run: bool,
    assume_yes: bool,
) -> Result<u8, Error> {
    let style = run.style;
    let mut planned: Vec<(Adoption, String)> = Vec::new();
    let mut skipped: Vec<(String, String)> = Vec::new();
    for rel in manifest.drift(run.root) {
        match resolver.resolve(&format!("{}/{rel}", run.root), run.err)? {
            Err(reason) => skipped.push((rel, reason)),
            Ok(found) => match hash(&found.dest_abs) {
                Some(current) => planned.push((found, current)),
                None => skipped.push((rel, "cannot hash destination".to_string())),
            },
        }
    }
    let ok: Vec<bool> = planned
        .iter()
        .enumerate()
        .map(|(i, (found, current))| {
            !planned.iter().enumerate().any(|(j, (other, other_hash))| {
                i != j && found.source_abs == other.source_abs && current != other_hash
            })
        })
        .collect();
    for ((found, _), fine) in planned.iter().zip(&ok) {
        if !fine {
            skipped.push((
                found.dest_rel.clone(),
                format!(
                    "multiple edited outputs map to {} — adopt one explicitly",
                    found.source_rel
                ),
            ));
        }
    }
    let ok_count = ok.iter().filter(|fine| **fine).count();

    if ok_count == 0 && skipped.is_empty() {
        put(
            run.out,
            format!(
                "{}\n",
                style.dim("Nothing to adopt: every tracked output matches its source.")
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }

    let mut plan = format!("\n{}\n", style.bold("  Adopt plan (--all)"));
    if ok_count > 0 {
        plan.push_str(&format!(
            "    {ok_count} file(s) will be promoted to source:\n\n"
        ));
        for ((found, _), _) in planned.iter().zip(&ok).filter(|(_, fine)| **fine) {
            plan.push_str(&format!(
                "    {}  {} {} {}\n",
                style.cyan(&found.tool),
                style.yellow(&found.dest_rel),
                style.dim("→"),
                style.green(&found.source_rel)
            ));
        }
        plan.push('\n');
    }
    if !skipped.is_empty() {
        plan.push_str(&format!(
            "    {}\n",
            style.dim(&format!(
                "{} skipped (edit .ai/src/ directly):",
                skipped.len()
            ))
        ));
        for (rel, reason) in &skipped {
            plan.push_str(&format!(
                "    {} {} {}\n",
                style.yellow(rel),
                style.dim("—"),
                style.dim(reason)
            ));
        }
        plan.push('\n');
    }
    put(run.out, plan.as_bytes())?;

    if ok_count == 0 {
        put(
            run.out,
            format!(
                "{}\n",
                style.dim("No adoptable edits — the drifted files above need manual source edits.")
            )
            .as_bytes(),
        )?;
        return Ok(0);
    }
    if dry_run {
        put(
            run.out,
            format!("{}\n", style.dim("Dry-run — nothing written.")).as_bytes(),
        )?;
        return Ok(0);
    }
    let question = format!("Apply these {ok_count} adoption(s)?");
    if let Some(status) = confirmed(run, assume_yes, &question)? {
        return Ok(status);
    }

    put(run.out, b"\n")?;
    for ((found, current), _) in planned.iter().zip(&ok).filter(|(_, fine)| **fine) {
        copy_into_source(found)?;
        manifest::update_entry(run.root, &found.dest_rel, current)?;
        put(
            run.out,
            format!(
                "{} {} {}\n",
                style.green("✓"),
                style.dim("adopted"),
                found.source_rel
            )
            .as_bytes(),
        )?;
    }
    put(
        run.out,
        format!(
            "\n{} Adopted {ok_count} file(s) into .ai/src/ and refreshed .ai/.sync-manifest\n\n{}",
            style.green("✓"),
            verify_hint(style)
        )
        .as_bytes(),
    )?;
    Ok(0)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn project(files: &[(&str, &str)]) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap().disk_text();
        for (rel, text) in files {
            let path = format!("{root}/{rel}");
            std::fs::create_dir_all(paths::parent(&path)).unwrap();
            std::fs::write(path, text).unwrap();
        }
        (dir, root)
    }

    fn manifest_of(root: &str, rels: &[(&str, &str)]) {
        let text: String = rels
            .iter()
            .map(|(rel, content)| format!("{rel}\t{}\n", manifest::sha256_hex(content.as_bytes())))
            .collect();
        std::fs::write(format!("{root}/{}", manifest::REL), text).unwrap();
    }

    fn call(root: &str, args: &[&str], interactive: bool, accept: bool) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let discover = || Project::at(root);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = adopt(
            &args,
            &discover,
            &Style::plain(),
            interactive,
            &mut |_| accept,
            &mut out,
            &mut err,
        )
        .unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    const SOURCES: [(&str, &str); 4] = [
        (".ai/agent_sync.yaml", "tools:\n  enabled:\n    - claude\n"),
        (".ai/src/AGENTS.md", "# Agents\n"),
        (".ai/src/rules/core.md", "# Core\n\nBody.\n"),
        (".ai/src/commands/go.md", "---\ndescription: Go\n---\nGo.\n"),
    ];

    #[test]
    fn a_destination_maps_to_its_source_or_to_the_bash_refusal() {
        let mut files = SOURCES.to_vec();
        files.extend([
            ("CLAUDE.md", "# Agents\n"),
            (".clinerules/workflows/go.md", "Go.\n"),
            (".github/prompts/go.prompt.md", "Go.\n"),
            (".cursor/rules/core.mdc", "---\n---\n# Core\n"),
            (".claude/settings.json", "{}\n"),
            ("README.md", "readme\n"),
        ]);
        let (_dir, root) = project(&files);
        let project = Project::at(&root).unwrap();
        let style = Style::plain();
        let mut resolver =
            Resolver::new(&project, discover_sources(&project).unwrap(), &style).unwrap();
        let mut err = Vec::new();
        let mut resolve = |raw: &str| {
            resolver
                .resolve(raw, &mut err)
                .unwrap()
                .map(|found| (found.tool, found.resource, found.source_rel))
        };
        assert_eq!(
            resolve("CLAUDE.md"),
            Ok((
                "claude".to_string(),
                "agents",
                ".ai/src/AGENTS.md".to_string()
            ))
        );
        assert_eq!(
            resolve(".clinerules/workflows/go.md"),
            Ok((
                "cline".to_string(),
                "commands",
                ".ai/src/commands/go.md".to_string()
            ))
        );
        assert_eq!(
            resolve(".github/prompts/go.prompt.md"),
            Ok((
                "copilot".to_string(),
                "commands",
                ".ai/src/commands/go.md".to_string()
            ))
        );
        assert_eq!(
            resolve(".claude/settings.json"),
            Ok((
                "claude".to_string(),
                "settings",
                ".ai/src/tools/claude/settings.json".to_string()
            ))
        );
        assert_eq!(
            resolve(".cursor/rules/core.mdc"),
            Err("cursor injects a frontmatter header on sync. Adopting would propagate it to other tools' rule files. Edit .ai/src/rules/ instead.".to_string())
        );
        assert_eq!(
            resolve("../outside.md"),
            Err("Path is outside the project: ../outside.md".to_string())
        );
        assert_eq!(
            resolve(".claude/rules/nope.md"),
            Err("Destination file not found: .claude/rules/nope.md".to_string())
        );
        assert_eq!(
            resolve("README.md"),
            Err(
                "README.md is not a recognised AgentSync output (no enabled tool produces it)."
                    .to_string()
            )
        );
    }

    #[test]
    fn the_project_source_keys_move_the_detected_layout() {
        let (_dir, root) = project(&[
            (
                ".ai/agent_sync.yaml",
                "tools:\n  enabled: []\nsource:\n  rules: \"docs/rules\"\ncommands: \"docs/commands\"\n",
            ),
            (".ai/src/AGENTS.md", "# A\n"),
            (".ai/src/rules/core.md", "# Core\n"),
            (".ai/skills/s/SKILL.md", "s\n"),
        ]);
        let project = Project::at(&root).unwrap();
        assert_eq!(
            discover_sources(&project).unwrap(),
            Sources {
                agents: ".ai/src/AGENTS.md".to_string(),
                rules: "docs/rules".to_string(),
                skills: ".ai/skills".to_string(),
                commands: "docs/commands".to_string(),
                subagents: String::new(),
            }
        );
    }

    #[test]
    fn one_file_is_planned_confirmed_written_and_recorded_like_bash() {
        let mut files = SOURCES.to_vec();
        files.push(("CLAUDE.md", "# Agents\n\nEdited.\n"));
        let (_dir, root) = project(&files);
        manifest_of(&root, &[("CLAUDE.md", "# Agents\n")]);
        let plan = "\n  Adopt plan\n    tool:     claude\n    resource: agents\n    from:     CLAUDE.md (destination — your edit)\n    to:       .ai/src/AGENTS.md (source)\n\n    --- .ai/src/AGENTS.md\n    +++ CLAUDE.md\n    @@ -1 +1,3 @@\n     # Agents\n    +\n    +Edited.\n\n";

        assert_eq!(
            call(&root, &["CLAUDE.md"], false, true),
            (
                1,
                plan.to_string(),
                "Error: refusing to adopt non-interactively without --yes.\n".to_string()
            )
        );
        assert_eq!(
            call(&root, &["--dry-run", "CLAUDE.md"], false, true).1,
            format!("{plan}Dry-run — nothing written.\n")
        );
        assert_eq!(
            call(&root, &["CLAUDE.md"], true, false),
            (0, format!("{plan}Cancelled.\n"), String::new())
        );
        assert_eq!(
            std::fs::read_to_string(format!("{root}/.ai/src/AGENTS.md")).unwrap(),
            "# Agents\n"
        );

        assert_eq!(
            call(&root, &["--yes", "CLAUDE.md"], false, false),
            (
                0,
                format!(
                    "{plan}\n✓ Wrote .ai/src/AGENTS.md\n✓ Updated .ai/.sync-manifest\n\nRun agentsync sync to verify everything is consistent.\n"
                ),
                String::new()
            )
        );
        assert_eq!(
            std::fs::read_to_string(format!("{root}/.ai/src/AGENTS.md")).unwrap(),
            "# Agents\n\nEdited.\n"
        );
        assert_eq!(
            std::fs::read_to_string(format!("{root}/{}", manifest::REL)).unwrap(),
            format!(
                "CLAUDE.md\t{}\n",
                manifest::sha256_hex(b"# Agents\n\nEdited.\n")
            )
        );
        assert_eq!(
            call(&root, &["CLAUDE.md"], false, false).1,
            "Nothing to adopt: CLAUDE.md already matches the source.\n"
        );
    }

    #[test]
    fn all_skips_refusals_and_same_source_conflicts_like_bash() {
        let mut files = SOURCES.to_vec();
        files.extend([
            (".claude/rules/core.md", "# Core\n\nClaude edit.\n"),
            (".amazonq/rules/core.md", "# Core\n\nAmazon edit.\n"),
            (".cursor/rules/core.mdc", "edited\n"),
            (".claude/skills/foo/SKILL.md", "Skill two.\n"),
            (".ai/src/skills/foo/SKILL.md", "Skill.\n"),
        ]);
        let (_dir, root) = project(&files);
        manifest_of(
            &root,
            &[
                (".amazonq/rules/core.md", "# Core\n\nBody.\n"),
                (".claude/rules/core.md", "# Core\n\nBody.\n"),
                (".claude/skills/foo/SKILL.md", "Skill.\n"),
                (".cursor/rules/core.mdc", "generated\n"),
            ],
        );
        let plan = "\n  Adopt plan (--all)\n    1 file(s) will be promoted to source:\n\n    claude  .claude/skills/foo/SKILL.md → .ai/src/skills/foo/SKILL.md\n\n    3 skipped (edit .ai/src/ directly):\n    .cursor/rules/core.mdc — cursor injects a frontmatter header on sync. Adopting would propagate it to other tools' rule files. Edit .ai/src/rules/ instead.\n    .amazonq/rules/core.md — multiple edited outputs map to .ai/src/rules/core.md — adopt one explicitly\n    .claude/rules/core.md — multiple edited outputs map to .ai/src/rules/core.md — adopt one explicitly\n\n";
        assert_eq!(
            call(&root, &["--all", "--dry-run"], false, false),
            (
                0,
                format!("{plan}Dry-run — nothing written.\n"),
                String::new()
            )
        );
        assert_eq!(
            call(&root, &["-a", "-y"], false, false).1,
            format!(
                "{plan}\n✓ adopted .ai/src/skills/foo/SKILL.md\n\n✓ Adopted 1 file(s) into .ai/src/ and refreshed .ai/.sync-manifest\n\nRun agentsync sync to verify everything is consistent.\n"
            )
        );
        assert_eq!(
            std::fs::read_to_string(format!("{root}/.ai/src/skills/foo/SKILL.md")).unwrap(),
            "Skill two.\n"
        );
    }

    #[test]
    fn help_renders_in_the_shared_shape() {
        let (_dir, root) = project(&SOURCES);
        assert_eq!(
            call(&root, &["--help"], false, false),
            (
                0,
                "\n  agentsync adopt — promote a manual edit back into .ai/src/\n\n  USAGE\n    agentsync adopt <dest-file> [OPTIONS]\n    agentsync adopt --all [OPTIONS]\n\n  DESCRIPTION\n    Promote a manual edit in a destination file back into .ai/src/ as the\n    new canonical content. Refuses transformed targets (merged rules,\n    inlined skills, format-converted commands/subagents).\n\n    With --all, adopt every drifted (manually-edited) tracked output at\n    once, skipping refused targets and same-source conflicts.\n\n  OPTIONS\n    -a, --all    Adopt every drifted output (no <dest-file>)\n    --dry-run    Show the plan without writing\n    -y, --yes    Skip confirmation (required outside a TTY)\n    -h, --help   Show this help\n\n  EXAMPLES\n    agentsync adopt CLAUDE.md\n    agentsync adopt .claude/rules/core.md --dry-run\n    agentsync adopt --all --yes\n\n".to_string(),
                String::new()
            )
        );
    }

    #[test]
    fn arguments_are_refused_with_the_bash_statuses() {
        let (_dir, root) = project(&SOURCES);
        let refused = |args: &[&str]| {
            let (status, _, err) = call(&root, args, false, false);
            (status, err)
        };
        assert_eq!(
            refused(&[]),
            (
                2,
                format!(
                    "Error: missing <dest-file>\n{}",
                    HELP.render(&Style::plain())
                )
            )
        );
        assert_eq!(
            refused(&["--bogus"]),
            (2, "Error: unknown flag: --bogus\n".to_string())
        );
        assert_eq!(
            refused(&["a", "b"]),
            (
                2,
                "Error: adopt accepts a single destination file\n".to_string()
            )
        );
        assert_eq!(
            refused(&["--all", "CLAUDE.md"]),
            (2, "Error: adopt --all takes no <dest-file>\n".to_string())
        );
        assert_eq!(
            refused(&["--all"]),
            (
                1,
                "Error: no .ai/.sync-manifest yet — run agentsync sync first, or adopt one file at a time.\n"
                    .to_string()
            )
        );
        assert_eq!(
            refused(&["CLAUDE.md"]),
            (
                1,
                "Cannot adopt: Destination file not found: CLAUDE.md\n".to_string()
            )
        );
    }
}
