//! Markdown frontmatter and the per-file converters of
//! `lib/helpers/format_conversion.sh`: Gemini command TOML, Codex agent TOML,
//! Amazon Q agent JSON, and OpenCode agent Markdown.

use crate::text::{self, after_key, is_space, strip_quotes};

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Frontmatter {
    pub name: Vec<u8>,
    pub description: Vec<u8>,
    pub model: Vec<u8>,
    pub tools: Vec<Vec<u8>>,
    pub tools_declared: bool,
    pub readonly: Vec<u8>,
    pub body: Vec<u8>,
}

/// `_parse_md_frontmatter`.
pub fn parse_frontmatter(source: &[u8]) -> Frontmatter {
    let mut fm = Frontmatter::default();
    let mut in_frontmatter = false;
    let mut done = false;
    let mut in_multiline_desc = false;
    let mut in_tools_list = false;

    for line in text::lines(source) {
        if !done {
            if line == b"---" && !in_frontmatter {
                in_frontmatter = true;
                continue;
            }
            if line == b"---" {
                done = true;
                in_multiline_desc = false;
                in_tools_list = false;
                continue;
            }
            if in_frontmatter {
                parse_frontmatter_line(line, &mut fm, &mut in_multiline_desc, &mut in_tools_list);
                continue;
            }
            done = true;
        }
        fm.body.extend_from_slice(line);
        fm.body.push(b'\n');
    }
    fm
}

fn parse_frontmatter_line(
    line: &[u8],
    fm: &mut Frontmatter,
    in_multiline_desc: &mut bool,
    in_tools_list: &mut bool,
) {
    if *in_multiline_desc {
        if line.first().is_some_and(|b| is_space(*b)) {
            let cont = text::trim_start_space(line);
            if !fm.description.is_empty() {
                fm.description.push(b' ');
            }
            fm.description.extend_from_slice(cont);
            return;
        }
        *in_multiline_desc = false;
    }
    if *in_tools_list {
        if let Some(item) = block_list_item(line) {
            fm.tools.push(strip_quotes(item).to_vec());
            return;
        }
        *in_tools_list = false;
    }

    if let Some(rest) = after_key(line, "name") {
        fm.name = strip_quotes(rest).to_vec();
    } else if let Some(rest) = after_key(line, "model") {
        fm.model = strip_quotes(rest).to_vec();
    } else if let Some(inner) = after_key(line, "tools").and_then(inline_list) {
        fm.tools_declared = true;
        for item in inner.split(|b| *b == b',') {
            let item = item.strip_prefix(b" ").unwrap_or(item);
            let item = item.strip_suffix(b" ").unwrap_or(item);
            let item = strip_quotes(item);
            if !item.is_empty() {
                fm.tools.push(item.to_vec());
            }
        }
    } else if after_key(line, "tools").is_some_and(<[u8]>::is_empty) {
        fm.tools_declared = true;
        *in_tools_list = true;
    } else if let Some(rest) = after_key(line, "readonly") {
        fm.readonly = strip_quotes(rest).to_vec();
    } else if after_key(line, "description").is_some_and(|rest| rest == b">") {
        *in_multiline_desc = true;
        fm.description.clear();
    } else if let Some(rest) = after_key(line, "description") {
        fm.description = strip_quotes(rest).to_vec();
    }
}

/// `^[[:space:]]+-[[:space:]]+(.*)`.
fn block_list_item(line: &[u8]) -> Option<&[u8]> {
    let after_indent = text::trim_start_space(line);
    if after_indent.len() == line.len() {
        return None;
    }
    let after_dash = after_indent.strip_prefix(b"-")?;
    let item = text::trim_start_space(after_dash);
    (item.len() < after_dash.len()).then_some(item)
}

/// `\[(.*)\][[:space:]]*$` on the text after `tools:`.
fn inline_list(rest: &[u8]) -> Option<&[u8]> {
    let trimmed = text::trim_end_space(rest);
    if trimmed.len() >= 2 && trimmed.starts_with(b"[") && trimmed.ends_with(b"]") {
        Some(&trimmed[1..trimmed.len() - 1])
    } else {
        None
    }
}

