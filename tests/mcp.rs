mod common;

use common::Project;
use predicates::prelude::*;

fn manifest(id: &str, title: &str) -> String {
    format!(
        r#"{{"schema_version":1,"id":"{id}","title":"{title}","connection":{{"type":"stdio","command":"never-run","args":[]}},"requirements":{{"binaries":[],"inputs":[]}}}}"#
    )
}

#[test]
fn help_and_read_only_commands_need_no_project_setup() {
    let project = Project::empty();
    project
        .agentsync()
        .args(["mcp", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("mcp list --library"));

    project.write("catalog/zeta/manifest.json", &manifest("zeta", "Last"));
    project.write("catalog/alpha/manifest.json", &manifest("alpha", "First"));
    project
        .agentsync()
        .args(["mcp", "list", "--library", "catalog"])
        .assert()
        .success()
        .stdout("alpha\tFirst\nzeta\tLast\n");
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .success()
        .stdout("MCP library is valid\n");
    assert!(!project.exists("never-run"));
}

#[test]
fn show_preserves_exact_source_bytes_and_validates_only_the_selected_entry() {
    let project = Project::empty();
    let original = format!("{}\n", manifest("alpha", "Grüße"));
    project.write("catalog/alpha/manifest.json", &original);
    project.write("catalog/broken/manifest.json", "not JSON");
    project
        .agentsync()
        .args(["mcp", "show", "alpha", "--library", "catalog"])
        .assert()
        .success()
        .stdout(original);
    project
        .agentsync()
        .args(["mcp", "list", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("");
}

#[test]
fn render_default_stdio_as_source_without_running_or_writing() {
    let project = Project::empty();
    project.write("catalog/alpha/manifest.json", &manifest("alpha", "First"));
    project.write("catalog/broken/manifest.json", "not JSON");
    for selection in ["alpha", "alpha@default"] {
        project
            .agentsync()
            .args(["mcp", "render", selection, "--library", "catalog"])
            .assert()
            .success()
            .stdout("{\"mcpServers\":{\"alpha\":{\"args\":[],\"command\":\"never-run\"}}}\n");
    }
    assert!(!project.exists("never-run"));
    assert!(!project.exists(".ai/src/mcp/claude.json"));
    assert!(!project.exists(".mcp.json"));
}

#[test]
fn render_resolves_http_alternatives_and_recommendation_explicitly() {
    let project = Project::empty();
    let v2 = r#"{"schema_version":2,"id":"docs","title":"Docs","connection":{"type":"http","url":"https://example.invalid/default"},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"remote":{"connection":{"type":"http","url":"https://example.invalid/remote"},"requirements":{"binaries":[],"inputs":[]}}},"guidance":{"recommended":"remote","authority":"vendor","source":"https://example.invalid/docs","checked_at":"2024-02-29","reason":"Documented remote option"}}"#;
    project.write("catalog/docs/manifest.json", v2);
    project
        .agentsync()
        .args(["mcp", "render", "docs", "--library", "catalog"])
        .assert()
        .success()
        .stdout("{\"mcpServers\":{\"docs\":{\"type\":\"http\",\"url\":\"https://example.invalid/default\"}}}\n");
    for selection in ["docs@remote", "docs@recommended"] {
        project
            .agentsync()
            .args(["mcp", "render", selection, "--library", "catalog"])
            .assert()
            .success()
            .stdout("{\"mcpServers\":{\"docs\":{\"type\":\"http\",\"url\":\"https://example.invalid/remote\"}}}\n");
    }
    project.write(
        "catalog/docs/manifest.json",
        &v2.replace("\"recommended\":\"remote\"", "\"recommended\":\"default\""),
    );
    project
        .agentsync()
        .args(["mcp", "render", "docs@recommended", "--library", "catalog"])
        .assert()
        .success()
        .stdout("{\"mcpServers\":{\"docs\":{\"type\":\"http\",\"url\":\"https://example.invalid/default\"}}}\n");
}

#[test]
fn render_rejects_bad_selections_and_invalid_manifests_without_stdout() {
    let project = Project::empty();
    project.write("catalog/alpha/manifest.json", &manifest("alpha", "First"));
    for selection in ["alpha@", "alpha@bad/name", "alpha@@remote", "../alpha"] {
        project
            .agentsync()
            .args(["mcp", "render", selection, "--library", "catalog"])
            .assert()
            .failure()
            .stdout("");
    }
    project
        .agentsync()
        .args(["mcp", "render", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains("requires an id"));
    project
        .agentsync()
        .args(["mcp", "render", "alpha@recommended", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains("no attributed recommendation"));
    project
        .agentsync()
        .args(["mcp", "render", "alpha@remote", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains("Unknown MCP variant"));
    project.write("catalog/alpha/manifest.json", "not JSON");
    project
        .agentsync()
        .args(["mcp", "render", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("");
}

#[test]
fn render_serializes_connection_strings_as_json_data() {
    let project = Project::empty();
    let escaped = manifest("alpha", "First").replace(
        "\"command\":\"never-run\",\"args\":[]",
        r#""command":"a\"b\\c","args":["line\nnext","\u0000"]"#,
    );
    project.write("catalog/alpha/manifest.json", &escaped);
    project
        .agentsync()
        .args(["mcp", "render", "alpha", "--library", "catalog"])
        .assert()
        .success()
        .stdout("{\"mcpServers\":{\"alpha\":{\"args\":[\"line\\nnext\",\"\\u0000\"],\"command\":\"a\\\"b\\\\c\"}}}\n");
}

#[test]
fn configured_catalog_stays_inside_project_root() {
    let project = Project::empty();
    project.write(
        ".ai/agent_sync.yaml",
        "library:\n  mcp:\n    path: catalog\n",
    );
    project.write("catalog/alpha/manifest.json", &manifest("alpha", "First"));
    project
        .agentsync()
        .args(["mcp", "list"])
        .assert()
        .success()
        .stdout("alpha\tFirst\n");

    let external = tempfile::tempdir().unwrap();
    project.write(
        ".ai/agent_sync.yaml",
        &format!(
            "library:\n  mcp:\n    path: {}\n",
            external.path().display()
        ),
    );
    project
        .agentsync()
        .args(["mcp", "list"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("outside the project root"));
}

#[test]
fn duplicate_keys_and_oversized_or_deep_manifests_fail_without_stdout() {
    let project = Project::empty();
    let path = "catalog/alpha/manifest.json";
    let duplicate = manifest("alpha", "First").replace(
        "\"connection\":",
        "\"extensions\":{\"example.dev\":{\"key\":1,\"\\u006bey\":2}},\"connection\":",
    );
    project.write(path, &duplicate);
    project
        .agentsync()
        .args(["mcp", "show", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains("duplicate JSON key: key"));

    let oversized = " ".repeat(131_073);
    project.write(path, &oversized);
    project
        .agentsync()
        .args(["mcp", "validate", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("byte limit"));

    let deep = manifest("alpha", "First").replace(
        "\"connection\":",
        &format!(
            "\"extensions\":{{\"example.dev\":{}0{}}},\"connection\":",
            "[".repeat(17),
            "]".repeat(17)
        ),
    );
    project.write(path, &deep);
    project
        .agentsync()
        .args(["mcp", "validate", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("depth limit"));
}

#[test]
fn v2_validates_every_variant_and_attributed_guidance() {
    let project = Project::empty();
    let v2 = r#"{"schema_version":2,"id":"docs","title":"Docs","connection":{"type":"http","url":"https://example.invalid/mcp"},"requirements":{"binaries":[],"inputs":[]},"alternatives":{"local":{"connection":{"type":"stdio","command":"never-run","args":[]},"requirements":{"binaries":[],"inputs":[]}}},"guidance":{"recommended":"local","authority":"vendor","source":"https://example.invalid/docs","checked_at":"2024-02-29","reason":"Documented local option"}}"#;
    project.write("catalog/docs/manifest.json", v2);
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .success();

    project.write(
        "catalog/docs/manifest.json",
        &v2.replace("2024-02-29", "2026-02-29"),
    );
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("guidance.checked_at"));

    project.write(
        "catalog/docs/manifest.json",
        &v2.replace(",\"args\":[]", ""),
    );
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("args"));

    project.write(
        "catalog/docs/manifest.json",
        &v2.replace("https://example.invalid/docs", "https://:"),
    );
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("guidance.source"));
}

#[test]
fn schema_errors_reject_unknown_fields_inputs_and_mismatched_ids() {
    let project = Project::empty();
    let original = manifest("alpha", "First");
    for invalid in [
        original.replace("\"id\":\"alpha\"", "\"id\":\"other\""),
        original.replace("\"inputs\":[]", "\"inputs\":[\"TOKEN\"]"),
        original.replace("\"schema_version\":1", "\"schema_version\":99"),
        original.replace("\"title\":\"First\"", "\"title\":\"First\",\"bogus\":true"),
        original.replace(
            "\"schema_version\":1",
            "\"schema_version\":1,\"alternatives\":{}",
        ),
    ] {
        project.write("catalog/alpha/manifest.json", &invalid);
        project
            .agentsync()
            .args(["mcp", "validate", "alpha", "--library", "catalog"])
            .assert()
            .failure()
            .stdout("");
    }
}

#[test]
fn escaped_nul_is_data_but_raw_nul_is_invalid_json() {
    let project = Project::empty();
    let original = manifest("alpha", "First").replace("First", r"First\u0000End");
    project.write("catalog/alpha/manifest.json", &original);
    project
        .agentsync()
        .args(["mcp", "show", "alpha", "--library", "catalog"])
        .assert()
        .success()
        .stdout(original);

    let raw = manifest("alpha", "First").replace("First", "First\0End");
    project.write("catalog/alpha/manifest.json", &raw);
    project
        .agentsync()
        .args(["mcp", "validate", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("");
}

#[test]
fn list_escapes_control_characters_in_titles() {
    let project = Project::empty();
    let title = format!(
        r"Привет\n\t\u0085\u202e{}{}{}",
        '\u{00ad}', '\u{3164}', '\u{e0100}'
    );
    project.write("catalog/alpha/manifest.json", &manifest("alpha", &title));
    project
        .agentsync()
        .args(["mcp", "list", "--library", "catalog"])
        .assert()
        .success()
        .stdout("alpha\tПривет\\n\\t\\u0085\\u202e\\u00ad\\u3164\\u{e0100}\n");
}

#[test]
fn diagnostics_escape_untrusted_json_keys() {
    let project = Project::empty();
    let path = "catalog/alpha/manifest.json";
    let original = manifest("alpha", "First");
    let key = r"\u001b[31m";
    project.write(
        path,
        &original.replace(
            "\"connection\":",
            &format!("\"{key}\":1,\"{key}\":2,\"connection\":"),
        ),
    );
    project
        .agentsync()
        .args(["mcp", "validate", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stdout("")
        .stderr(predicate::str::contains(r"duplicate JSON key: \u001b[31m"));

    project.write(
        path,
        &original.replace("\"connection\":", &format!("\"{key}\":1,\"connection\":")),
    );
    let output = project
        .agentsync()
        .args(["mcp", "validate", "alpha", "--library", "catalog"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!output.stderr.contains(&0x1b));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains(r"unknown manifest field: \u001b[31m")
    );
}

#[test]
fn catalog_entry_limit_and_unsafe_ids_are_rejected() {
    let project = Project::empty();
    for index in 0..257 {
        std::fs::create_dir_all(project.join(&format!("catalog/item{index}"))).unwrap();
    }
    project
        .agentsync()
        .args(["mcp", "validate", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("entry limit"));
    project
        .agentsync()
        .args(["mcp", "show", "../item0", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Unsafe MCP library id"));
}

// Windows symlink creation can require Developer Mode or elevated privileges.
#[cfg(unix)]
#[test]
fn symlinks_cannot_escape_the_selected_catalog() {
    use std::os::unix::fs::symlink;

    let project = Project::empty();
    project.write("outside.json", &manifest("alpha", "Outside"));
    std::fs::create_dir_all(project.join("catalog/alpha")).unwrap();
    symlink(
        project.join("outside.json"),
        project.join("catalog/alpha/manifest.json"),
    )
    .unwrap();
    project
        .agentsync()
        .args(["mcp", "show", "alpha", "--library", "catalog"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not a regular file"));
}
