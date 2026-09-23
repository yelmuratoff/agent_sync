//! Optional source declarations from a pinned local Git blob, never a checkout.

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};

const MAX_BYTES: usize = 128 * 1024;

#[derive(Debug)]
pub struct SourceInfo {
    pub status: String,
    pub frontmatter: String,
    pub name: String,
    pub description: String,
}

impl SourceInfo {
    fn unavailable(reason: &str) -> Self {
        Self {
            status: format!("unavailable ({reason})"),
            frontmatter: "unknown".into(),
            name: "unknown".into(),
            description: "unknown".into(),
        }
    }
}

fn git_command(repo: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new("git");
    // Config selectors, injected -c entries, replacement objects, and inherited
    // pathspec modes must not redirect the explicitly selected source.
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("GIT_")
        {
            cmd.env_remove(key);
        }
    }
    let null = if cfg!(windows) { "NUL" } else { "/dev/null" };
    cmd.args([
        "--no-pager",
        "--literal-pathspecs",
        "-c",
        "core.fsmonitor=false",
    ])
    .arg("-C")
    .arg(repo)
    .args(args)
    .env("GIT_CONFIG_NOSYSTEM", "1")
    .env("GIT_CONFIG_SYSTEM", null)
    .env("GIT_CONFIG_GLOBAL", null)
    .env("GIT_NO_LAZY_FETCH", "1")
    .env("GIT_NO_REPLACE_OBJECTS", "1")
    .env("GIT_ALLOW_PROTOCOL", "")
    .env("GIT_TERMINAL_PROMPT", "0")
    .env("GIT_OPTIONAL_LOCKS", "0")
    .env("GIT_PAGER", "cat")
    .env("LC_ALL", "C")
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::null());
    cmd
}

fn git(repo: &Path, args: &[&str], limit: usize) -> Option<Vec<u8>> {
    let mut child = git_command(repo, args).spawn().ok()?;
    let mut bytes = Vec::new();
    let result = child
        .stdout
        .take()?
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes);
    if result.is_err() || bytes.len() > limit {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }
    child.wait().ok()?.success().then_some(bytes)
}

fn oid(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|c| c.is_ascii_hexdigit())
}

fn safe_path(path: &str) -> bool {
    path == "."
        || (path
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._/-".contains(&c))
            && path.split('/').all(|part| !matches!(part, "" | "." | "..")))
}

pub fn read(
    repo: Option<&Path>,
    commit: &str,
    skill_path: &str,
    expected_name: &str,
) -> SourceInfo {
    let Some(repo) = repo else {
        return SourceInfo::unavailable("source alias was not supplied");
    };
    if !oid(commit) || !safe_path(skill_path) {
        return SourceInfo::unavailable("invalid source pin or path");
    }
    if !repo.join(".git").exists()
        && !(repo.join("HEAD").is_file() && repo.join("objects").is_dir())
    {
        return SourceInfo::unavailable("source is not a local repository root");
    }
    if git(repo, &["cat-file", "-t", commit], 64).as_deref() != Some(b"commit\n") {
        return SourceInfo::unavailable("pinned commit is missing locally or is not a commit");
    }
    let file = if skill_path == "." {
        "SKILL.md".into()
    } else {
        format!("{skill_path}/SKILL.md")
    };
    let Some(tree) = git(
        repo,
        &["ls-tree", "--full-tree", "-z", commit, "--", &file],
        MAX_BYTES,
    ) else {
        return SourceInfo::unavailable("pinned SKILL.md cannot be located");
    };
    let Some((head, found)) = std::str::from_utf8(&tree)
        .ok()
        .and_then(|s| s.split_once('\t'))
    else {
        return SourceInfo::unavailable("pinned SKILL.md is not a regular blob");
    };
    let parts: Vec<_> = head.split(' ').collect();
    if parts.len() != 3
        || !matches!(parts[0], "100644" | "100755")
        || parts[1] != "blob"
        || !oid(parts[2])
        || found != format!("{file}\0")
    {
        return SourceInfo::unavailable("pinned SKILL.md is not a regular blob");
    }
    let size = git(repo, &["cat-file", "-s", parts[2]], 32)
        .and_then(|s| String::from_utf8(s).ok())
        .and_then(|s| s.trim().parse::<usize>().ok());
    if !size.is_some_and(|size| size <= MAX_BYTES) {
        return SourceInfo::unavailable("pinned SKILL.md exceeds the byte limit or cannot be read");
    }
    let Some(blob) = git(repo, &["cat-file", "blob", parts[2]], MAX_BYTES) else {
        return SourceInfo::unavailable("pinned SKILL.md cannot be read");
    };
    let Ok(text) = std::str::from_utf8(&blob) else {
        return SourceInfo::unavailable("pinned SKILL.md is not UTF-8");
    };
    let mut info = parse(text);
    if info.frontmatter == "parsed" && info.name != expected_name {
        info.status = "unavailable (pinned name does not match catalog id)".into();
    }
    info
}

