//! `tests/add.bats`: `agentsync add <kind> <name>` and `agentsync add mcp`.

mod common;

use common::Project;
use predicates::prelude::*;

fn seeded() -> Project {
    Project::seeded(&[])
}

// ── Happy paths ──────────────────────────────────────────────────────────────

#[test]
fn add_rule_creates_ai_src_rules_name_md() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .success();
    assert!(
        project
            .read(".ai/src/rules/testing.md")
            .starts_with("# Testing\n")
    );
}

#[test]
fn add_skill_creates_ai_src_skills_name_skill_md() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "skill", "deploy"])
        .assert()
        .success();
    let content = project.read(".ai/src/skills/deploy/SKILL.md");
    assert!(content.contains("\nname: \"deploy\"\n"));
    assert!(content.contains("\ndescription:"));
}

#[test]
fn add_skill_rejects_names_outside_the_agent_skills_spec() {
    let project = seeded();
    for name in ["MySkill", "my_skill", "my--skill", "my-skill-"] {
        project
            .agentsync()
            .args(["add", "skill", name])
            .assert()
            .failure()
            .stderr(predicate::str::contains("Skill name must be"));
        assert!(!project.exists(&format!(".ai/src/skills/{name}/SKILL.md")));
    }
}

#[test]
fn add_command_creates_ai_src_commands_name_md_with_description_frontmatter() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "command", "deploy"])
        .assert()
        .success();
    assert!(
        project
            .read(".ai/src/commands/deploy.md")
            .contains("\ndescription:")
    );
}

#[test]
fn add_subagent_creates_ai_src_agents_name_md() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "subagent", "reviewer"])
        .assert()
        .success();
    let content = project.read(".ai/src/agents/reviewer.md");
    assert!(content.contains("\nname: \"reviewer\"\n"));
    assert!(content.contains("\ntools:"));
}

#[test]
fn add_prints_next_step_hint() {
    seeded()
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .success()
        .stdout(predicate::str::contains("agentsync sync"));
}

// ── Rejections ───────────────────────────────────────────────────────────────

#[test]
fn add_with_no_args_fails_with_usage() {
    seeded()
        .agentsync()
        .arg("add")
        .assert()
        .failure()
        .stderr(predicate::str::contains("Error"))
        .stderr(predicate::str::contains("<kind>"));
}

#[test]
fn add_with_only_kind_fails_with_usage() {
    seeded()
        .agentsync()
        .args(["add", "rule"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Error"));
}

#[test]
fn add_rejects_unknown_kind() {
    seeded()
        .agentsync()
        .args(["add", "banana", "myname"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Unknown kind"));
}

#[test]
fn add_rejects_name_with_slash() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "sub/dir"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("path separators"));
    assert!(!project.exists(".ai/src/rules/sub"));
}

#[test]
fn add_rejects_name_with_dotdot() {
    seeded()
        .agentsync()
        .args(["add", "rule", "..evil"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("'..'"));
}

#[test]
fn add_rejects_name_with_relative_traversal() {
    seeded()
        .agentsync()
        .args(["add", "rule", "../evil"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("path separators"));
}

#[test]
fn add_rejects_name_starting_with_dot() {
    seeded()
        .agentsync()
        .args(["add", "rule", ".hidden"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("cannot start with"));
}

#[test]
fn add_rejects_name_with_space() {
    seeded()
        .agentsync()
        .args(["add", "rule", "my rule"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("letters, digits"));
}

#[test]
fn add_rejects_name_with_extension() {
    seeded()
        .agentsync()
        .args(["add", "rule", "testing.md"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("letters, digits"));
}

// ── Existing-file behavior ───────────────────────────────────────────────────

#[test]
fn add_refuses_existing_file_without_force() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Already exists"))
        .stderr(predicate::str::contains("--force"));
}

#[test]
fn add_force_overwrites_existing_file() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .success();
    project.write(".ai/src/rules/testing.md", "custom content\n");

    project
        .agentsync()
        .args(["add", "--force", "rule", "testing"])
        .assert()
        .success();
    let content = project.read(".ai/src/rules/testing.md");
    assert!(!content.contains("custom content"));
    assert!(content.starts_with("# Testing\n"));
}

#[test]
fn add_force_works_with_f_short_flag() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "testing"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "-f", "rule", "testing"])
        .assert()
        .success();
}

#[test]
fn add_refuses_existing_skill_directory_without_force() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "skill", "deploy"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "skill", "deploy"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Already exists"));
}

// ── Name-shape sanity ────────────────────────────────────────────────────────

#[test]
fn add_accepts_kebab_case_name() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "my-rule"])
        .assert()
        .success();
    assert!(project.exists(".ai/src/rules/my-rule.md"));
}

#[test]
fn add_accepts_snake_case_name() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "my_rule"])
        .assert()
        .success();
    assert!(project.exists(".ai/src/rules/my_rule.md"));
}

#[test]
fn add_accepts_digits_in_name() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "rule", "rule42"])
        .assert()
        .success();
    assert!(project.exists(".ai/src/rules/rule42.md"));
}

#[test]
fn add_substitutes_name_into_skill_frontmatter() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "skill", "my-skill"])
        .assert()
        .success();
    let content = project.read(".ai/src/skills/my-skill/SKILL.md");
    assert!(content.contains("\nname: \"my-skill\"\n"));
    assert!(content.contains("\n# My Skill\n"));
}