/// `read_frontmatter_field`: the first value of `field` inside a leading
/// `---` block, read by [`field_scalar`].
pub fn read_field(source: &[u8], field: &str) -> Vec<u8> {
    let mut in_frontmatter = false;
    for line in text::lines(source) {
        if !in_frontmatter {
            if line != b"---" {
                return Vec::new();
            }
            in_frontmatter = true;
            continue;
        }
        if line == b"---" {
            break;
        }
        if let Some(rest) = after_key(line, field) {
            return field_scalar(rest).to_vec();
        }
    }
    Vec::new()
}

/// A frontmatter value: the text between its quotes when quoted, else the
/// text before a `#` comment, trimmed.
fn field_scalar(rest: &[u8]) -> &[u8] {
    let rest = text::trim_start_space(rest);
    if let Some(&quote) = rest.first().filter(|b| **b == b'"' || **b == b'\'')
        && let Some(close) = rest[1..].iter().position(|b| *b == quote)
    {
        return &rest[1..=close];
    }
    let cut = rest
        .iter()
        .position(|b| *b == b'#')
        .map_or(rest, |idx| &rest[..idx]);
    text::trim_end_space(cut)
}

/// Per-line `sed` substitution: every non-overlapping `from` becomes `to`.
pub fn replace_all(line: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(line.len());
    let mut i = 0;
    while i < line.len() {
        if line[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(line[i]);
            i += 1;
        }
    }
    out
}

/// `sed 's/!`\([^`]*\)`/!{\1}/g'` on one line.
fn braces_for_shell_sugar(line: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(line.len());
    let mut i = 0;
    while i < line.len() {
        if line[i..].starts_with(b"!`")
            && let Some(close) = line[i + 2..].iter().position(|b| *b == b'`')
        {
            out.extend_from_slice(b"!{");
            out.extend_from_slice(&line[i + 2..i + 2 + close]);
            out.push(b'}');
            i += close + 3;
            continue;
        }
        out.push(line[i]);
        i += 1;
    }
    out
}

/// `$(echo "$text" | sed …)`: a per-line rewrite with trailing newlines dropped.
fn sed_lines(input: &[u8], rewrite: impl Fn(&[u8]) -> Vec<u8>) -> Vec<u8> {
    let mut with_newline = input.to_vec();
    with_newline.push(b'\n');
    let mut out = Vec::with_capacity(with_newline.len());
    for line in text::lines(&with_newline) {
        out.extend(rewrite(line));
        out.push(b'\n');
    }
    text::strip_trailing_newlines(&mut out);
    out
}

/// `convert_md_command_to_toml`.
pub fn command_to_toml(source: &[u8]) -> Vec<u8> {
    let fm = parse_frontmatter(source);
    let body = sed_lines(&fm.body, braces_for_shell_sugar);
    let body = sed_lines(&body, |line| replace_all(line, b"$ARGUMENTS", b"{{args}}"));
    let mut out = Vec::new();
    if !fm.description.is_empty() {
        out.extend_from_slice(b"description = \"");
        out.extend(text::json_escape(&fm.description));
        out.extend_from_slice(b"\"\n");
    }
    out.extend_from_slice(b"prompt = \"\"\"\n");
    out.extend_from_slice(&body);
    out.extend_from_slice(b"\"\"\"\n");
    out
}

/// `convert_md_agent_to_toml`.
pub fn agent_to_toml(stem: &str, source: &[u8]) -> Vec<u8> {
    let fm = parse_frontmatter(source);
    let name = if fm.name.is_empty() {
        stem.as_bytes()
    } else {
        &fm.name
    };
    let mut out = Vec::new();
    out.extend_from_slice(b"name = \"");
    out.extend(text::json_escape(name));
    out.extend_from_slice(b"\"\n");
    if !fm.description.is_empty() {
        out.extend_from_slice(b"description = \"");
        out.extend(text::json_escape(&fm.description));
        out.extend_from_slice(b"\"\n");
    }
    out.extend_from_slice(b"developer_instructions = \"\"\"\n");
    out.extend_from_slice(&fm.body);
    out.extend_from_slice(b"\"\"\"\n");
    out
}

