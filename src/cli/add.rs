//! `agentsync add`: `cmd_add` and `cmd_add_mcp` of `lib/helpers/add.sh`,
//! which scaffold a rule, skill, command, or subagent from the shipped content
//! templates and splice one server into the shared `.ai/src/mcp.json`.

use std::io::Write;
use std::path::{Path, PathBuf};

use super::put;
use crate::output::help::{Help, Section};
use crate::output::style::Style;
use crate::{Error, config::catalog, engine::staging};

pub const HELP: Help = Help {
    command: "add",
    tagline: "scaffold a rule, skill, command, subagent, or MCP server",
    synopsis: &[
        "add <kind> <name> [--force]",
        "add mcp <server> (--url URL | --command CMD) [MCP OPTIONS] [--force]",
    ],
    description: &[
        "Scaffold a new entry under .ai/src/ from the shipped content templates,\nor add one server entry to the shared .ai/src/mcp.json.",
        "Edit the scaffold, then run agentsync sync to propagate.",
    ],
    sections: &[
        Section {
            title: "KINDS",
            entries: &[
                ("rule", "Create .ai/src/rules/<name>.md"),
                ("skill", "Create .ai/src/skills/<name>/SKILL.md"),
                ("command", "Create .ai/src/commands/<name>.md"),
                ("subagent", "Create .ai/src/agents/<name>.md"),
                ("mcp", "Add an MCP server entry to .ai/src/mcp.json"),
            ],
        },
        Section {
            title: "MCP OPTIONS",
            entries: &[
                ("--url URL", "HTTP server endpoint"),
                ("--command CMD", "Command that starts the server"),
                ("--args \"a b c\"", "Command arguments, split on whitespace"),
                ("--env K=V[,K=V...]", "Environment variables for the server"),
            ],
        },
        Section {
            title: "OPTIONS",
            entries: &[
                ("-f, --force", "Overwrite an existing file or server entry"),
                ("-h, --help", "Show this help"),
            ],
        },
    ],
    examples: &[
        "add rule testing",
        "add skill deploy",
        "add mcp linear --url https://mcp.linear.app/sse",
        "add mcp github --command npx --args \"-y @github/mcp-server\"",
    ],
};

const EMPTY_MCP: &str = "{\n  \"mcpServers\": {}\n}\n";

/// `_add_print_usage`: the refusal line, then the help.
fn usage(message: &str, style: &Style, err: &mut dyn Write) -> Result<(), Error> {
    put(
        err,
        format!("{}: {message}\n{}", style.red("Error"), HELP.render(style)).as_bytes(),
    )
}

/// `_add_validate_name`: the refusal, or nothing.
fn validate_name(name: &str, style: &Style) -> Option<String> {
    let error = style.red("Error");
    if name.is_empty() {
        return Some(format!("{error}: Name is empty.\n"));
    }
    if name.contains('/') || name.contains('\\') {
        return Some(format!(
            "{error}: Name cannot contain path separators: {name}\n"
        ));
    }
    if name.contains("..") {
        return Some(format!("{error}: Name cannot contain '..': {name}\n"));
    }
    if name.starts_with('.') || name.starts_with('-') {
        return Some(format!(
            "{error}: Name cannot start with '.' or '-': {name}\n"
        ));
    }
    if !name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Some(format!(
            "{error}: Name may only contain letters, digits, hyphens, and underscores: {name}\n"
        ));
    }
    None
}

/// `_add_resolve_dest`, below `.ai/src/`.
fn dest_rel(kind: &str, name: &str) -> String {
    match kind {
        "rule" => format!(".ai/src/rules/{name}.md"),
        "skill" => format!(".ai/src/skills/{name}/SKILL.md"),
        "command" => format!(".ai/src/commands/{name}.md"),
        _ => format!(".ai/src/agents/{name}.md"),
    }
}