fn display(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if ch == '\\'
            || ch.is_control()
            || matches!(ch, '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}')
        {
            out.extend(ch.escape_debug());
        } else {
            out.push(ch);
        }
    }
    out
}

fn scalar(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if let Some(inner) = value.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')) {
        let mut result = String::new();
        let mut chars = inner.chars();
        while let Some(ch) = chars.next() {
            if ch == '\'' && chars.next() != Some('\'') {
                return None;
            }
            result.push(ch);
        }
        return Some(result);
    }
    if let Some(inner) = value.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        return (!inner.contains(['\\', '"'])).then(|| inner.to_string());
    }
    let first = value.chars().next()?;
    if "'\"!&*[{]}>,|%@`#?:-".contains(first)
        || value.contains(": ")
        || value.ends_with(':')
        || value.contains(" #")
        || value.contains('\t')
        || value.chars().any(char::is_control)
        || matches!(
            value.to_ascii_lowercase().as_str(),
            "null" | "~" | "true" | "false" | "yes" | "no" | "on" | "off"
        )
        || first.is_ascii_digit()
        || first == '+'
        || first == '.'
    {
        return None;
    }
    Some(value.to_string())
}

fn simple_key(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
}

fn parse(text: &str) -> SourceInfo {
    let mut info = SourceInfo {
        status: "available (pinned local Git object)".into(),
        frontmatter: "parsed".into(),
        name: "unknown".into(),
        description: "unknown".into(),
    };
    let parsed = fields(text);
    match parsed {
        Ok((name, description)) => {
            info.name = display(&name);
            info.description = display(&description);
        }
        Err(reason) => info.frontmatter = format!("unsupported ({reason})"),
    }
    info
}