/// `convert_md_agent_to_amazonq_json`.
pub fn agent_to_amazonq_json(stem: &str, source: &[u8]) -> Vec<u8> {
    let fm = parse_frontmatter(source);
    let name = if fm.name.is_empty() {
        stem.as_bytes()
    } else {
        &fm.name
    };
    let body = fm.body.strip_suffix(b"\n").unwrap_or(&fm.body);
    let mut tools = b"[".to_vec();
    for (i, tool) in fm.tools.iter().filter(|t| !t.is_empty()).enumerate() {
        if i > 0 {
            tools.extend_from_slice(b", ");
        }
        tools.push(b'"');
        tools.extend(text::json_escape(tool));
        tools.push(b'"');
    }
    tools.push(b']');

    let mut out = b"{\n  \"name\": \"".to_vec();
    out.extend(text::json_escape(name));
    out.extend_from_slice(b"\",\n");
    if !fm.description.is_empty() {
        out.extend_from_slice(b"  \"description\": \"");
        out.extend(text::json_escape(&fm.description));
        out.extend_from_slice(b"\",\n");
    }
    if !fm.model.is_empty() {
        out.extend_from_slice(b"  \"model\": \"");
        out.extend(text::json_escape(&fm.model));
        out.extend_from_slice(b"\",\n");
    }
    out.extend_from_slice(b"  \"tools\": ");
    out.extend(tools);
    out.extend_from_slice(b",\n  \"mcpServers\": {},\n  \"prompt\": \"");
    out.extend(text::json_escape(body));
    out.extend_from_slice(b"\"\n}\n");
    out
}

/// `convert_md_agent_to_opencode_md`.
pub fn agent_to_opencode_md(stem: &str, source: &[u8]) -> Vec<u8> {
    let fm = parse_frontmatter(source);
    let description: &[u8] = if !fm.description.is_empty() {
        &fm.description
    } else if !fm.name.is_empty() {
        &fm.name
    } else {
        stem.as_bytes()
    };

    let mut permissions = Vec::new();
    if fm.tools_declared {
        permissions.extend_from_slice(b"  \"*\": deny\n");
        let mut seen: Vec<&str> = Vec::new();
        for tool in &fm.tools {
            let mapped = match tool.as_slice() {
                b"Read" => "read",
                b"Grep" => "grep",
                b"Glob" => "glob",
                b"Bash" => "bash",
                b"Write" | b"Edit" => "edit",
                b"WebFetch" => "webfetch",
                b"WebSearch" => "websearch",
                b"Task" => "task",
                _ => continue,
            };
            if seen.contains(&mapped) {
                continue;
            }
            permissions.extend_from_slice(format!("  \"{mapped}\": allow\n").as_bytes());
            seen.push(mapped);
        }
    } else if fm.readonly == b"true" {
        permissions.extend_from_slice(b"  edit: deny\n  bash: deny\n");
    }

    let mut out = b"---\n".to_vec();
    if !description.is_empty() {
        out.extend_from_slice(b"description: \"");
        out.extend(text::json_escape(description));
        out.extend_from_slice(b"\"\n");
    }
    out.extend_from_slice(b"mode: subagent\n");
    if fm.model.contains(&b'/') {
        out.extend_from_slice(b"model: \"");
        out.extend(text::json_escape(&fm.model));
        out.extend_from_slice(b"\"\n");
    }
    if !permissions.is_empty() {
        out.extend_from_slice(b"permission:\n");
        out.extend(permissions);
    }
    out.extend_from_slice(b"---\n");
    out.extend_from_slice(&fm.body);
    out
}