// ── add mcp ──────────────────────────────────────────────────────────────────

#[test]
fn add_mcp_creates_ai_src_mcp_json_on_first_run() {
    let project = seeded();
    assert!(!project.exists(".ai/src/mcp.json"));
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "github",
            "--command",
            "npx @github/mcp-server",
        ])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"npx @github/mcp-server\"}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_appends_a_second_server_without_touching_the_first() {
    let project = seeded();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "github",
            "--command",
            "npx @github/mcp-server",
        ])
        .assert()
        .success();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "linear",
            "--url",
            "https://mcp.linear.app/sse",
        ])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"github\": {\"command\":\"npx @github/mcp-server\"},\n    \"linear\": {\"type\":\"http\",\"url\":\"https://mcp.linear.app/sse\"}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_parses_args_into_a_list() {
    let project = seeded();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "fs",
            "--command",
            "fs-server",
            "--args",
            "--root /tmp --debug",
        ])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"fs\": {\"command\":\"fs-server\",\"args\":[\"--root\",\"/tmp\",\"--debug\"]}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_parses_env_pairs_into_a_map() {
    let project = seeded();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "gh",
            "--command",
            "gh-mcp",
            "--env",
            "TOKEN=abc,DEBUG=1",
        ])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"gh\": {\"command\":\"gh-mcp\",\"env\":{\"TOKEN\":\"abc\",\"DEBUG\":\"1\"}}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_refuses_duplicate_server_without_force() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "gh", "--command", "gh-mcp"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "gh", "--command", "other"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("already exists"));
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"gh\": {\"command\":\"gh-mcp\"}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_force_overwrites_existing_entry() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "gh", "--command", "gh-mcp"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "gh", "--command", "other", "--force"])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"gh\": {\"command\":\"other\"}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_requires_url_or_command() {
    seeded()
        .agentsync()
        .args(["add", "mcp", "gh"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--url or --command"));
}

#[test]
fn add_mcp_rejects_both_url_and_command() {
    seeded()
        .agentsync()
        .args([
            "add",
            "mcp",
            "gh",
            "--url",
            "https://example",
            "--command",
            "foo",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("mutually exclusive"));
}

#[test]
fn add_mcp_rejects_invalid_server_name() {
    seeded()
        .agentsync()
        .args(["add", "mcp", "bad/name", "--command", "x"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("path separators"));
}

#[test]
fn add_mcp_overwrites_a_middle_server_without_disturbing_its_siblings() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "aaa", "--command", "cmd-a"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "bbb", "--command", "cmd-b", "--args", "x y"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "ccc", "--url", "https://c"])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "bbb", "--command", "cmd-b2", "--force"])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"aaa\": {\"command\":\"cmd-a\"},\n    \"bbb\": {\"command\":\"cmd-b2\"},\n    \"ccc\": {\"type\":\"http\",\"url\":\"https://c\"}\n  }\n}\n"
    );
}

// `add mcp JSON-escapes quotes and backslashes in values`: the bats case wraps
// this in `MSYS_NO_PATHCONV=1` because Git Bash rewrote the backslash in the
// argument as a path separator. Rust's `Command` passes arguments verbatim, so
// no such workaround is needed here.
#[test]
fn add_mcp_json_escapes_quotes_and_backslashes_in_values() {
    let project = seeded();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "weird",
            "--command",
            "say \"hi\" path\\to",
            "--env",
            "MSG=a\"b",
        ])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"weird\": {\"command\":\"say \\\"hi\\\" path\\\\to\",\"env\":{\"MSG\":\"a\\\"b\"}}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_attaches_env_to_an_http_server() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "h", "--url", "https://x", "--env", "TOKEN=t"])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"h\": {\"type\":\"http\",\"url\":\"https://x\",\"env\":{\"TOKEN\":\"t\"}}\n  }\n}\n"
    );
}

// The exact expected content below is well-formed JSON by construction, which
// stands in for the bats case's `python3 -c "import json; json.load(...)"`
// parseability check without adding a JSON dependency.
#[test]
fn add_mcp_output_is_valid_json_parseable_across_repeated_edits() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "one", "--command", "c1"])
        .assert()
        .success();
    project
        .agentsync()
        .args([
            "add",
            "mcp",
            "two",
            "--command",
            "c2",
            "--args",
            "a b c",
            "--env",
            "K=v",
        ])
        .assert()
        .success();
    project
        .agentsync()
        .args(["add", "mcp", "three", "--url", "https://three"])
        .assert()
        .success();
    assert_eq!(
        project.read(".ai/src/mcp.json"),
        "{\n  \"mcpServers\": {\n    \"one\": {\"command\":\"c1\"},\n    \"two\": {\"command\":\"c2\",\"args\":[\"a\",\"b\",\"c\"],\"env\":{\"K\":\"v\"}},\n    \"three\": {\"type\":\"http\",\"url\":\"https://three\"}\n  }\n}\n"
    );
}

#[test]
fn add_mcp_names_a_flag_that_is_missing_its_value() {
    let project = seeded();
    project
        .agentsync()
        .args(["add", "mcp", "gh", "--url"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("--url requires a value."))
        .stderr(predicate::str::contains(
            "\n  USAGE\n    agentsync add <kind> <name> [--force]\n    agentsync add mcp <server>",
        ));
    assert!(!project.exists(".ai/src/mcp.json"));
}
