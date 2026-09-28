//! The plan shown before writing and the summary shown after.

use std::path::Path;

use super::scaffold::Scaffold;
use crate::config::catalog;
use crate::output::style::Style;
use crate::paths::DiskText;

/// `_init_print_plan`.
pub(super) fn plan(
    style: &Style,
    target: &str,
    tools: &[String],
    content: &[String],
    detect_source: &str,
    no_templates: bool,
) -> String {
    let mut text = format!(
        "{}\n  Target:   {}\n",
        style.bold("Plan:"),
        style.cyan(&format!("{target}/.ai/"))
    );
    if content.is_empty() {
        text.push_str(&format!("  Content:  {}\n", style.dim("(none)")));
    } else if no_templates {
        text.push_str(&format!(
            "  Content:  {} {}\n",
            content.join(", "),
            style.dim("(no starter templates)")
        ));
    } else {
        text.push_str(&format!("  Content:  {}\n", content.join(", ")));
    }
    if tools.is_empty() {
        text.push_str(&format!(
            "  Tools:    {}\n",
            style.dim("(none — opt in later via 'agentsync enable')")
        ));
    } else {
        text.push_str(&format!(
            "  Tools:    {} {}\n",
            tools.join(", "),
            style.dim(&format!("({detect_source})"))
        ));
        let mut any_payload = false;
        for resource in ["settings", "hooks"] {
            let names: Vec<String> = tools
                .iter()
                .flat_map(|slug| catalog::base_payloads(resource, slug))
                .filter_map(|file| Some(file.path().file_name()?.disk_text()))
                .collect();
            if !names.is_empty() {
                any_payload = true;
                text.push_str(&format!(
                    "  {:<9} {}\n",
                    format!("{resource}:"),
                    names.join(", ")
                ));
            }
        }
        if !any_payload {
            text.push_str(&format!(
                "  {}\n",
                style.dim("No payloads to scaffold — tools will use base templates at sync time.")
            ));
        }
    }
    text.push('\n');
    text
}

/// `*.md` files directly inside a directory.
fn count_md(dir: &Path) -> usize {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.file_name().disk_text().ends_with(".md")
                        && !e.file_name().disk_text().starts_with('.')
                        && e.path().is_file()
                })
                .count()
        })
        .unwrap_or(0)
}

/// Non-hidden subdirectories of a directory.
fn count_dirs(dir: &Path) -> usize {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| !e.file_name().disk_text().starts_with('.') && e.path().is_dir())
                .count()
        })
        .unwrap_or(0)
}

