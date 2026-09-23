mod common;

use common::Project;
use predicates::prelude::*;

fn project() -> Project {
    let project = Project::empty();
    project.write(".ai/src/AGENTS.md", "# Agent\n");
    project.write(".ai/agent_sync.yaml", "base_skills: false\n");
    project
}

#[test]
fn list_reads_project_skills_without_a_catalog() {
    let project = project();
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: Deploy the app safely\n---\n\n# Deploy\n",
    );
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout("name\tdescription\tpath\ndeploy\tDeploy the app safely\t.ai/src/skills/deploy/SKILL.md\n")
        .stderr("");
}

#[test]
fn list_reads_bundled_skill_and_folded_description() {
    let project = project();
    project.write(".ai/agent_sync.yaml", "base_skills: true\n");
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: >-\n  Deploy the app\n  safely\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains("deploy\tDeploy the app safely\t"))
        .stdout(predicate::str::contains("agentsync\t"))
        .stdout(predicate::str::contains(
            "bundled:skills/agentsync/SKILL.md",
        ));
}

#[test]
fn check_reports_invalid_frontmatter_without_changing_sync() {
    let project = project();
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: wrong\ndescription: Deploy\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "check"])
        .assert()
        .failure()
        .stdout(predicate::str::contains(
            "name 'wrong' does not match directory 'deploy'",
        ));
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "deploy\t\t.ai/src/skills/deploy/SKILL.md",
        ));
    project.enable_tools(&["claude"]);
    project.agentsync().arg("sync").assert().success();
    assert!(project.exists(".claude/skills/deploy/SKILL.md"));
}

#[test]
fn list_uses_configured_source_path() {
    let project = project();
    project.write(
        ".ai/agent_sync.yaml",
        "base_skills: false\nsource:\n  skills: custom/skills\n",
    );
    project.write(
        "custom/skills/review/SKILL.md",
        "---\nname: review\ndescription: Review changes\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "review\tReview changes\tcustom/skills/review/SKILL.md",
        ));
}

#[test]
fn list_includes_shared_skills_and_respects_child_precedence() {
    let project = project();
    project.write(
        ".ai/agent_sync.yaml",
        "base_skills: false\nshared:\n  path: parent\n  inherit: skills\n",
    );
    project.write(
        "parent/.ai/src/skills/shared/SKILL.md",
        "---\nname: shared\ndescription: From parent\n---\n",
    );
    project.write(
        "parent/.ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: Old deployment\n---\n",
    );
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: Child deployment\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "deploy\tChild deployment\t.ai/src/skills/deploy/SKILL.md",
        ))
        .stdout(predicate::str::contains(
            "shared\tFrom parent\tparent/.ai/src/skills/shared/SKILL.md",
        ));
}

#[test]
fn profile_list_uses_profile_overlay() {
    let project = project();
    project.write(
        ".ai/agent_sync.yaml",
        "base_skills: false\nprofiles:\n  work:\n    tools: [claude-work]\n",
    );
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: Personal deployment\n---\n",
    );
    project.write(
        ".ai/profiles/work/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: Work deployment\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "list", "--profile", "work"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "deploy\tWork deployment\t.ai/profiles/work/src/skills/deploy/SKILL.md",
        ));
}

#[test]
fn unknown_profile_is_an_error() {
    project()
        .agentsync()
        .args(["skills", "list", "--profile", "missing"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Unknown profile: missing"));
}

#[test]
fn check_reports_missing_skill_file_at_project_path() {
    let project = project();
    project.write(".ai/src/skills/empty/reference.md", "# Reference\n");
    project
        .agentsync()
        .args(["skills", "check"])
        .assert()
        .failure()
        .stdout(predicate::str::contains(
            ".ai/src/skills/empty/SKILL.md: missing SKILL.md",
        ))
        .stdout(predicate::str::contains("Checked 1 skills: 1 issue(s)"));
}

#[test]
fn help_and_invalid_arguments_do_not_read_the_project() {
    Project::empty()
        .agentsync()
        .args(["skills", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("skills list [--profile <name>]"));
    Project::empty()
        .agentsync()
        .args(["skills", "install"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("expected skills list|check"));
}
