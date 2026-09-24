mod common;

use common::Project;
use predicates::prelude::*;

const CONFIG: &str = ".codex/config.toml";
const SETTINGS: &str = ".ai/src/tools/codex/settings.toml";
const APP_STATE: &str = "\n[projects.\"/tmp/p\"]\ntrust_level = \"trusted\"\n\n[mcp_servers.repl]\ncommand = \"node_repl\"\nstartup_timeout_sec = 120\n";

fn codex_project(ownership: Option<&str>) -> Project {
    let project = Project::seeded(&[]);
    project.enable_tools(&["codex"]);
    if let Some(mode) = ownership {
        project.write(
            ".ai/src/tools/codex.yaml",
            &format!("targets:\n  settings:\n    ownership: {mode}\n"),
        );
    }
    project.write(SETTINGS, "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n");
    project.write(
        ".ai/src/mcp.json",
        r#"{"mcpServers":{"dart":{"command":"dart","args":["mcp-server"]}}}"#,
    );
    project
}

fn sync(project: &Project) -> assert_cmd::assert::Assert {
    project
        .agentsync()
        .args(["sync", "--only", "codex"])
        .assert()
}

#[test]
fn app_written_keys_survive_sync_and_check() {
    let project = codex_project(Some("keys"));
    sync(&project).success();
    assert_eq!(
        project.read(CONFIG),
        "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n\n[mcp_servers.dart]\ncommand = \"dart\"\nargs = [\"mcp-server\"]\n"
    );
    project.append(CONFIG, APP_STATE);
    let with_app_state = project.read(CONFIG);

    project.agentsync().arg("check").assert().success();
    sync(&project).success();
    assert_eq!(project.read(CONFIG), with_app_state);
    let manifest = project.read(".ai/.sync-manifest");
    let line = manifest
        .lines()
        .find(|line| line.starts_with(".codex/config.toml\t"))
        .unwrap();
    assert_eq!(line.split('\t').count(), 3);
}

#[test]
fn a_changed_owned_key_stops_sync_and_names_it() {
    let project = codex_project(Some("keys"));
    sync(&project).success();
    project.append(CONFIG, APP_STATE);
    let edited = project.read(CONFIG).replace("\"gpt\"", "\"ui-pick\"");
    project.write(CONFIG, &edited);

    sync(&project)
        .failure()
        .stderr(predicate::str::contains(".codex/config.toml (model)"));
    assert_eq!(project.read(CONFIG), edited);
    project
        .agentsync()
        .arg("check")
        .assert()
        .failure()
        .stdout(predicate::str::contains(".codex/config.toml"));

    project
        .agentsync()
        .args(["sync", "--only", "codex", "--force"])
        .assert()
        .success();
    let forced = project.read(CONFIG);
    assert!(forced.contains("model = \"gpt\""));
    assert!(forced.contains("[projects.\"/tmp/p\"]"));
    assert!(forced.contains("[mcp_servers.repl]"));
}

#[test]
fn keys_dropped_from_the_sources_leave_the_live_file() {
    let project = codex_project(Some("keys"));
    sync(&project).success();
    project.append(CONFIG, APP_STATE);
    project.write(SETTINGS, "model = \"gpt\"\n");
    project.write(".ai/src/mcp.json", r#"{"mcpServers":{}}"#);

    sync(&project).success();
    assert_eq!(
        project.read(CONFIG),
        "model = \"gpt\"\n\n[projects.\"/tmp/p\"]\ntrust_level = \"trusted\"\n\n[mcp_servers.repl]\ncommand = \"node_repl\"\nstartup_timeout_sec = 120\n"
    );
}

#[test]
fn a_first_keyed_sync_stops_on_a_value_it_never_owned() {
    let project = codex_project(Some("keys"));
    project.write(CONFIG, "model = \"ui-pick\"\n");
    sync(&project)
        .failure()
        .stderr(predicate::str::contains(
            "differs from .ai/src in 1 key(s) sync has not owned before",
        ))
        .stderr(predicate::str::contains("      model\n"));
    assert_eq!(project.read(CONFIG), "model = \"ui-pick\"\n");

    project
        .agentsync()
        .args(["sync", "--only", "codex", "--force"])
        .assert()
        .success();
    assert!(project.read(CONFIG).starts_with("model = \"gpt\"\n"));
}

#[test]
fn switching_to_keys_keeps_what_the_app_wrote_after_a_whole_file_sync() {
    let project = codex_project(None);
    sync(&project).success();
    project.append(CONFIG, APP_STATE);
    let with_app_state = project.read(CONFIG);

    project.write(
        ".ai/src/tools/codex.yaml",
        "targets:\n  settings:\n    ownership: keys\n",
    );
    sync(&project).success();
    assert_eq!(project.read(CONFIG), with_app_state);
}

#[test]
fn auto_owns_keys_when_the_project_root_is_home() {
    let project = codex_project(None);
    let home = project.path().to_str().unwrap().to_string();
    let run = |args: &[&str]| project.agentsync().env("HOME", &home).args(args).assert();
    run(&["sync", "--only", "codex"]).success();
    project.append(CONFIG, APP_STATE);
    run(&["sync", "--only", "codex"]).success();
    assert!(project.read(CONFIG).contains("[projects.\"/tmp/p\"]"));
}

#[test]
fn auto_owns_the_whole_file_in_a_repository() {
    let project = codex_project(None);
    sync(&project).success();
    project.append(CONFIG, APP_STATE);
    sync(&project)
        .failure()
        .stderr(predicate::str::contains("Manual edits detected"));
}

#[test]
fn rollback_restores_the_whole_config() {
    let project = codex_project(Some("keys"));
    sync(&project).success();
    project.append(CONFIG, APP_STATE);
    let before = project.read(CONFIG);
    project.write(SETTINGS, "model = \"other\"\n");
    sync(&project).success();
    assert_ne!(project.read(CONFIG), before);

    project
        .agentsync()
        .args(["rollback", "--yes"])
        .assert()
        .success();
    assert_eq!(project.read(CONFIG), before);
}

#[test]
fn live_toml_that_does_not_parse_stops_sync_before_writing() {
    let project = codex_project(Some("keys"));
    sync(&project).success();
    project.write(CONFIG, "model = \n");
    project
        .agentsync()
        .args(["sync", "--only", "codex", "--force"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "Cannot merge into .codex/config.toml",
        ));
    assert_eq!(project.read(CONFIG), "model = \n");
}