/// `_init_print_summary`.
pub(super) fn summary(style: &Style, scaffold: &Scaffold, payload_lines: &[String]) -> String {
    let Scaffold {
        ai_dir,
        tools,
        detect_source,
        no_templates,
        outputs,
        run_sync,
        ..
    } = *scaffold;
    let src = Path::new(ai_dir).join("src");
    let mut text = String::from("\n");
    if outputs == "committed" {
        text.push_str(&format!(
            "   Created {}     — project config (outputs: committed — teammates need only git pull)\n",
            style.cyan(".ai/agent_sync.yaml")
        ));
    } else {
        text.push_str(&format!(
            "   Created {}     — project config (outputs: local — every clone runs agentsync sync)\n",
            style.cyan(".ai/agent_sync.yaml")
        ));
    }
    let agents = src.join("AGENTS.md");
    if agents.is_file() {
        let empty = std::fs::metadata(&agents)
            .map(|m| m.len() == 0)
            .unwrap_or(false);
        if no_templates && empty {
            text.push_str(&format!(
                "   Created {}      — {}\n",
                style.cyan(".ai/src/AGENTS.md"),
                style.dim("(empty)")
            ));
        } else {
            text.push_str(&format!(
                "   Created {}      — agent identity\n",
                style.cyan(".ai/src/AGENTS.md")
            ));
        }
    }
    let sections: [(&str, &str, &str, bool); 4] = [
        ("rules", ".ai/src/rules/", "rule(s)", false),
        ("skills", ".ai/src/skills/", "skill(s)", true),
        ("commands", ".ai/src/commands/", "command(s)", false),
        ("agents", ".ai/src/agents/", "subagent(s)", false),
    ];
    for (dir, shown, noun, dirs) in sections {
        let path = src.join(dir);
        if !path.is_dir() {
            continue;
        }
        let count = if dirs {
            count_dirs(&path)
        } else {
            count_md(&path)
        };
        let padded = pad_created(style, shown);
        if count > 0 {
            text.push_str(&format!("{padded}— {count} {noun}\n"));
        } else if no_templates {
            text.push_str(&format!("{padded}— {}\n", style.dim("(empty)")));
        }
    }
    for line in payload_lines {
        text.push_str(&format!(
            "   Created {}\n",
            style.cyan(&format!(".ai/src/{line}"))
        ));
    }
    text.push('\n');
    if tools.is_empty() {
        text.push_str(&format!(
            "   {}\n",
            style.dim("No tools enabled. Run 'agentsync enable <slug>' to opt in.")
        ));
    } else {
        let joined = tools.join(", ");
        let count = tools.len();
        let line = match detect_source {
            "detect" => format!(
                "   {} {joined}\n",
                style.green(&format!("Auto-detected {count} tool(s):"))
            ),
            "flag" => format!(
                "   {} {joined} {}\n",
                style.green(&format!("Enabled {count} tool(s):")),
                style.dim("(from --tools)")
            ),
            "mixed" => format!(
                "   {} {joined} {}\n",
                style.green(&format!("Enabled {count} tool(s):")),
                style.dim("(auto-detect + --tools)")
            ),
            "interactive" => format!(
                "   {} {joined} {}\n",
                style.green(&format!("Enabled {count} tool(s):")),
                style.dim("(selected)")
            ),
            _ => format!(
                "   {} {joined}\n",
                style.green(&format!("Enabled {count} tool(s):"))
            ),
        };
        text.push_str(&line);
    }
    text.push_str(&format!("\n{}\n\nNext steps:\n", style.green("Done!")));
    let mut step = 1;
    if agents.is_file() {
        text.push_str(&format!(
            "  {step}. Edit {} — customize your agent's identity\n",
            style.cyan(".ai/src/AGENTS.md")
        ));
        step += 1;
    }
    text.push_str(&format!(
        "  {step}. Run {}    — print an AI prompt to tailor .ai/src/ to your codebase\n",
        style.cyan("agentsync generate")
    ));
    step += 1;
    text.push_str(&format!(
        "  {step}. Run {}        — browse all available tools\n",
        style.cyan("agentsync list")
    ));
    step += 1;
    if tools.is_empty() {
        text.push_str(&format!(
            "  {step}. Run {} — opt in to tools you use\n",
            style.cyan("agentsync enable <slug>")
        ));
    } else {
        text.push_str(&format!(
            "  {step}. Run {} — add more tools\n",
            style.cyan("agentsync enable <slug>")
        ));
    }
    step += 1;
    if run_sync && !tools.is_empty() {
        text.push_str(&format!(
            "  {step}. Re-run {}     — after every change to .ai/src/\n",
            style.cyan("agentsync sync")
        ));
    } else {
        text.push_str(&format!(
            "  {step}. Run {}        — distribute to enabled tools\n",
            style.cyan("agentsync sync")
        ));
    }
    text.push_str(&format!(
        "\nCustomize:\n  {} {}            — configure shared MCP servers\n  {} {} — override settings/hooks per tool\n\n",
        style.dim("•"),
        style.cyan("agentsync add mcp <server>"),
        style.dim("•"),
        style.cyan("agentsync customize <tool> <resource>")
    ));
    text
}

/// `   Created $(_cyan "<shown>")` padded as Bash's literal spacing pads each
/// section line: the styled name plus the spaces that bring the plain text to
/// the column the `—` starts in.
fn pad_created(style: &Style, shown: &str) -> String {
    let spaces = match shown {
        ".ai/src/rules/" => 10,
        ".ai/src/skills/" => 9,
        ".ai/src/commands/" => 7,
        _ => 9,
    };
    format!("   Created {}{}", style.cyan(shown), " ".repeat(spaces))
}

#[cfg(all(test, unix))]
mod tests {
    use super::super::tests::{backup_line, backups, call, project, quiet, tree};
    use crate::config::template_manifest::REL;
    use std::path::Path;

