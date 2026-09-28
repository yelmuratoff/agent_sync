//! `tests/base_skills.bats`: engine-owned skills. Content documenting
//! AgentSync itself is resolved from the install dir at sync time, so
//! upgrading the engine updates it in every project. A project copy still
//! wins, and `base_skills: false` opts out.

mod common;

use common::Project;

fn synced_project() -> Project {
    Project::seeded(&["--tools", "claude", "--yes"])
}

fn set_config(project: &Project, line: &str) {
    project.append(".ai/agent_sync.yaml", &format!("{line}\n"));
}

#[test]
fn base_skills_the_agentsync_skill_reaches_outputs_without_living_in_ai_src() {
    let project = synced_project();
    assert!(!project.join(".ai/src/skills/agentsync").exists());
    assert!(project.exists(".claude/skills/agentsync/SKILL.md"));
    assert!(
        project
            .read(".claude/skills/agentsync/SKILL.md")
            .contains("AgentSync")
    );
}

#[test]
fn base_skills_init_no_longer_scaffolds_it_as_project_content() {
    let project = synced_project();
    project
        .agentsync()
        .args(["sync", "--force"])
        .assert()
        .success();
    assert!(!project.join(".ai/src/skills/agentsync").exists());
}

#[test]
fn base_skills_nested_reference_files_come_along() {
    let project = synced_project();
    assert!(project.exists(".claude/skills/agentsync/references/writing-skills.md"));
    assert!(project.exists(".claude/skills/agentsync/references/maintenance.md"));
}

#[test]
fn base_skills_it_is_a_tracked_output_like_any_other() {
    let project = synced_project();
    assert!(
        project
            .read(".ai/.sync-manifest")
            .lines()
            .any(|line| line.starts_with(".claude/skills/agentsync/SKILL.md\t"))
    );
}

#[test]
fn base_skills_the_projects_own_copy_wins() {
    let project = synced_project();
    project.write(
        ".ai/src/skills/agentsync/SKILL.md",
        "---\nname: agentsync\ndescription: Project version\n---\n\nPROJECT OVERRIDE\n",
    );
    project
        .agentsync()
        .args(["sync", "--force"])
        .assert()
        .success();
    assert!(
        project
            .read(".claude/skills/agentsync/SKILL.md")
            .contains("PROJECT OVERRIDE")
    );
}

#[test]
fn base_skills_the_projects_categorized_copy_wins_without_a_collision() {
    let project = synced_project();
    project.write(
        ".ai/src/skills/meta/agentsync/SKILL.md",
        "---\nname: agentsync\ndescription: Project version\n---\n\nPROJECT OVERRIDE\n",
    );
    project
        .agentsync()
        .args(["sync", "--force"])
        .assert()
        .success();
    assert!(
        project
            .read(".claude/skills/agentsync/SKILL.md")
            .contains("PROJECT OVERRIDE")
    );
    assert!(!project.exists(".claude/skills/agentsync/references"));
}

#[test]
fn base_skills_base_skills_false_leaves_it_out_entirely() {
    let project = synced_project();
    set_config(&project, "base_skills: false");
    project
        .agentsync()
        .args(["sync", "--force"])
        .assert()
        .success();
    assert!(!project.join(".claude/skills/agentsync").exists());
}

#[test]
fn base_skills_the_projects_other_skills_are_untouched() {
    let project = synced_project();
    assert!(project.exists(".ai/src/skills/commit"));
    assert!(project.exists(".claude/skills/commit/SKILL.md"));
}

#[test]
fn base_skills_shared_inheritance_preserves_child_and_parent_skills_together() {
    let project = synced_project();
    project.write(".ai/src/skills/child-only/SKILL.md", "child skill\n");
    project.write(
        "shared/.ai/src/skills/parent-only/SKILL.md",
        "parent skill\n",
    );
    set_config(&project, "shared:\n  path: shared\n  inherit: skills");

    project.agentsync().arg("sync").assert().success();
    assert_eq!(
        project.read(".claude/skills/child-only/SKILL.md"),
        "child skill\n"
    );
    assert_eq!(
        project.read(".claude/skills/parent-only/SKILL.md"),
        "parent skill\n"
    );
    assert!(project.exists(".claude/skills/agentsync/SKILL.md"));
}

#[test]
fn base_skills_a_second_sync_is_byte_identical_no_drift() {
    let project = synced_project();
    let before = project.sha256(".claude/skills/agentsync/SKILL.md");
    project.agentsync().arg("sync").assert().success();
    let after = project.sha256(".claude/skills/agentsync/SKILL.md");
    assert_eq!(before, after);
}

#[test]
fn base_skills_check_stays_green_with_the_layer_active() {
    let project = synced_project();
    project.agentsync().arg("check").assert().success();
}

#[test]
fn base_skills_removing_the_engine_skill_from_a_project_prunes_the_output() {
    let project = synced_project();
    assert!(project.exists(".claude/skills/agentsync/SKILL.md"));
    set_config(&project, "base_skills: false");
    project
        .agentsync()
        .args(["sync", "--force"])
        .assert()
        .success();
    assert!(!project.exists(".claude/skills/agentsync/SKILL.md"));
}

#[test]
fn base_skills_the_overlay_leaves_no_temp_directory_behind() {
    let project = synced_project();
    let sandbox = project.join("tmpdir_sandbox");
    std::fs::create_dir_all(&sandbox).unwrap();
    project
        .agentsync()
        .env("TMPDIR", &sandbox)
        .args(["sync", "--force"])
        .assert()
        .success();
    assert_eq!(std::fs::read_dir(&sandbox).unwrap().count(), 0);
}
