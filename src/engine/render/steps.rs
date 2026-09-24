//! The per-target steps of one tool: rules, skills, commands, subagents, payloads, and the OpenCode composition.

use super::passes::{Dests, source_path, tool_source};
use super::{Run, Step, Stop, io, tools};
use crate::config::tool::Tool;
use crate::engine::keyed;
use crate::engine::rules::{self, Conversion, RuleOptions};
use crate::engine::session::Session;
use crate::{config::payload, engine::codex_toml, engine::file_ops, engine::opencode_json, paths};

pub(super) fn sync_rules_step(
    s: &mut Session,
    run: &Run,
    tool: &Tool,
    dests: &Dests,
    display: &str,
) -> Step {
    let src_agents = tool_source(s, tool, "agents", &run.sources.agents, display)?;
    let src_rules = tool_source(s, tool, "rules", &run.sources.rules, display)?;
    let include = tool.filter("targets.rules.include");
    let exclude = tool.filter("targets.rules.exclude");

    if tool.value("targets.rules.inline_into_agents") == "true" && !dests.agents.is_empty() {
        if s.dry_run {
            s.log.step(&format!(
                "Would append rule references to {} (dry-run)",
                paths::leaf(&dests.agents)
            ));
        } else {
            inline_rules_into_agents(s, &src_rules, &dests.agents, &include, &exclude)?;
        }
    } else if !dests.rules.is_empty() {
        if tool.value("targets.rules.merge_to_file") == "true" {
            let prepend = (tool.value("targets.rules.prepend_agents") == "true"
                && s.ws.is_file(&src_agents))
            .then_some(src_agents.as_str());
            rules::merge_rules_to_file(s, &src_rules, &dests.rules, &include, &exclude, prepend)
                .map_err(|e| io(s, e))?;
        } else {
            let extension = tool.value("targets.rules.extension");
            let header = tool.value("targets.rules.header");
            let scoped_header = tool.value("targets.rules.scoped_header");
            let opts = RuleOptions {
                extension: &extension,
                header: &header,
                scoped_header: &scoped_header,
                include: &include,
                exclude: &exclude,
            };
            rules::sync_rules(s, &src_rules, &dests.rules, &opts).map_err(|e| io(s, e))?;
            if tool.value("targets.rules.append_imports") == "true" && !s.dry_run {
                if dests.agents.is_empty() {
                    s.log.warning(&format!(
                        "Skipping append_imports for {display} because targets.agents.dest is missing"
                    ));
                } else {
                    rules::append_imports(s, &dests.agents, &dests.rules).map_err(|e| io(s, e))?;
                    s.log.step(&format!(
                        "Appended @rules imports to {}",
                        paths::leaf(&dests.agents)
                    ));
                }
            }
        }
    }

    if !dests.agents.is_empty()
        && !dests.rules.is_empty()
        && dests.agents.starts_with(&format!("{}/", dests.rules))
        && !s.dry_run
    {
        let _ = file_ops::copy_file(s, &src_agents, &dests.agents);
    }
    Ok(())
}

/// `_inline_rules_into_agents`.
fn inline_rules_into_agents(
    s: &mut Session,
    src_rules: &str,
    dest_agents: &str,
    include: &str,
    exclude: &str,
) -> Step {
    if !s.ws.is_dir(src_rules) {
        return Ok(());
    }
    let mut block = "\n\n## Rules\n\nThe following rule files define project constraints. Read them before making changes:\n\n"
        .as_bytes()
        .to_vec();
    for name in s.ws.glob(src_rules) {
        let path = format!("{src_rules}/{name}");
        if !name.ends_with(".md")
            || !s.ws.is_file(&path)
            || !crate::engine::filters::matches(&name, include, exclude)
        {
            continue;
        }
        let bytes = s.ws.read(&path).map_err(|e| io(s, e))?;
        let title = crate::text::lines(&bytes)
            .into_iter()
            .find(|line| line.starts_with(b"#"))
            .map(|line| {
                let without_hashes = &line[line.iter().take_while(|b| **b == b'#').count()..];
                let spaces = without_hashes.iter().take_while(|b| **b == b' ').count();
                without_hashes[spaces..].to_vec()
            })
            .unwrap_or_default();
        block.extend_from_slice(format!("- `{name}` — ").as_bytes());
        block.extend(title);
        block.push(b'\n');
    }
    block.extend_from_slice("\nFind all rules in `.ai/src/rules/`.\n".as_bytes());
    s.ws.append(dest_agents, &block).map_err(|e| io(s, e))?;
    s.record_write(dest_agents);
    s.log.step(&format!(
        "Appended rule references to {}",
        paths::leaf(dest_agents)
    ));
    Ok(())
}