/// `{{TITLE}}`: hyphens become spaces and each part starts upper-case, as the
/// awk program splits it, so `my_tool-x2--y` reads `My_tool X2  Y`.
fn title(name: &str) -> String {
    name.split('-')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// The `sed` pass: placeholders everywhere, the sentinel `name:` lines whole.
fn render(template: &str, name: &str) -> String {
    let text = template
        .replace("{{TITLE}}", &title(name))
        .replace("{{NAME}}", name);
    text.split('\n')
        .map(|line| {
            if line == "name: \"content\"" || line == "name: \"template-agent\"" {
                format!("name: \"{name}\"")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `cmd_add`: the report on `out`, refusals on `err`, the status as the result.
pub fn add(
    args: &[String],
    root: &str,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    if args.first().map(String::as_str) == Some("mcp") {
        return add_mcp(&args[1..], root, style, out, err);
    }
    let mut force = false;
    let mut kind = String::new();
    let mut name = String::new();
    for arg in args {
        match arg.as_str() {
            "--force" | "-f" => force = true,
            "--help" | "-h" => {
                put(out, HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            flag if flag.starts_with('-') => {
                put(
                    err,
                    format!("{}: Unknown flag: {flag}\n", style.red("Error")).as_bytes(),
                )?;
                return Ok(1);
            }
            positional => {
                if kind.is_empty() {
                    kind = positional.to_string();
                } else if name.is_empty() {
                    name = positional.to_string();
                } else {
                    usage(&format!("Unexpected argument: {positional}"), style, err)?;
                    return Ok(1);
                }
            }
        }
    }
    if kind.is_empty() {
        usage("missing <kind> and <name>", style, err)?;
        return Ok(1);
    }
    if name.is_empty() {
        usage(&format!("missing <name> for {kind}"), style, err)?;
        return Ok(1);
    }
    if !matches!(kind.as_str(), "rule" | "skill" | "command" | "subagent") {
        put(
            err,
            format!(
                "{}: Unknown kind '{kind}'.\nValid kinds: rule, skill, command, subagent\n",
                style.red("Error")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    if let Some(refusal) = validate_name(&name, style) {
        put(err, refusal.as_bytes())?;
        return Ok(1);
    }
    if kind == "skill" && !crate::config::skill_metadata::valid_name(&name) {
        put(
            err,
            format!(
                "{}: Skill name must be 1–64 lowercase letters, digits, or single hyphens and cannot end with a hyphen: {name}\n",
                style.red("Error")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let Some(template) = catalog::content_template(&kind) else {
        put(
            err,
            format!(
                "{}: Template missing: {}/lib/templates/content/{kind}.md\n",
                style.red("Error"),
                crate::paths::ENGINE_ROOT
            )
            .as_bytes(),
        )?;
        return Ok(1);
    };
    let rel = dest_rel(&kind, &name);
    let dest = PathBuf::from(format!("{root}/{rel}"));
    if dest.exists() && !force {
        put(
            err,
            format!(
                "{}: Already exists: {}\n\nPass {} to overwrite, or pick a different name.\n",
                style.red("Error"),
                dest.display(),
                style.cyan("--force")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
    }
    std::fs::write(&dest, render(template, &name)).map_err(|e| Error::io(&dest, e))?;
    put(
        out,
        format!(
            "\n{} {rel}\n\nEdit the file, then run {} to propagate.\n\n",
            style.green(&format!("Created {kind}:")),
            style.cyan("agentsync sync")
        )
        .as_bytes(),
    )
    .map(|()| 0)
}

/// `_add_json_escape`.
fn json_escape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for c in raw.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            other => out.push(other),
        }
    }
    out
}

fn is_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0b' | '\x0c')
}

/// `read -r` on a here-string: the first line only.
fn first_line(text: &str) -> &str {
    text.split('\n').next().unwrap_or("")
}

/// `_add_mcp_build_entry`: the compact-to-be JSON object, or the `--env`
/// refusal.
fn build_entry(
    url: &str,
    command: &str,
    args: &str,
    env: &str,
    style: &Style,
) -> Result<String, String> {
    let mut fields = if !url.is_empty() {
        format!("\"type\": \"http\", \"url\": \"{}\"", json_escape(url))
    } else {
        let mut fields = format!("\"command\": \"{}\"", json_escape(command));
        if !args.is_empty() {
            let list = first_line(args)
                .split([' ', '\t'])
                .filter(|token| !token.is_empty())
                .map(|token| format!("\"{}\"", json_escape(token)))
                .collect::<Vec<_>>()
                .join(", ");
            fields.push_str(&format!(", \"args\": [{list}]"));
        }
        fields
    };
    if !env.is_empty() {
        let mut members = Vec::new();
        for pair in first_line(env).split(',') {
            let pair = pair.trim_matches(is_blank);
            if pair.is_empty() {
                continue;
            }
            let Some((key, value)) = pair.split_once('=') else {
                return Err(format!(
                    "{}: --env entry '{pair}' must be KEY=VALUE.\n",
                    style.red("Error")
                ));
            };
            members.push(format!(
                "\"{}\": \"{}\"",
                json_escape(key.trim_matches(is_blank)),
                json_escape(value)
            ));
        }
        if !members.is_empty() {
            fields.push_str(&format!(", \"env\": {{{}}}", members.join(", ")));
        }
    }
    Ok(format!("{{{fields}}}"))
}

/// Why `_add_mcp_merge` refused: the server exists (awk exit 3), or the
/// `mcpServers` member is not an object (awk exit 2).
enum Refusal {
    Exists,
    Malformed,
}

fn is_ws(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

/// awk `skip_string`: `at` is the opening quote; the index past the closing
/// quote, or the end.
fn skip_string(s: &[u8], at: usize) -> usize {
    let mut i = at + 1;
    let mut escaped = false;
    while i < s.len() {
        let c = s[i];
        if escaped {
            escaped = false;
        } else if c == b'\\' {
            escaped = true;
        } else if c == b'"' {
            return i + 1;
        }
        i += 1;
    }
    i
}

/// awk `skip_value`: the index past a string, a balanced object or array,
/// or a scalar, blanks before it skipped.
fn skip_value(s: &[u8], at: usize) -> usize {
    let mut i = at;
    while i < s.len() && is_ws(s[i]) {
        i += 1;
    }
    match s.get(i) {
        Some(b'"') => skip_string(s, i),
        Some(b'{' | b'[') => {
            let mut depth = 0usize;
            let mut in_string = false;
            let mut escaped = false;
            while i < s.len() {
                let c = s[i];
                if in_string {
                    if escaped {
                        escaped = false;
                    } else if c == b'\\' {
                        escaped = true;
                    } else if c == b'"' {
                        in_string = false;
                    }
                } else if c == b'"' {
                    in_string = true;
                } else if c == b'{' || c == b'[' {
                    depth += 1;
                } else if c == b'}' || c == b']' {
                    depth -= 1;
                    if depth == 0 {
                        return i + 1;
                    }
                }
                i += 1;
            }
            i
        }
        _ => {
            while i < s.len() {
                let c = s[i];
                if c == b',' || c == b'}' || c == b']' || is_ws(c) {
                    break;
                }
                i += 1;
            }
            i
        }
    }
}

/// awk `compact`: blanks outside strings dropped.
fn compact(value: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(value.len());
    let mut in_string = false;
    let mut escaped = false;
    for &c in value {
        if in_string {
            out.push(c);
            if escaped {
                escaped = false;
            } else if c == b'\\' {
                escaped = true;
            } else if c == b'"' {
                in_string = false;
            }
        } else if c == b'"' {
            in_string = true;
            out.push(c);
        } else if !is_ws(c) {
            out.push(c);
        }
    }
    out
}

fn slice(s: &[u8], from: usize, to: usize) -> &[u8] {
    if from < to && to <= s.len() {
        &s[from..to]
    } else {
        &[]
    }
}

/// `_add_mcp_merge`: the file re-emitted canonically with `entry` spliced in
/// under `server`. The awk program reads the file record by record, so the
/// text it parses ends in one newline; the first `"mcpServers"` anywhere is
/// the member, whatever surrounds it, and without one the file is replaced.
fn merge(content: &[u8], server: &str, entry: &str, force: bool) -> Result<Vec<u8>, Refusal> {
    let mut s = content.to_vec();
    if !s.is_empty() && s.last() != Some(&b'\n') {
        s.push(b'\n');
    }
    let key = b"\"mcpServers\"";
    let Some(k) = s.windows(key.len()).position(|w| w == key) else {
        let mut out = b"{\n  \"mcpServers\": {\n    \"".to_vec();
        out.extend_from_slice(server.as_bytes());
        out.extend_from_slice(b"\": ");
        out.extend_from_slice(&compact(entry.as_bytes()));
        out.extend_from_slice(b"\n  }\n}\n");
        return Ok(out);
    };
    let mut j = k + key.len();
    while j < s.len() && is_ws(s[j]) {
        j += 1;
    }
    if s.get(j) == Some(&b':') {
        j += 1;
    }
    while j < s.len() && is_ws(s[j]) {
        j += 1;
    }
    if s.get(j) != Some(&b'{') {
        return Err(Refusal::Malformed);
    }
    let obj_start = j;
    let obj_end = skip_value(&s, j);
    let mut names: Vec<&[u8]> = Vec::new();
    let mut values: Vec<&[u8]> = Vec::new();
    let mut p = obj_start + 1;
    while p + 1 < obj_end {
        let c = s[p];
        if is_ws(c) || c == b',' {
            p += 1;
            continue;
        }
        if c != b'"' {
            break;
        }
        let key_end = skip_string(&s, p);
        let mut q = key_end;
        while q < s.len() && is_ws(s[q]) {
            q += 1;
        }
        if s.get(q) == Some(&b':') {
            q += 1;
        }
        while q < s.len() && is_ws(s[q]) {
            q += 1;
        }
        let value_end = skip_value(&s, q);
        names.push(slice(&s, p + 1, key_end.saturating_sub(1)));
        values.push(slice(&s, q, value_end));
        p = value_end;
    }
    let mut entries: Vec<(&[u8], Vec<u8>)> = names
        .iter()
        .zip(&values)
        .map(|(name, value)| (*name, value.to_vec()))
        .collect();
    match entries
        .iter()
        .position(|(name, _)| *name == server.as_bytes())
    {
        Some(_) if !force => return Err(Refusal::Exists),
        Some(found) => entries[found].1 = entry.as_bytes().to_vec(),
        None => entries.push((server.as_bytes(), entry.as_bytes().to_vec())),
    }
    let mut out = b"{\n  \"mcpServers\": {".to_vec();
    let last = entries.len() - 1;
    for (index, (name, value)) in entries.iter().enumerate() {
        out.extend_from_slice(b"\n    \"");
        out.extend_from_slice(name);
        out.extend_from_slice(b"\": ");
        out.extend_from_slice(&compact(value));
        if index < last {
            out.push(b',');
        }
    }
    out.extend_from_slice(b"\n  }\n}\n");
    Ok(out)
}

/// `cmd_add_mcp`.
fn add_mcp(
    args: &[String],
    root: &str,
    style: &Style,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8, Error> {
    let mut server = String::new();
    let mut url = String::new();
    let mut command = String::new();
    let mut args_str = String::new();
    let mut env_str = String::new();
    let mut force = false;
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "--url" | "--command" | "--args" | "--env" => {
                let Some(value) = args.get(i + 1) else {
                    usage(&format!("{arg} requires a value."), style, err)?;
                    return Ok(1);
                };
                match arg {
                    "--url" => url = value.clone(),
                    "--command" => command = value.clone(),
                    "--args" => args_str = value.clone(),
                    _ => env_str = value.clone(),
                }
                i += 2;
            }
            "--force" | "-f" => {
                force = true;
                i += 1;
            }
            "-h" | "--help" => {
                put(out, HELP.render(style).as_bytes())?;
                return Ok(0);
            }
            flag if flag.starts_with('-') => {
                usage(&format!("Unknown flag: {flag}"), style, err)?;
                return Ok(1);
            }
            positional => {
                if server.is_empty() {
                    server = positional.to_string();
                    i += 1;
                } else {
                    usage(&format!("Unexpected argument: {positional}"), style, err)?;
                    return Ok(1);
                }
            }
        }
    }
    if server.is_empty() {
        usage("missing <server> for mcp", style, err)?;
        return Ok(1);
    }
    if let Some(refusal) = validate_name(&server, style) {
        put(err, refusal.as_bytes())?;
        return Ok(1);
    }
    if url.is_empty() && command.is_empty() {
        usage("one of --url or --command is required.", style, err)?;
        return Ok(1);
    }
    if !url.is_empty() && !command.is_empty() {
        put(
            err,
            format!(
                "{}: --url and --command are mutually exclusive.\n",
                style.red("Error")
            )
            .as_bytes(),
        )?;
        return Ok(1);
    }
    let mcp_file = PathBuf::from(format!("{root}/.ai/src/mcp.json"));
    let mut created = false;
    if !mcp_file.is_file() {
        let parent = Path::new(root).join(".ai/src");
        std::fs::create_dir_all(&parent).map_err(|e| Error::io(&parent, e))?;
        std::fs::write(&mcp_file, EMPTY_MCP).map_err(|e| Error::io(&mcp_file, e))?;
        created = true;
    }
    let entry = match build_entry(&url, &command, &args_str, &env_str, style) {
        Ok(entry) => entry,
        Err(refusal) => {
            put(err, refusal.as_bytes())?;
            return Ok(1);
        }
    };
    let content = std::fs::read(&mcp_file).map_err(|e| Error::io(&mcp_file, e))?;
    match merge(&content, &server, &entry, force) {
        Ok(bytes) => staging::write_beside(&mcp_file, &bytes)?,
        Err(Refusal::Exists) => {
            put(
                err,
                format!(
                    "{}: server '{server}' already exists. Pass --force to overwrite.\n",
                    style.red("Error")
                )
                .as_bytes(),
            )?;
            return Ok(1);
        }
        Err(Refusal::Malformed) => {
            put(
                err,
                format!(
                    "{}: failed to update {}\n",
                    style.red("Error"),
                    mcp_file.display()
                )
                .as_bytes(),
            )?;
            return Ok(1);
        }
    }
    let headline = if created {
        style.green("Created shared MCP source:")
    } else {
        style.green("Updated shared MCP source:")
    };
    put(
        out,
        format!(
            "\n{headline} .ai/src/mcp.json\n{} {server}\n\nThis MCP source applies to every enabled tool on next {}.\nAdd a per-tool override with {} if needed.\n\n",
            style.green("Added server:"),
            style.cyan("agentsync sync"),
            style.cyan("agentsync customize <tool> mcp")
        )
        .as_bytes(),
    )
    .map(|()| 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use crate::paths::DiskText;

    #[test]
    fn titles_split_on_hyphens_like_the_awk_program() {
        assert_eq!(title("testing"), "Testing");
        assert_eq!(title("my-skill"), "My Skill");
        assert_eq!(title("my_tool-x2--y"), "My_tool X2  Y");
    }

    #[test]
    fn templates_are_filled_like_sed() {
        let skill = render(catalog::content_template("skill").unwrap(), "my-skill");
        assert!(skill.contains("\nname: \"my-skill\"\n"));
        assert!(skill.contains("\n# My Skill\n"));
        let agent = render(catalog::content_template("subagent").unwrap(), "reviewer");
        assert!(agent.starts_with("---\nname: \"reviewer\"\ndescription: >-\n"));
        let rule = render(catalog::content_template("rule").unwrap(), "testing");
        assert!(rule.starts_with("# Testing\n\n- One imperative"));
        assert!(rule.ends_with("native glob trigger.\n"));
    }

    #[test]
    fn names_are_refused_like_add_validate_name() {
        let style = Style::plain();
        let refusal = |name: &str| validate_name(name, &style).unwrap_or_default();
        assert_eq!(refusal(""), "Error: Name is empty.\n");
        assert_eq!(
            refusal("sub/dir"),
            "Error: Name cannot contain path separators: sub/dir\n"
        );
        assert_eq!(
            refusal("a\\b"),
            "Error: Name cannot contain path separators: a\\b\n"
        );
        assert_eq!(
            refusal("..evil"),
            "Error: Name cannot contain '..': ..evil\n"
        );
        assert_eq!(
            refusal(".hidden"),
            "Error: Name cannot start with '.' or '-': .hidden\n"
        );
        assert_eq!(
            refusal("my rule"),
            "Error: Name may only contain letters, digits, hyphens, and underscores: my rule\n"
        );
        assert_eq!(
            refusal("règle"),
            "Error: Name may only contain letters, digits, hyphens, and underscores: règle\n"
        );
        assert_eq!(refusal("my_rule-42"), "");
    }

    #[test]
    fn entries_are_built_like_add_mcp_build_entry() {
        let style = Style::plain();
        let entry = |url: &str, command: &str, args: &str, env: &str| {
            build_entry(url, command, args, env, &style)
        };
        assert_eq!(
            entry("https://mcp.linear.app/sse", "", "", "").unwrap(),
            "{\"type\": \"http\", \"url\": \"https://mcp.linear.app/sse\"}"
        );
        assert_eq!(
            entry(
                "",
                "fs-server",
                "--root /tmp   --debug",
                " TOKEN = abc ,DEBUG=1,, "
            )
            .unwrap(),
            "{\"command\": \"fs-server\", \"args\": [\"--root\", \"/tmp\", \"--debug\"], \"env\": {\"TOKEN\": \" abc\", \"DEBUG\": \"1\"}}"
        );
        assert_eq!(
            entry("", "say \"hi\" path\\to", "x\"y z\\w", "MSG=a\"b").unwrap(),
            "{\"command\": \"say \\\"hi\\\" path\\\\to\", \"args\": [\"x\\\"y\", \"z\\\\w\"], \"env\": {\"MSG\": \"a\\\"b\"}}"
        );
        assert_eq!(entry("", "c", "", ",").unwrap(), "{\"command\": \"c\"}");
        assert_eq!(
            entry("", "a\tb\nc\rd", "", "K=v\tw").unwrap(),
            "{\"command\": \"a\\tb\\nc\\rd\", \"env\": {\"K\": \"v\\tw\"}}"
        );
        assert_eq!(
            entry("https://x", "", "", "A= b =c").unwrap(),
            "{\"type\": \"http\", \"url\": \"https://x\", \"env\": {\"A\": \" b =c\"}}"
        );
        assert_eq!(
            entry("", "c", "", "NOEQ").unwrap_err(),
            "Error: --env entry 'NOEQ' must be KEY=VALUE.\n"
        );
    }

    fn merged(content: &str, server: &str, entry: &str, force: bool) -> String {
        String::from_utf8(
            merge(content.as_bytes(), server, entry, force)
                .ok()
                .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn servers_are_spliced_like_the_awk_merge() {
        let github = "{\"command\": \"npx @github/mcp-server\"}";
        let one = merged(EMPTY_MCP, "github", github, false);
        assert_eq!(
            one,
            "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"npx @github/mcp-server\"}\n  }\n}\n"
        );
        let two = merged(
            &one,
            "linear",
            "{\"type\": \"http\", \"url\": \"https://l\"}",
            false,
        );
        assert_eq!(
            two,
            "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"npx @github/mcp-server\"},\n    \"linear\": {\"type\":\"http\",\"url\":\"https://l\"}\n  }\n}\n"
        );
        assert!(matches!(
            merge(two.as_bytes(), "github", "{\"command\": \"other\"}", false),
            Err(Refusal::Exists)
        ));
        assert_eq!(
            merged(&two, "github", "{\"command\": \"other\"}", true),
            "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"other\"},\n    \"linear\": {\"type\":\"http\",\"url\":\"https://l\"}\n  }\n}\n"
        );
        assert_eq!(
            merged(
                "{\"mcpServers\":{\"a\":{\"k\":\"v\"}}}",
                "b",
                "{\"type\": \"http\", \"url\": \"https://b\"}",
                false
            ),
            "{\n  \"mcpServers\": {\n    \"a\": {\"k\":\"v\"},\n    \"b\": {\"type\":\"http\",\"url\":\"https://b\"}\n  }\n}\n"
        );
        assert_eq!(
            merged(
                "{\"mcpServers\": {\"esc\\\"aped\": {}}}\n",
                "n",
                "{\"type\": \"http\", \"url\": \"https://n\"}",
                false
            ),
            "{\n  \"mcpServers\": {\n    \"esc\\\"aped\": {},\n    \"n\": {\"type\":\"http\",\"url\":\"https://n\"}\n  }\n}\n"
        );
        assert_eq!(
            merged(
                "{\"mcpServers\": {\"a\": { \"env\": { \"X\": \"}\\\"{\" }, \"args\": [ \"1\", [ \"2\" ] ] }, \"b\": \"str\", \"c\": 12}, \"trailing\": true}\n",
                "d",
                "{\"type\": \"http\", \"url\": \"https://d\"}",
                false
            ),
            "{\n  \"mcpServers\": {\n    \"a\": {\"env\":{\"X\":\"}\\\"{\"},\"args\":[\"1\",[\"2\"]]},\n    \"b\": \"str\",\n    \"c\": 12,\n    \"d\": {\"type\":\"http\",\"url\":\"https://d\"}\n  }\n}\n"
        );
    }

    #[test]
    fn odd_files_are_replaced_dropped_or_refused_like_the_awk_merge() {
        let n = "{\"type\": \"http\", \"url\": \"https://n\"}";
        let fresh = "{\n  \"mcpServers\": {\n    \"n\": {\"type\":\"http\",\"url\":\"https://n\"}\n  }\n}\n";
        assert_eq!(merged("{\"servers\": {}}\n", "n", n, false), fresh);
        assert_eq!(merged("garbage\n", "n", n, false), fresh);
        assert_eq!(merged("", "n", n, false), fresh);
        assert_eq!(
            merged(
                "{\"mcpServers\": {\"a\": {}, 1: {}, \"z\": {}}}\n",
                "n",
                n,
                false
            ),
            "{\n  \"mcpServers\": {\n    \"a\": {},\n    \"n\": {\"type\":\"http\",\"url\":\"https://n\"}\n  }\n}\n"
        );
        assert!(matches!(
            merge(b"{\"mcpServers\": []}\n", "n", n, false),
            Err(Refusal::Malformed)
        ));
        assert!(matches!(
            merge(
                b"{\n  \"other\": {\"mcpServers\": 1},\n  \"mcpServers\": {}\n}\n",
                "n",
                n,
                false
            ),
            Err(Refusal::Malformed)
        ));
    }

    #[cfg(unix)]
    fn run(root: &str, args: &[&str]) -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let status = add(&args, root, &Style::plain(), &mut out, &mut err).unwrap();
        (
            status,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    #[cfg(unix)]
    #[test]
    fn a_rule_is_scaffolded_once_like_cmd_add() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().disk_text();
        let (status, out, err) = run(&root, &["rule", "testing"]);
        assert_eq!((status, err.as_str()), (0, ""));
        assert_eq!(
            out,
            "\nCreated rule: .ai/src/rules/testing.md\n\nEdit the file, then run agentsync sync to propagate.\n\n"
        );
        let written = std::fs::read_to_string(dir.path().join(".ai/src/rules/testing.md")).unwrap();
        assert_eq!(
            written,
            catalog::content_template("rule")
                .unwrap()
                .replace("{{TITLE}}", "Testing")
        );
        let (status, out, err) = run(&root, &["rule", "testing"]);
        assert_eq!((status, out.as_str()), (1, ""));
        assert_eq!(
            err,
            format!(
                "Error: Already exists: {root}/.ai/src/rules/testing.md\n\nPass --force to overwrite, or pick a different name.\n"
            )
        );
        let (status, _, err) = run(&root, &["rule", "testing", "--force", "extra"]);
        assert_eq!(status, 1);
        assert!(err.starts_with(
            "Error: Unexpected argument: extra\n\n  agentsync add — scaffold a rule, skill, command, subagent, or MCP server\n\n  USAGE\n"
        ));
        let (status, _, err) = run(&root, &["rule"]);
        assert_eq!(status, 1);
        assert!(err.starts_with("Error: missing <name> for rule\n\n  agentsync add — "));
        let (status, out, _) = run(&root, &["-h"]);
        assert_eq!((status, out), (0, HELP.render(&Style::plain())));
    }

    #[test]
    fn help_renders_both_forms_with_their_kinds_and_mcp_options() {
        assert_eq!(
            HELP.render(&Style::plain()),
            "\n  agentsync add — scaffold a rule, skill, command, subagent, or MCP server\n\n  USAGE\n    agentsync add <kind> <name> [--force]\n    agentsync add mcp <server> (--url URL | --command CMD) [MCP OPTIONS] [--force]\n\n  DESCRIPTION\n    Scaffold a new entry under .ai/src/ from the shipped content templates,\n    or add one server entry to the shared .ai/src/mcp.json.\n\n    Edit the scaffold, then run agentsync sync to propagate.\n\n  KINDS\n    rule       Create .ai/src/rules/<name>.md\n    skill      Create .ai/src/skills/<name>/SKILL.md\n    command    Create .ai/src/commands/<name>.md\n    subagent   Create .ai/src/agents/<name>.md\n    mcp        Add an MCP server entry to .ai/src/mcp.json\n\n  MCP OPTIONS\n    --url URL            HTTP server endpoint\n    --command CMD        Command that starts the server\n    --args \"a b c\"       Command arguments, split on whitespace\n    --env K=V[,K=V...]   Environment variables for the server\n\n  OPTIONS\n    -f, --force   Overwrite an existing file or server entry\n    -h, --help    Show this help\n\n  EXAMPLES\n    agentsync add rule testing\n    agentsync add skill deploy\n    agentsync add mcp linear --url https://mcp.linear.app/sse\n    agentsync add mcp github --command npx --args \"-y @github/mcp-server\"\n\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_server_is_added_once_like_cmd_add_mcp() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().disk_text();
        let (status, out, err) = run(
            &root,
            &["mcp", "github", "--command", "npx @github/mcp-server"],
        );
        assert_eq!((status, err.as_str()), (0, ""));
        assert_eq!(
            out,
            "\nCreated shared MCP source: .ai/src/mcp.json\nAdded server: github\n\nThis MCP source applies to every enabled tool on next agentsync sync.\nAdd a per-tool override with agentsync customize <tool> mcp if needed.\n\n"
        );
        let file = dir.path().join(".ai/src/mcp.json");
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"npx @github/mcp-server\"}\n  }\n}\n"
        );
        let (status, out, err) = run(&root, &["mcp", "github", "--command", "other"]);
        assert_eq!((status, out.as_str()), (1, ""));
        assert_eq!(
            err,
            "Error: server 'github' already exists. Pass --force to overwrite.\n"
        );
        let (status, out, err) = run(&root, &["mcp", "gh", "--url"]);
        assert_eq!((status, out.as_str()), (1, ""));
        assert_eq!(
            err,
            format!(
                "Error: --url requires a value.\n{}",
                HELP.render(&Style::plain())
            )
        );
        let (status, _, err) = run(&root, &["mcp"]);
        assert_eq!(status, 1);
        assert!(err.starts_with("Error: missing <server> for mcp\n\n  agentsync add — "));
        let (status, out, err) = run(&root, &["mcp", "bad", "--command", "c", "--env", "NOEQ"]);
        assert_eq!((status, out.as_str()), (1, ""));
        assert_eq!(err, "Error: --env entry 'NOEQ' must be KEY=VALUE.\n");
        let (status, out, err) = run(&root, &["mcp", "-h"]);
        assert_eq!((status, err.as_str()), (0, ""));
        assert_eq!(out, HELP.render(&Style::plain()));
    }
}