    #[test]
    fn payloads_config_and_summary_follow_the_selected_tools() {
        let (_dir, root) = project(&[]);
        let run = call(
            &root,
            &[
                "--tools",
                "claude,cursor",
                "--content",
                "agents,rules",
                "--no-sync",
            ],
            quiet(),
        );
        assert_eq!(
            run.out,
            format!(
                "Plan:\n  Target:   {root}/.ai/\n  Content:  agents, rules\n  Tools:    claude, cursor (flag)\n  settings: claude.json\n  hooks:    cursor.json\n\nInitializing AgentSync in {root}\n\n\n   Created .ai/agent_sync.yaml     — project config (outputs: committed — teammates need only git pull)\n   Created .ai/src/AGENTS.md      — agent identity\n   Created .ai/src/rules/          — 3 rule(s)\n   Created .ai/src/tools/claude/settings.json\n   Created .ai/src/tools/cursor/hooks.json\n\n   Enabled 2 tool(s): claude, cursor (from --tools)\n\nDone!\n\nNext steps:\n  1. Edit .ai/src/AGENTS.md — customize your agent's identity\n  2. Run agentsync generate    — print an AI prompt to tailor .ai/src/ to your codebase\n  3. Run agentsync list        — browse all available tools\n  4. Run agentsync enable <slug> — add more tools\n  5. Run agentsync sync        — distribute to enabled tools\n\nCustomize:\n  • agentsync add mcp <server>            — configure shared MCP servers\n  • agentsync customize <tool> <resource> — override settings/hooks per tool\n\n{}",
                backup_line(&root)
            )
        );
        assert_eq!(
            tree(&root),
            [
                ".ai/.template-manifest",
                ".ai/agent_sync.yaml",
                ".ai/src/AGENTS.md",
                ".ai/src/rules/comments.md",
                ".ai/src/rules/core.md",
                ".ai/src/rules/git.md",
                ".ai/src/tools/claude/settings.json",
                ".ai/src/tools/cursor/hooks.json"
            ]
        );
        let config = std::fs::read_to_string(Path::new(&root).join(".ai/agent_sync.yaml")).unwrap();
        assert!(config.contains("\ntools:\n  enabled:\n    - claude\n    - cursor\n\n"));
        let snapshot = backups(&root).pop().unwrap();
        let targets = std::fs::read_to_string(snapshot.join("targets.tsv")).unwrap();
        assert!(targets.starts_with("missing\t.ai/src\nmissing\t.ai/agent_sync.yaml\nmissing\t.ai/.template-manifest\nmissing\tCLAUDE.md\n"));
        assert!(targets.contains("missing\t.cursor/hooks.json\n"));

        let (_dir, root) = project(&[]);
        let empty = call(
            &root,
            &[
                "--no-templates",
                "--no-detect",
                "--content",
                "rules,agents",
                "--outputs=local",
                "--no-sync",
            ],
            quiet(),
        );
        assert!(empty.out.contains("\n   Created .ai/agent_sync.yaml     — project config (outputs: local — every clone runs agentsync sync)\n   Created .ai/src/AGENTS.md      — (empty)\n   Created .ai/src/rules/          — (empty)\n\n   No tools enabled."));
        assert_eq!(
            std::fs::metadata(Path::new(&root).join(".ai/src/AGENTS.md"))
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            std::fs::read_dir(Path::new(&root).join(".ai/src/rules"))
                .unwrap()
                .count(),
            0
        );
        assert!(!Path::new(&root).join(REL).exists());
        let (_dir, root) = project(&[]);
        let rules_only = call(
            &root,
            &[
                "--no-templates",
                "--no-detect",
                "--content",
                "rules",
                "--no-sync",
            ],
            quiet(),
        );
        assert!(
            rules_only
                .out
                .contains("  Content:  rules (no starter templates)\n")
        );
        assert!(rules_only.out.contains("\n   Created .ai/agent_sync.yaml     — project config (outputs: committed — teammates need only git pull)\n   Created .ai/src/rules/          — (empty)\n\n   No tools enabled."));
        assert!(
            rules_only
                .out
                .contains("Next steps:\n  1. Run agentsync generate")
        );
        assert!(!Path::new(&root).join(".ai/src/AGENTS.md").exists());
    }
}