// The shared YAML subset accepts ambiguous Bash-era forms, so pinned source
// metadata uses a stricter reader and reports unsupported forms as unknown.
fn fields(text: &str) -> Result<(String, String), &'static str> {
    let lines: Vec<_> = text.lines().collect();
    if lines.first().copied() != Some("---") {
        return Err("no opening delimiter");
    }
    let end = lines
        .iter()
        .enumerate()
        .skip(1)
        .find_map(|(i, s)| (*s == "---").then_some(i))
        .ok_or("no closing delimiter")?;
    if lines[..end]
        .iter()
        .any(|line| line.chars().any(|ch| ch.is_control() && ch != '\t'))
    {
        return Err("control character in frontmatter");
    }
    let mut name = None;
    let mut description = None;
    let mut i = 1;
    while i < end {
        let line = lines[i];
        if line.is_empty() || line.trim_start().starts_with('#') {
            i += 1;
            continue;
        }
        if line.starts_with(char::is_whitespace) {
            return Err("unsupported indented content");
        }
        let (key, raw) = line.split_once(':').ok_or("unsupported top-level line")?;
        if !simple_key(key) {
            return Err("unsupported top-level field");
        }
        if !raw.is_empty() && !raw.starts_with(' ') {
            return Err("unsupported field separator");
        }
        let value = raw.trim();
        if key == "metadata" {
            if !value.is_empty() {
                return Err("unsupported metadata mapping");
            }
            i += 1;
            let mut entries = 0;
            while i < end {
                let line = lines[i];
                if line.is_empty() || line.trim_start().starts_with('#') {
                    i += 1;
                    continue;
                }
                if !line.starts_with(char::is_whitespace) {
                    break;
                }
                let entry = line
                    .strip_prefix("  ")
                    .ok_or("unsupported metadata mapping")?;
                let (field, raw) = entry
                    .split_once(':')
                    .ok_or("unsupported metadata mapping")?;
                if !simple_key(field) || !raw.starts_with(' ') || scalar(raw).is_none() {
                    return Err("unsupported metadata mapping");
                }
                entries += 1;
                i += 1;
            }
            if entries == 0 {
                return Err("empty metadata mapping");
            }
            continue;
        }
        if !matches!(key, "name" | "description") {
            scalar(value).ok_or("unsupported top-level field")?;
            i += 1;
            continue;
        }
        let slot = if key == "name" {
            &mut name
        } else {
            &mut description
        };
        if slot.is_some() {
            return Err("duplicate field");
        }
        if key == "description" && matches!(value, ">" | ">-" | ">+" | "|" | "|-" | "|+") {
            let mut block = Vec::new();
            i += 1;
            while i < end {
                let line = lines[i];
                if line.is_empty() || line.starts_with(char::is_whitespace) {
                    let body = line.strip_prefix("  ").ok_or("complex description block")?;
                    if body.is_empty() || body.starts_with(char::is_whitespace) {
                        return Err("complex description block");
                    }
                    block.push(body);
                    i += 1;
                } else {
                    break;
                }
            }
            if block.is_empty() {
                return Err("empty description block");
            }
            let separator = if value.starts_with('>') { " " } else { "\n" };
            let mut joined = block.join(separator);
            if !value.ends_with('-') {
                joined.push('\n');
            }
            *slot = Some(joined);
            continue;
        }
        *slot = Some(scalar(value).ok_or("unsupported or empty scalar")?);
        i += 1;
    }
    let name = name.filter(|s| !s.is_empty()).ok_or("missing name")?;
    let description = description
        .filter(|s| !s.is_empty())
        .ok_or("missing description")?;
    Ok((name, description))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, String) {
        let repo = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            let output = Command::new("git")
                .arg("-C")
                .arg(repo.path())
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env(
                    "GIT_CONFIG_GLOBAL",
                    if cfg!(windows) { "NUL" } else { "/dev/null" },
                )
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        };
        run(&["init", "--quiet"]);
        run(&["config", "user.name", "Test"]);
        run(&["config", "user.email", "test@example.invalid"]);
        std::fs::write(
            repo.path().join("SKILL.md"),
            "---\nname: pdf\ndescription: Pinned text\n---\n",
        )
        .unwrap();
        run(&["add", "SKILL.md"]);
        run(&["commit", "--quiet", "-m", "fixture"]);
        let commit = run(&["rev-parse", "HEAD"]);
        run(&["tag", "-a", "fixture-tag", "-m", "not a commit"]);
        (repo, commit)
    }

    #[test]
    fn source_reads_only_the_pin_and_rejects_tag_ids() {
        let (repo, commit) = fixture();
        std::fs::write(repo.path().join("SKILL.md"), "dirty checkout").unwrap();
        let info = read(Some(repo.path()), &commit, ".", "pdf");
        assert!(info.status.starts_with("available"));
        assert_eq!(info.name, "pdf");
        assert_eq!(info.description, "Pinned text");
        let tag = git(repo.path(), &["rev-parse", "fixture-tag"], 128).unwrap();
        let tag = std::str::from_utf8(&tag).unwrap().trim();
        assert!(
            read(Some(repo.path()), tag, ".", "pdf")
                .status
                .starts_with("unavailable")
        );
        assert!(
            read(Some(repo.path()), &commit, ".", "other")
                .status
                .starts_with("unavailable")
        );
        std::fs::create_dir(repo.path().join("child")).unwrap();
        assert!(
            read(Some(&repo.path().join("child")), &commit, ".", "pdf")
                .status
                .starts_with("unavailable")
        );
    }

    #[test]
    fn oversized_source_blobs_are_refused_before_parsing() {
        let (repo, _) = fixture();
        std::fs::write(repo.path().join("SKILL.md"), "x".repeat(MAX_BYTES + 1)).unwrap();
        for args in [
            &["add", "SKILL.md"][..],
            &["commit", "--quiet", "-m", "large"][..],
        ] {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(repo.path())
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            );
        }
        let commit = git(repo.path(), &["rev-parse", "HEAD"], 128).unwrap();
        let info = read(
            Some(repo.path()),
            std::str::from_utf8(&commit).unwrap().trim(),
            ".",
            "pdf",
        );
        assert!(info.status.contains("byte limit"));
        assert_eq!(info.description, "unknown");
    }

    #[cfg(unix)]
    #[test]
    fn pinned_symlinks_are_not_followed() {
        let (repo, _) = fixture();
        std::fs::remove_file(repo.path().join("SKILL.md")).unwrap();
        std::os::unix::fs::symlink("outside", repo.path().join("SKILL.md")).unwrap();
        for args in [
            &["add", "SKILL.md"][..],
            &["commit", "--quiet", "-m", "symlink"][..],
        ] {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(repo.path())
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            );
        }
        let commit = git(repo.path(), &["rev-parse", "HEAD"], 128).unwrap();
        let info = read(
            Some(repo.path()),
            std::str::from_utf8(&commit).unwrap().trim(),
            ".",
            "pdf",
        );
        assert!(info.status.contains("not a regular blob"));
        assert_eq!(info.description, "unknown");
    }

    #[cfg(unix)]
    #[test]
    fn hostile_local_pager_and_missing_promisor_object_do_not_execute() {
        let (repo, commit) = fixture();
        let marker = repo.path().join("executed");
        let evil = format!("touch '{}'", marker.display());
        for (key, value) in [
            ("pager.cat-file", evil.as_str()),
            ("core.pager", evil.as_str()),
            ("remote.origin.promisor", "true"),
            ("remote.origin.url", "ext::touch executed"),
        ] {
            let status = Command::new("git")
                .arg("-C")
                .arg(repo.path())
                .args(["config", key, value])
                .status()
                .unwrap();
            assert!(status.success());
        }
        assert!(
            read(Some(repo.path()), &commit, ".", "pdf")
                .status
                .starts_with("available")
        );
        assert!(
            read(Some(repo.path()), &"0".repeat(40), ".", "pdf")
                .status
                .starts_with("unavailable")
        );
        assert!(!marker.exists());
    }

    #[test]
    fn missing_fields_never_shift_or_expose_partial_descriptions() {
        for text in [
            "---\ndescription: PDF text\n---",
            "---\nname: pdf\n---",
            "---\nname: pdf\ndescription: |\n  first\n\n  last\n---",
        ] {
            let info = parse(text);
            assert!(info.frontmatter.starts_with("unsupported"));
            assert_eq!(info.name, "unknown");
            assert_eq!(info.description, "unknown");
        }
    }

    #[test]
    fn unsupported_extra_fields_leave_source_metadata_unknown() {
        for extra in [
            "extra: [unterminated",
            "metadata: [unterminated",
            "metadata:\n  author: [unterminated",
            "extra: valid\n  unexpected: indentation",
            "[invalid: value",
        ] {
            let info = parse(&format!(
                "---\nname: pdf\ndescription: Valid description\n{extra}\n---\n"
            ));
            assert!(info.frontmatter.starts_with("unsupported"), "{extra}");
            assert_eq!(info.name, "unknown", "{extra}");
            assert_eq!(info.description, "unknown", "{extra}");
        }
    }

    #[test]
    fn ordinary_optional_fields_preserve_source_metadata() {
        let info = parse(
            "---\nname: pdf\ndescription: Valid description\nlicense: MIT\ncompatibility: Requires git\nallowed-tools: Bash(git:*) Read\nmetadata:\n  author: example-org\n  version: '1.0'\n---\n",
        );
        assert_eq!(info.frontmatter, "parsed");
        assert_eq!(info.name, "pdf");
        assert_eq!(info.description, "Valid description");
    }

    #[test]
    fn ambiguous_scalars_are_never_canonical() {
        for value in [
            "first\n  second",
            ">2\n  words",
            "|-2\n  words",
            "Use when: foo",
            "true",
            "123",
            "\"an \\n escape\"",
            "'stray'quote'",
            "\"stray\"quote\"",
            "text # comment",
        ] {
            let info = parse(&format!("---\nname: pdf\ndescription: {value}\n---"));
            assert!(info.frontmatter.starts_with("unsupported"), "{value}");
            assert_eq!(info.description, "unknown");
        }
    }

    #[test]
    fn delimiters_report_the_correct_failure() {
        assert_eq!(
            parse("name: pdf").frontmatter,
            "unsupported (no opening delimiter)"
        );
        assert_eq!(
            parse("---\nname: pdf").frontmatter,
            "unsupported (no closing delimiter)"
        );
    }

    #[test]
    fn simple_fields_and_blocks_have_explicit_newlines() {
        assert_eq!(
            parse("---\nname: pdf\ndescription: 'It''s useful'\n---").description,
            "It's useful"
        );
        assert_eq!(
            parse("---\nname: pdf\ndescription: >-\n  first\n  second\n---").description,
            "first second"
        );
        assert_eq!(
            parse("---\nname: pdf\ndescription: |\n  first\n  second\n---").description,
            "first\\nsecond\\n"
        );
        assert_eq!(
            parse("---\r\nname: pdf\r\ndescription: text\r\n---\r\n").frontmatter,
            "parsed"
        );
    }

    #[test]
    fn controls_are_escaped_without_inventing_nul_bytes() {
        assert_eq!(display("a\u{1b}\u{7}\u{7f}b"), "a\\u{1b}\\u{7}\\u{7f}b");
        assert_eq!(display("a\u{061c}\u{feff}b"), "a\\u{61c}\\u{feff}b");
    }

    #[test]
    fn git_process_cannot_use_pagers_or_transport() {
        let cmd = git_command(Path::new("."), &["cat-file", "-t", "unused"]);
        let args: Vec<_> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
        assert!(args.contains(&"--no-pager"));
        assert!(args.contains(&"--literal-pathspecs"));
        let env: std::collections::BTreeMap<_, _> = cmd.get_envs().collect();
        assert_eq!(
            env[std::ffi::OsStr::new("GIT_ALLOW_PROTOCOL")],
            Some(std::ffi::OsStr::new(""))
        );
        assert_eq!(
            env[std::ffi::OsStr::new("GIT_NO_LAZY_FETCH")],
            Some(std::ffi::OsStr::new("1"))
        );
    }
}