/// A portable subagent as a Kiro Markdown agent: `name`, `description`, and
/// the declared tools mapped onto Kiro's tool tags. `model` is dropped, since
/// Kiro names its own models: https://kiro.dev/docs/custom-agents/configuration-reference/
pub fn agent_to_kiro_md(stem: &str, source: &[u8]) -> Vec<u8> {
    let fm = parse_frontmatter(source);
    let name: &[u8] = if fm.name.is_empty() {
        stem.as_bytes()
    } else {
        &fm.name
    };
    let mut tags: Vec<&str> = Vec::new();
    if fm.tools_declared {
        for tool in &fm.tools {
            let tag = match tool.as_slice() {
                b"Read" | b"Grep" | b"Glob" => "read",
                b"Write" | b"Edit" => "write",
                b"Bash" => "shell",
                b"WebFetch" | b"WebSearch" => "web",
                b"Task" => "subagent",
                _ => continue,
            };
            if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
    } else if fm.readonly == b"true" {
        tags.push("read");
    }

    let mut out = b"---\nname: \"".to_vec();
    out.extend(text::json_escape(name));
    out.extend_from_slice(b"\"\n");
    if !fm.description.is_empty() {
        out.extend_from_slice(b"description: \"");
        out.extend(text::json_escape(&fm.description));
        out.extend_from_slice(b"\"\n");
    }
    if fm.tools_declared || fm.readonly == b"true" {
        out.extend_from_slice(format!("tools: [{}]\n", tags.join(", ")).as_bytes());
    }
    out.extend_from_slice(b"---\n");
    out.extend_from_slice(&fm.body);
    out
}

/// The generated `SKILL.md` of `sync_commands_as_skills` for `<name>.md`.
pub fn command_to_skill(name: &str, source: &[u8]) -> Vec<u8> {
    let mut description = read_field(source, "description");
    if description.is_empty() {
        description = format!("Run the /{name} command workflow.").into_bytes();
    }

    let mut body = Vec::new();
    let mut in_fm = false;
    let mut fm_seen = false;
    let mut body_started = false;
    for (index, line) in text::lines(source).into_iter().enumerate() {
        if index == 0 && line == b"---" {
            in_fm = true;
            continue;
        }
        if in_fm && line == b"---" {
            in_fm = false;
            fm_seen = true;
            continue;
        }
        if in_fm || (!body_started && line.is_empty() && fm_seen) {
            continue;
        }
        body_started = true;
        let line = replace_all(line, b"$ARGUMENTS", b"<arg>");
        body.extend(replace_all(&line, b"!`", b"`"));
        body.push(b'\n');
    }
    text::strip_trailing_newlines(&mut body);

    let mut out = format!("---\nname: \"command-{name}\"\ndescription: >-\n  ").into_bytes();
    out.extend(description);
    out.extend_from_slice(b"\n---\n\n");
    out.extend(body);
    out.push(b'\n');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const AGENT: &[u8] = b"---\nname: \"code-reviewer\"\ndescription: >\n  Reviews code\n  carefully\ntools:\n  - Read\n  - \"Grep\"\nmodel: sonnet\n---\n\nYou review.\n";

    #[test]
    fn frontmatter_folds_a_multiline_description_and_collects_block_tools() {
        let fm = parse_frontmatter(AGENT);
        assert_eq!(fm.name, b"code-reviewer");
        assert_eq!(fm.description, b"Reviews code carefully");
        assert_eq!(fm.tools, [b"Read".to_vec(), b"Grep".to_vec()]);
        assert!(fm.tools_declared);
        assert_eq!(fm.model, b"sonnet");
        assert_eq!(fm.body, b"\nYou review.\n");
    }

    #[test]
    fn inline_tools_trim_one_space_and_quotes_per_item() {
        let fm = parse_frontmatter(b"---\ntools: [Read, 'Glob',, Bash ]\n---\nx\n");
        assert_eq!(
            fm.tools,
            [b"Read".to_vec(), b"Glob".to_vec(), b"Bash".to_vec()]
        );
    }

    #[test]
    fn a_file_without_frontmatter_is_all_body() {
        let fm = parse_frontmatter(b"# Title\n---\n");
        assert_eq!(fm.body, b"# Title\n---\n");
        assert!(fm.name.is_empty());
    }

    // Design spec, "Known quirks", item 9: reproduced on purpose until cutover.
    #[test]
    fn read_field_takes_the_first_occurrence_and_whole_quoted_values() {
        let src = b"---\ndescription: first\ndescription: second\n---\n";
        assert_eq!(read_field(src, "description"), b"first");
        let quoted = b"---\ndescription: \"use # with care\" # note\n---\n";
        assert_eq!(read_field(quoted, "description"), b"use # with care");
        let single = b"---\nname: 'reviewer'\n---\n";
        assert_eq!(read_field(single, "name"), b"reviewer");
        let plain = b"---\nmodel: sonnet # cheap\n---\n";
        assert_eq!(read_field(plain, "model"), b"sonnet");
        assert_eq!(read_field(b"# no fm\n", "description"), b"");
    }

    #[test]
    fn command_toml_rewrites_shell_sugar_and_drops_trailing_newlines() {
        let src = b"---\ndescription: Say \"hi\"\n---\nRun !`git status` for $ARGUMENTS\n\n";
        assert_eq!(
            String::from_utf8(command_to_toml(src)).unwrap(),
            "description = \"Say \\\"hi\"\nprompt = \"\"\"\nRun !{git status} for {{args}}\"\"\"\n"
        );
    }

    #[test]
    fn agent_toml_keeps_the_body_newline() {
        assert_eq!(
            agent_to_toml("x", b"body\n"),
            b"name = \"x\"\ndeveloper_instructions = \"\"\"\nbody\n\"\"\"\n"
        );
    }

    #[test]
    fn amazonq_json_escapes_the_prompt() {
        let out = String::from_utf8(agent_to_amazonq_json("code-reviewer", AGENT)).unwrap();
        assert_eq!(
            out,
            "{\n  \"name\": \"code-reviewer\",\n  \"description\": \"Reviews code carefully\",\n  \"model\": \"sonnet\",\n  \"tools\": [\"Read\", \"Grep\"],\n  \"mcpServers\": {},\n  \"prompt\": \"\\nYou review.\"\n}\n"
        );
    }

    #[test]
    fn opencode_md_maps_tools_to_an_allowlist_and_omits_portable_models() {
        let out = String::from_utf8(agent_to_opencode_md("code-reviewer", AGENT)).unwrap();
        assert_eq!(
            out,
            "---\ndescription: \"Reviews code carefully\"\nmode: subagent\npermission:\n  \"*\": deny\n  \"read\": allow\n  \"grep\": allow\n---\n\nYou review.\n"
        );
        let readonly = String::from_utf8(agent_to_opencode_md(
            "r",
            b"---\nreadonly: true\nmodel: a/b\n---\n",
        ))
        .unwrap();
        assert_eq!(
            readonly,
            "---\ndescription: \"r\"\nmode: subagent\nmodel: \"a/b\"\npermission:\n  edit: deny\n  bash: deny\n---\n"
        );
    }

    #[test]
    fn kiro_md_maps_tools_to_kiro_tags_and_drops_the_model() {
        let out = String::from_utf8(agent_to_kiro_md("code-reviewer", AGENT)).unwrap();
        assert_eq!(
            out,
            "---\nname: \"code-reviewer\"\ndescription: \"Reviews code carefully\"\ntools: [read]\n---\n\nYou review.\n"
        );
        let wide = String::from_utf8(agent_to_kiro_md(
            "w",
            b"---\ntools: [Bash, Edit, Write, WebFetch, Task, mcp__x]\n---\nGo.\n",
        ))
        .unwrap();
        assert_eq!(
            wide,
            "---\nname: \"w\"\ntools: [shell, write, web, subagent]\n---\nGo.\n"
        );
        let readonly =
            String::from_utf8(agent_to_kiro_md("r", b"---\nreadonly: true\n---\n")).unwrap();
        assert_eq!(readonly, "---\nname: \"r\"\ntools: [read]\n---\n");
        let open = String::from_utf8(agent_to_kiro_md("o", b"Body.\n")).unwrap();
        assert_eq!(open, "---\nname: \"o\"\n---\nBody.\n");
    }

    #[test]
    fn command_skill_skips_blank_lines_after_frontmatter() {
        let src = b"---\ndescription: Review it\n---\n\n\nCheck $ARGUMENTS with !`ls`\n";
        assert_eq!(
            String::from_utf8(command_to_skill("review", src)).unwrap(),
            "---\nname: \"command-review\"\ndescription: >-\n  Review it\n---\n\nCheck <arg> with `ls`\n"
        );
        assert!(
            String::from_utf8(command_to_skill("x", b"body"))
                .unwrap()
                .contains("  Run the /x command workflow.\n")
        );
    }

    #[test]
    fn an_empty_tools_allowlist_stays_deny_by_default() {
        let out = agent_to_opencode_md(
            "no-tools",
            b"---\ndescription: No-tools agent\ntools: []\n---\nAnswer from context only.\n",
        );
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "---\ndescription: \"No-tools agent\"\nmode: subagent\npermission:\n  \"*\": deny\n---\nAnswer from context only.\n"
        );
    }
}
