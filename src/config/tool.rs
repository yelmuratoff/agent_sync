//! Layered tool config: user override → shipped base → `base:` variant,
//! resolved per field exactly as `get_tool_value_r` in `lib/helpers/tool_resolver.sh`.

use include_dir::File;

use crate::{Error, config::catalog, config::yaml_subset, project::Project};

pub struct Tool {
    pub slug: String,
    user_yaml: Option<String>,
    base_yaml: Option<&'static str>,
}

impl Tool {
    pub fn load(project: &Project, slug: &str) -> Result<Self, Error> {
        let path = project.user_tool_file(slug);
        let user_yaml = if path.is_file() {
            Some(std::fs::read_to_string(&path).map_err(|e| Error::io(&path, e))?)
        } else {
            None
        };
        Ok(Self::from_parts(
            slug,
            user_yaml,
            catalog::base_tool_yaml(slug),
        ))
    }

    /// A tool whose override text was read by the caller, with its shipped base.
    pub fn new(slug: &str, user_yaml: Option<String>) -> Self {
        Self::from_parts(slug, user_yaml, catalog::base_tool_yaml(slug))
    }

    fn from_parts(slug: &str, user_yaml: Option<String>, base_yaml: Option<&'static str>) -> Self {
        Self {
            slug: slug.to_string(),
            user_yaml,
            base_yaml,
        }
    }

    /// `base:` from the user file: the slug a profile variant inherits from.
    pub fn base_name(&self) -> String {
        self.user_yaml
            .as_deref()
            .map(|text| yaml_subset::value(text, "base"))
            .unwrap_or_default()
    }

    /// Effective scalar for a dotted key. A non-empty user value wins; a shipped
    /// base answers next, even with an empty value; only a slug without a
    /// shipped file falls back to its `base:` tool, and never for `base` or `name`.
    pub fn value(&self, key_path: &str) -> String {
        if let Some(user) = &self.user_yaml {
            let found = yaml_subset::value(user, key_path);
            if !found.is_empty() {
                return found;
            }
        }
        if let Some(base) = self.base_yaml {
            return yaml_subset::value(base, key_path);
        }
        if key_path != "base" && key_path != "name" {
            let base_tool = self.base_name();
            if let Some(text) = catalog::base_tool_yaml(&base_tool) {
                return yaml_subset::value(text, key_path);
            }
        }
        String::new()
    }

    /// A scalar from `.ai/src/tools/<slug>.yaml` alone, as the legacy
    /// `enabled: true` lookup reads it.
    pub fn user_value(&self, key_path: &str) -> String {
        self.user_yaml
            .as_deref()
            .map(|text| yaml_subset::value(text, key_path))
            .unwrap_or_default()
    }

    /// `get_tool_bool`:`Some` for the true and false spellings, `None` otherwise.
    pub fn flag(&self, key_path: &str) -> Option<bool> {
        match self.value(key_path).to_ascii_lowercase().as_str() {
            "true" | "yes" | "1" | "on" => Some(true),
            "false" | "no" | "0" | "off" => Some(false),
            _ => None,
        }
    }

    /// `get_tool_filter`: an include/exclude list as one space-joined string,
    /// layered like `value` but per file, from a scalar, `[a, b]`, or a block list.
    pub fn filter(&self, key_path: &str) -> String {
        if let Some(user) = &self.user_yaml {
            let found = read_filter(user, key_path);
            if !found.is_empty() {
                return found;
            }
        }
        if let Some(base) = self.base_yaml {
            return read_filter(base, key_path);
        }
        match catalog::base_tool_yaml(&self.base_name()) {
            Some(text) => read_filter(text, key_path),
            None => String::new(),
        }
    }

    /// Whether sync owns only the declared keys of this tool's TOML settings:
    /// `targets.settings.ownership` `keys`, or `auto` in a config home, the
    /// project rooted at `$HOME` or a profile variant.
    pub fn settings_keyed(&self, root_is_home: bool) -> bool {
        if self.value("targets.mcp.format") != "codex_toml" {
            return false;
        }
        match self.value("targets.settings.ownership").as_str() {
            "keys" => true,
            "auto" => root_is_home || !self.value("profile_home").is_empty(),
            _ => false,
        }
    }

