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
fn list_neutralizes_invisible_formatting_in_skill_metadata() {
    let project = project();
    project.write(
        ".ai/src/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: safe\u{202e}spoof\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "list"])
        .assert()
        .success()
        .stdout("name\tdescription\tpath\ndeploy\tsafe spoof\t.ai/src/skills/deploy/SKILL.md\n");
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
    project
        .agentsync()
        .args(["skills", "show", "deploy", "--profile", "work"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Description: Work deployment\n"))
        .stdout(predicate::str::contains(
            "Path: .ai/profiles/work/src/skills/deploy/SKILL.md\n",
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
fn show_displays_declared_fields_and_unverified_annotations() {
    let project = project();
    project.write(
        ".ai/src/skills/review/SKILL.md",
        "---\nname: review\ndescription: Review a selected diff\nlicense: MIT\ncompatibility: Requires git\nmetadata:\n  agentsync-use-when: Before merging\n  agentsync-not-for: Writing the change\n  agentsync-requirements: A selected diff\n---\n# Review\n",
    );
    project
        .agentsync()
        .args(["skills", "show", "review"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Description: Review a selected diff\n",
        ))
        .stdout(predicate::str::contains(
            "Compatibility (declared): Requires git\n",
        ))
        .stdout(predicate::str::contains("License: MIT\n"))
        .stdout(predicate::str::contains(
            "Use when (annotation, unverified): Before merging\n",
        ))
        .stdout(predicate::str::contains(
            "Not for (annotation, unverified): Writing the change\n",
        ))
        .stdout(predicate::str::contains(
            "Requirements (annotation, unverified): A selected diff\n",
        ))
        .stdout(predicate::str::contains(
            "Path: .ai/src/skills/review/SKILL.md\n",
        ))
        .stderr("");
}

#[test]
fn list_filters_names_without_affecting_check() {
    let project = project();
    for name in ["review", "release", "deploy"] {
        project.write(
            &format!(".ai/src/skills/{name}/SKILL.md"),
            &format!("---\nname: {name}\ndescription: Use {name}\n---\n"),
        );
    }
    project
        .agentsync()
        .args(["skills", "list", "--include", "re*", "--exclude", "release"])
        .assert()
        .success()
        .stdout(predicate::str::contains("review\tUse review\t"))
        .stdout(predicate::str::contains("release\t").not())
        .stdout(predicate::str::contains("deploy\t").not());
    project
        .agentsync()
        .args(["skills", "check"])
        .assert()
        .success()
        .stdout("Checked 3 skills: 0 issue(s)\n");
    project
        .agentsync()
        .args([
            "skills",
            "list",
            "--include",
            "review",
            "--include",
            "deploy",
            "--exclude",
            "release",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("review\tUse review\t"))
        .stdout(predicate::str::contains("deploy\tUse deploy\t"))
        .stdout(predicate::str::contains("release\t").not());
}

#[test]
fn profile_reports_the_source_used_by_its_overlay() {
    let project = project();
    project.write(
        ".ai/agent_sync.yaml",
        "base_skills: false\nsource:\n  skills: custom/skills\nprofiles:\n  work:\n    tools: [claude-work]\n",
    );
    project.write(
        "custom/skills/review/SKILL.md",
        "---\nname: review\ndescription: Custom source\n---\n",
    );
    project.write(
        ".ai/src/skills/review/SKILL.md",
        "---\nname: review\ndescription: Profile base source\n---\n",
    );
    project.write(
        ".ai/profiles/work/src/skills/other/SKILL.md",
        "---\nname: other\ndescription: Profile skill\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "show", "review", "--profile", "work"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Description: Profile base source\n",
        ))
        .stdout(predicate::str::contains(
            "Path: .ai/src/skills/review/SKILL.md\n",
        ));
}

#[test]
fn show_reports_unknown_and_invalid_skills() {
    let project = project();
    project
        .agentsync()
        .args(["skills", "show", "absent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("unknown skill: absent"));
    project.write(
        ".ai/src/skills/review/SKILL.md",
        "---\nname: review\ndescription:\n---\n",
    );
    project
        .agentsync()
        .args(["skills", "show", "review"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "description must be 1–1024 characters",
        ));
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
        .stderr(predicate::str::contains("expected skills list|show|check"));
}