fn skill_description(skill: &[u8]) -> Vec<u8> {
    let lines = crate::text::lines(skill);
    let mut in_range = false;
    let mut first = Vec::new();
    for line in &lines {
        if !in_range {
            in_range = *line == b"---";
            continue;
        }
        if *line == b"---" {
            in_range = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix(b"description:") {
            let rest = crate::text::trim_start_space(rest);
            let rest = match rest.strip_prefix(b">") {
                Some(after) => crate::text::trim_start_space(after),
                None => rest,
            };
            first = rest.to_vec();
            break;
        }
    }
    if first == b">" {
        first.clear();
    }
    if !first.is_empty() {
        return first;
    }
    let mut outer = false;
    let mut inner = false;
    for line in &lines {
        let mut closes_outer = false;
        if !outer {
            if *line != b"---" {
                continue;
            }
            outer = true;
        } else if *line == b"---" {
            closes_outer = true;
        }
        if !inner {
            inner = line.starts_with(b"description:");
        } else if line.first().is_some_and(u8::is_ascii_lowercase) {
            inner = false;
        } else if line.starts_with(b"  ") {
            return crate::text::trim_start_space(line).to_vec();
        }
        if closes_outer {
            outer = false;
        }
    }
    Vec::new()
}

/// `_inline_skills_into_file`.
fn inline_skills_into_file(
    s: &mut Session,
    src_skills: &str,
    target: &str,
    include: &str,
    exclude: &str,
) -> Step {
    let mut entries = Vec::new();
    for name in s.ws.glob(src_skills) {
        let dir = format!("{src_skills}/{name}");
        if !s.ws.is_dir(&dir) || !crate::engine::filters::matches(&name, include, exclude) {
            continue;
        }
        let skill_file = format!("{dir}/SKILL.md");
        let desc = if s.ws.is_file(&skill_file) {
            skill_description(&s.ws.read(&skill_file).map_err(|e| io(s, e))?)
        } else {
            Vec::new()
        };
        entries.extend_from_slice(format!("- `{name}`").as_bytes());
        if !desc.is_empty() {
            entries.extend_from_slice(" — ".as_bytes());
            entries.extend(desc);
        }
        entries.push(b'\n');
    }
    if entries.is_empty() {
        return Ok(());
    }
    let mut block = "\n## Skills\n\nThe following skills provide step-by-step workflows. Find them in `.ai/src/skills/`:\n\n"
        .as_bytes()
        .to_vec();
    block.extend(entries);
    s.ws.append(target, &block).map_err(|e| io(s, e))?;
    s.record_write(target);
    s.log
        .step(&format!("Appended skill index to {}", paths::leaf(target)));
    Ok(())
}

pub(super) fn sync_skills_step(
    s: &mut Session,
    run: &Run,
    tool: &Tool,
    dests: &Dests,
    display: &str,
) -> Step {
    let src_skills = tool_source(s, tool, "skills", &run.sources.skills, display)?;
    let include = tool.filter("targets.skills.include");
    let exclude = tool.filter("targets.skills.exclude");

    if !dests.skills.is_empty() {
        let effective = if exclude.is_empty() {
            "command-*".to_string()
        } else {
            format!("{exclude} command-*")
        };
        return file_ops::sync_dir(s, &src_skills, &dests.skills, &include, &effective)
            .map_err(|e| io(s, e));
    }
    if tool.value("targets.skills.inline_into_agents") == "true" && s.ws.is_dir(&src_skills) {
        let target = if !dests.agents.is_empty() {
            dests.agents.clone()
        } else if tool.value("targets.rules.merge_to_file") == "true" && s.ws.is_file(&dests.rules)
        {
            dests.rules.clone()
        } else {
            String::new()
        };
        if !target.is_empty() && !s.dry_run {
            inline_skills_into_file(s, &src_skills, &target, &include, &exclude)?;
        } else if s.dry_run {
            s.log.step("Would append skill index (dry-run)");
        }
    }
    Ok(())
}

pub(super) fn sync_commands_step(
    s: &mut Session,
    run: &Run,
    tool: &Tool,
    dests: &Dests,
    display: &str,
) -> Step {
    if run.sources.commands.is_empty() {
        return Ok(());
    }
    let include = tool.filter("targets.commands.include");
    let exclude = tool.filter("targets.commands.exclude");
    let label = format!("source.commands for {display}");
    let src = source_path(s, &run.sources.commands, &label)?;
    if !s.ws.is_dir(&src) {
        return Ok(());
    }

    if !dests.commands.is_empty() {
        let result = if tool.value("targets.commands.format") == "toml" {
            rules::sync_converted(s, &src, &dests.commands, Conversion::CommandToml)
        } else {
            let extension = tool.value("targets.commands.extension");
            let opts = RuleOptions {
                extension: &extension,
                header: "",
                scoped_header: "",
                include: "",
                exclude: "",
            };
            rules::sync_rules(s, &src, &dests.commands, &opts)
        };
        return result.map_err(|e| io(s, e));
    }
    if tool.value("targets.commands.as_skills") == "true" && !dests.skills.is_empty() {
        s.log
            .step("No native commands surface — generating skills (command-*) instead");
        return rules::sync_commands_as_skills(s, &src, &dests.skills, &include, &exclude)
            .map_err(|e| io(s, e));
    }
    if tool.value("targets.commands.inline_into_agents") == "true" {
        let target = if !dests.agents.is_empty() {
            dests.agents.clone()
        } else if tool.value("targets.rules.merge_to_file") == "true" && s.ws.is_file(&dests.rules)
        {
            dests.rules.clone()
        } else {
            String::new()
        };
        if !target.is_empty() && s.dry_run {
            s.log.step("Would append command index (dry-run)");
        } else if !target.is_empty() {
            s.log.step(&format!(
                "No native commands surface — appending command index to {}",
                paths::leaf(&target)
            ));
            rules::inline_commands_to_file(s, &src, &target, &include, &exclude)
                .map_err(|e| io(s, e))?;
        }
    }
    Ok(())
}

pub(super) fn sync_subagents_step(
    s: &mut Session,
    run: &Run,
    tool: &Tool,
    dests: &Dests,
    display: &str,
) -> Step {
    if dests.subagents.is_empty() || run.sources.subagents.is_empty() {
        return Ok(());
    }
    let label = format!("source.subagents for {display}");
    let src = source_path(s, &run.sources.subagents, &label)?;
    if !s.ws.is_dir(&src) {
        return Ok(());
    }
    let result = match tool.value("targets.subagents.format").as_str() {
        "toml" => rules::sync_converted(s, &src, &dests.subagents, Conversion::AgentToml),
        "amazonq_json" => {
            rules::sync_converted(s, &src, &dests.subagents, Conversion::AgentAmazonqJson)
        }
        "opencode_md" => {
            rules::sync_converted(s, &src, &dests.subagents, Conversion::AgentOpencodeMd)
        }
        _ => {
            let extension = tool.value("targets.subagents.extension");
            let opts = RuleOptions {
                extension: &extension,
                header: "",
                scoped_header: "",
                include: "",
                exclude: "",
            };
            rules::sync_rules(s, &src, &dests.subagents, &opts)
        }
    };
    result.map_err(|e| io(s, e))
}

pub(super) fn sync_payloads_step(s: &mut Session, tool: &Tool, dests: &Dests) -> Step {
    let root = s.paths.root.clone();
    let tools_dir = s.tools_dir.clone();
    let src_settings = if dests.settings.is_empty() {
        None
    } else {
        payload::resolve_source(s, tool, "settings")
    }
    .filter(|path| s.ws.is_file(path));
    let src_mcp = if dests.mcp.is_empty() {
        None
    } else {
        payload::resolve_source(s, tool, "mcp")
    }
    .filter(|path| s.ws.is_file(path));

    for resource in ["settings", "mcp"] {
        let ownership = tool.value(&format!("targets.{resource}.ownership"));
        if !matches!(ownership.as_str(), "" | "auto" | "keys" | "file") {
            s.log.error(&format!(
                "Unknown targets.{resource}.ownership for {}: {ownership} (expected auto, keys, or file)",
                tool.display_name()
            ));
            return Err(Stop(1));
        }
    }
    let keyed_settings = !dests.settings.is_empty() && tools::keyed(s, tool, "settings");
    let keyed_mcp = !dests.mcp.is_empty() && tools::keyed(s, tool, "mcp");
    let format = tool.value("targets.mcp.format");

    if format == "codex_toml" {
        if !dests.settings.is_empty() && !dests.mcp.is_empty() && dests.settings != dests.mcp {
            s.log
                .error("Codex settings and MCP destinations must match");
            return Err(Stop(1));
        }
        let dest = if dests.settings.is_empty() {
            &dests.mcp
        } else {
            &dests.settings
        };
        if keyed_settings || keyed_mcp {
            let desired = codex_text(s, src_settings.as_deref(), src_mcp.as_deref(), true)?;
            merge_keyed(s, dest, &desired, "Codex settings and MCP")?;
        } else if !dest.is_empty() && (src_settings.is_some() || src_mcp.is_some()) {
            guard_whole_file(s, tool, "settings", dest)?;
            match &src_mcp {
                Some(mcp) => compose_codex(s, src_settings.as_deref(), mcp, dest)?,
                None => {
                    let settings = src_settings.as_deref().unwrap_or_default();
                    file_ops::copy_file(s, settings, dest).map_err(|e| io(s, e))?;
                }
            }
        }
    } else if format == "opencode_json" {
        if let Some(settings) = &src_settings {
            let label = src_mcp
                .as_deref()
                .map(|mcp| payload::describe_source(&tools_dir, &root, mcp, &tool.slug, "mcp"))
                .unwrap_or_default();
            if keyed_settings {
                let desired = match &src_mcp {
                    Some(mcp) => opencode_text(s, settings, mcp)?,
                    None => read_text(s, Some(settings), "settings")?,
                };
                merge_keyed(s, &dests.settings, &desired, "OpenCode settings and MCP")?;
            } else {
                guard_whole_file(s, tool, "settings", &dests.settings)?;
                match &src_mcp {
                    Some(mcp) => compose_opencode(s, settings, mcp, &dests.settings, label)?,
                    None => {
                        file_ops::copy_file(s, settings, &dests.settings).map_err(|e| io(s, e))?
                    }
                }
            }
        }
    } else {
        if let Some(settings) = &src_settings {
            if keyed_settings {
                let desired = read_text(s, Some(settings), "settings")?;
                let what = s.display(settings);
                merge_keyed(s, &dests.settings, &desired, &what)?;
            } else {
                guard_whole_file(s, tool, "settings", &dests.settings)?;
                file_ops::copy_file(s, settings, &dests.settings).map_err(|e| io(s, e))?;
            }
        }
        if let Some(mcp) = &src_mcp {
            let label = payload::describe_source(&tools_dir, &root, mcp, &tool.slug, "mcp");
            if keyed_mcp {
                let desired = read_text(s, Some(mcp), "MCP source")?;
                let what = s.display(mcp);
                merge_keyed(s, &dests.mcp, &desired, &what)?;
            } else {
                guard_whole_file(s, tool, "mcp", &dests.mcp)?;
                file_ops::copy_file_noted(s, mcp, &dests.mcp, label).map_err(|e| io(s, e))?;
            }
        }
    }

    for (resource, dest) in [("hooks", &dests.hooks), ("guard", &dests.guard)] {
        if dest.is_empty() {
            continue;
        }
        if let Some(src) = payload::resolve_source(s, tool, resource).filter(|p| s.ws.is_file(p)) {
            file_ops::copy_file(s, &src, dest).map_err(|e| io(s, e))?;
            if resource == "guard" && !s.dry_run {
                s.ws.make_executable(dest).map_err(|e| io(s, e))?;
            }
        }
    }
    Ok(())
}

fn read_text(s: &mut Session, path: Option<&str>, what: &str) -> Result<String, Stop> {
    let bytes = match path {
        Some(path) => s.ws.read(path).map_err(|e| io(s, e))?,
        None => Vec::new(),
    };
    String::from_utf8(bytes).map_err(|_| {
        s.log
            .error(&format!("Cannot compose Codex config: {what} is not UTF-8"));
        Stop(1)
    })
}

/// The settings text with the MCP source composed in, as `config.toml` takes
/// it; `keyed` picks the hint for settings that still hold `mcp_servers`.
fn codex_text(
    s: &mut Session,
    settings: Option<&str>,
    mcp: Option<&str>,
    keyed: bool,
) -> Result<String, Stop> {
    let settings_text = read_text(s, settings, "settings")?;
    let Some(mcp) = mcp else {
        return Ok(settings_text);
    };
    let mcp_bytes = s.ws.read(mcp).map_err(|e| io(s, e))?;
    codex_toml::compose(&settings_text, &mcp_bytes).map_err(|reason| {
        s.log
            .error(&format!("Cannot compose Codex config: {reason}"));
        if codex_toml::settings_claim_mcp(&settings_text) {
            s.log.err(
                "  • Move the [mcp_servers] tables into the MCP source as JSON, then re-run sync"
                    .into(),
            );
            s.log.err(if keyed {
                "  • Servers the Codex app manages need no source: delete them from settings and they stay in the live config".into()
            } else {
                "  • Or keep them in settings: set targets.mcp.enabled: false in .ai/src/tools/codex.yaml".into()
            });
        }
        Stop(1)
    })
}

/// A whole-file write over a file the previous sync owned by key would drop
/// what the tool itself wrote there; it takes `--force`.
fn guard_whole_file(s: &mut Session, tool: &Tool, resource: &str, dest: &str) -> Step {
    if dest.is_empty() || s.owned_before(dest).is_none() || s.force || s.dry_run {
        return Ok(());
    }
    let shown = s.display(dest);
    s.log.error(&format!(
        "{shown} is owned by key; owning the whole file drops what {} wrote there",
        tool.display_name()
    ));
    let force = s.log.command("agentsync sync --force");
    s.log.err(format!(
        "  • Set targets.{resource}.ownership: keys in .ai/src/tools/{}.yaml, or run {force} to own the whole file",
        tool.slug
    ));
    Err(Stop(1))
}

/// `desired`, the document the file would otherwise get whole, merged into
/// the live `dest` by key; every key the tool itself wrote stays as it is.
fn merge_keyed(s: &mut Session, dest: &str, desired: &str, what: &str) -> Step {
    let shown = s.display(dest);
    let Some(format) = keyed::Format::of(dest) else {
        s.log.error(&format!(
            "Cannot own {shown} by key: only TOML and JSON files can be"
        ));
        return Err(Stop(1));
    };
    let live = if s.ws.is_file(dest) {
        read_text(s, Some(dest), &shown)?
    } else {
        String::new()
    };
    let previous = s.owned_before(dest).cloned();
    let merged = keyed::merge(format, &live, desired, previous.as_ref()).map_err(|reason| {
        s.log.error(&format!("Cannot merge into {shown}: {reason}"));
        s.log
            .err("  • Fix that file or its source, then re-run sync".into());
        Stop(1)
    })?;
    if previous.is_none() && !merged.drifted.is_empty() && !s.force {
        let count = merged.drifted.len();
        let noun = if count == 1 { "key" } else { "keys" };
        let headline =
            format!("{shown} differs from .ai/src in {count} {noun} sync has not owned before:");
        if s.dry_run {
            s.log
                .warning(&format!("A real sync would stop: {headline}"));
        } else {
            s.log.error(&headline);
        }
        for key in &merged.drifted {
            s.log.err(format!("      {}", keyed::display(key)));
        }
        let force = s.log.command("agentsync sync --force");
        s.log.err(format!(
            "  • Copy the live values into the settings source, or run {force} to apply .ai/src"
        ));
        if !s.dry_run {
            return Err(Stop(1));
        }
    }
    if s.dry_run {
        s.log.step(&format!(
            "Would merge the owned keys of {what} → {shown} (dry-run)"
        ));
        return Ok(());
    }
    let text = if s.ws.is_file(dest) {
        merged.text
    } else {
        desired.to_string()
    };
    if !s.ws.is_file(dest) || text != live {
        s.ws.create_dir_all(&paths::parent(dest))
            .map_err(|e| io(s, e))?;
        s.ws.replace_atomically(dest, text.into_bytes())
            .map_err(|e| io(s, e))?;
    }
    s.record_write(dest);
    s.record_owned(dest, merged.owned);
    s.log.step(&format!("{what} → {shown} (owned keys only)"));
    Ok(())
}

fn compose_codex(s: &mut Session, settings: Option<&str>, mcp: &str, dest: &str) -> Step {
    let composed = codex_text(s, settings, Some(mcp), false)?;
    if s.dry_run {
        s.log.step(&format!(
            "Would compose Codex settings and MCP → {} (dry-run)",
            s.display(dest)
        ));
        return Ok(());
    }
    s.ws.create_dir_all(&paths::parent(dest))
        .map_err(|e| io(s, e))?;
    s.ws.replace_atomically(dest, composed.into_bytes())
        .map_err(|e| io(s, e))?;
    s.record_write(dest);
    s.log
        .step(&format!("Codex settings and MCP → {}", s.display(dest)));
    Ok(())
}

/// The OpenCode settings with the MCP source composed in.
fn opencode_text(s: &mut Session, settings: &str, mcp: &str) -> Result<String, Stop> {
    let settings_text =
        String::from_utf8_lossy(&s.ws.read(settings).map_err(|e| io(s, e))?).into_owned();
    let mcp_text = String::from_utf8_lossy(&s.ws.read(mcp).map_err(|e| io(s, e))?).into_owned();
    opencode_json::compose(&settings_text, &mcp_text).map_err(|failure| {
        let (settings_disp, mcp_disp) = (s.display(settings), s.display(mcp));
        s.log.error(&format!(
            "Cannot compose OpenCode config from {settings_disp} and {mcp_disp}: {}",
            failure.message
        ));
        Stop(failure.code)
    })
}

/// `sync_opencode_config`; `mcp_label` is `describe_source`'s word for where
/// the MCP half came from, shown on the written line.
fn compose_opencode(
    s: &mut Session,
    settings: &str,
    mcp: &str,
    dest: &str,
    mcp_label: &str,
) -> Step {
    let note = if mcp_label.is_empty() {
        String::new()
    } else {
        format!(" (mcp: {mcp_label})")
    };
    match opencode_text(s, settings, mcp) {
        Err(stop) => Err(stop),
        Ok(_) if s.dry_run => {
            s.log.step(&format!(
                "Would compose OpenCode settings and MCP → {}{note} (dry-run)",
                s.display(dest)
            ));
            Ok(())
        }
        Ok(composed) => {
            s.ws.create_dir_all(&paths::parent(dest))
                .map_err(|e| io(s, e))?;
            s.ws.remove(dest).map_err(|e| io(s, e))?;
            s.ws.write(dest, composed.into_bytes())
                .map_err(|e| io(s, e))?;
            s.record_write(dest);
            let line = format!(
                "{} + {} → {}{note}",
                s.display(settings),
                s.display(mcp),
                s.display(dest)
            );
            s.log.step(&line);
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::skill_description;
    use crate::engine::render::test_support::{file, project, text_of};
    use crate::engine::render::{Env, render};

    #[test]
    fn inline_indexes_follow_the_agents_copy_for_codex() {
        let mut s = project();
        file(
            &mut s,
            "/proj/.ai/agent_sync.yaml",
            "tools:\n  enabled: [codex]\n",
        );
        render(&mut s, &Env::default()).unwrap();
        let agents = text_of(&s, "/proj/AGENTS.md");
        assert!(agents.starts_with("# Agents\n\n\n## Rules\n"));
        assert!(agents.contains("- `core.md` — Core\n"));
        assert!(s.ws.is_file("/proj/.agents/skills/command-review/SKILL.md"));
    }

    // Design spec, "Known quirks", item 11: `description: >-` indexes as `-`.
    #[test]
    fn skill_descriptions_come_from_the_frontmatter_scalar_or_its_first_folded_line() {
        assert_eq!(
            skill_description(b"---\nname: a\ndescription: Does A\n---\n"),
            b"Does A"
        );
        assert_eq!(
            skill_description(b"---\ndescription: >\n  Folded first\n  second\nname: x\n---\n"),
            b"Folded first"
        );
        assert_eq!(skill_description(b"---\ndescription: >-\n  x\n---\n"), b"-");
        assert_eq!(skill_description(b"no frontmatter\n"), b"");
    }
}