    pub fn display_name(&self) -> String {
        let name = self.value("name");
        if name.is_empty() {
            self.slug.clone()
        } else {
            name
        }
    }

    /// Shipped payload template for this tool, or for its `base:` tool.
    pub fn base_payload(&self, resource: &str) -> Option<&'static File<'static>> {
        catalog::base_payload(resource, &self.slug).or_else(|| {
            let base_tool = self.base_name();
            if base_tool.is_empty() {
                None
            } else {
                catalog::base_payload(resource, &base_tool)
            }
        })
    }
}

/// `_read_filter_file`.
fn read_filter(text: &str, key_path: &str) -> String {
    let scalar = yaml_subset::value(text, key_path);
    if !scalar.is_empty() && !(scalar.starts_with('[') && scalar.ends_with(']')) {
        return scalar;
    }
    yaml_subset::list(text, key_path).join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude_with(user: &str) -> Tool {
        Tool::from_parts(
            "claude",
            Some(user.to_string()),
            catalog::base_tool_yaml("claude"),
        )
    }

    #[test]
    fn a_non_empty_user_value_wins() {
        assert_eq!(claude_with("name: \"Mine\"\n").display_name(), "Mine");
    }

    #[test]
    fn an_empty_user_value_falls_back_to_the_base() {
        assert_eq!(claude_with("name:\n").display_name(), "Claude Code");
    }

    #[test]
    fn a_shipped_base_answers_even_when_empty_and_blocks_the_variant_fallback() {
        let tool = claude_with("base: cursor\n");
        assert_eq!(tool.value("targets.rules.extension"), "");
        assert_eq!(tool.value("targets.rules.dest"), ".claude/rules");
    }

    #[test]
    fn a_variant_inherits_from_its_base_tool_but_keeps_its_own_identity() {
        let tool = Tool::from_parts(
            "claude-hub",
            Some("base: claude\nprofile_home: \".claude-hub\"\n".to_string()),
            None,
        );
        assert_eq!(tool.base_name(), "claude");
        assert_eq!(tool.value("targets.rules.dest"), ".claude/rules");
        assert_eq!(tool.display_name(), "claude-hub");
        let payload = tool
            .base_payload("settings")
            .expect("inherits claude's settings");
        assert!(payload.path().ends_with("claude.json"));
    }

    #[test]
    fn flags_accept_the_bash_spellings_case_insensitively() {
        let tool =
            claude_with("targets:\n  rules:\n    enabled: OFF\n  skills:\n    enabled: maybe\n");
        assert_eq!(tool.flag("targets.rules.enabled"), Some(false));
        assert_eq!(tool.flag("targets.skills.enabled"), None);
    }

    #[test]
    fn filters_join_scalar_inline_and_block_forms() {
        let block = claude_with("targets:\n  skills:\n    exclude:\n      - a\n      - \"b*\"\n");
        assert_eq!(block.filter("targets.skills.exclude"), "a b*");
        let inline = claude_with("targets:\n  skills:\n    exclude: [a, b]\n");
        assert_eq!(inline.filter("targets.skills.exclude"), "a b");
        let scalar = claude_with("targets:\n  skills:\n    exclude: \"a b\"\n");
        assert_eq!(scalar.filter("targets.skills.exclude"), "a b");
        assert_eq!(claude_with("").filter("targets.rules.include"), "");
    }

    #[test]
    fn an_unknown_tool_reads_as_empty_and_shows_its_slug() {
        let tool = Tool::from_parts("nope", None, None);
        assert_eq!(tool.value("targets.rules.dest"), "");
        assert_eq!(tool.display_name(), "nope");
        assert!(tool.base_payload("mcp").is_none());
    }
}
