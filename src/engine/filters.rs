//! Include/exclude filters, mirroring `matches_filter` in `lib/helpers/filters.sh`.

use crate::engine::skill_tree::Skill;

/// A target's include and exclude globs, each a space-separated list: any
/// exclude match rejects, an empty include accepts everything, otherwise any
/// include match accepts.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Filter {
    pub include: String,
    pub exclude: String,
}

impl Filter {
    pub fn new(include: &str, exclude: &str) -> Self {
        Self {
            include: include.to_string(),
            exclude: exclude.to_string(),
        }
    }

    /// This filter with `patterns` excluded as well.
    pub fn excluding(&self, patterns: &str) -> Self {
        let mut filter = self.clone();
        filter.exclude_also(patterns);
        filter
    }

    pub fn include_also(&mut self, patterns: &str) {
        append(&mut self.include, patterns);
    }

    pub fn exclude_also(&mut self, patterns: &str) {
        append(&mut self.exclude, patterns);
    }

    pub fn accepts(&self, name: &str) -> bool {
        self.passes(|pat| glob_match(pat, name))
    }

    /// A pattern names either the skill or its path below the skills root, so
    /// `cloudflare/*` filters a whole category.
    pub fn accepts_skill(&self, skill: &Skill) -> bool {
        self.passes(|pat| glob_match(pat, &skill.name) || glob_match(pat, &skill.rel))
    }

    fn passes(&self, hit: impl Fn(&str) -> bool) -> bool {
        if split_patterns(&self.exclude).any(&hit) {
            return false;
        }
        self.include.is_empty() || split_patterns(&self.include).any(&hit)
    }
}

fn append(list: &mut String, patterns: &str) {
    if !list.is_empty() {
        list.push(' ');
    }
    list.push_str(patterns);
}

fn split_patterns(list: &str) -> impl Iterator<Item = &str> {
    list.split([' ', '\t', '\n']).filter(|pat| !pat.is_empty())
}

/// Bash `[[ $name == $pat ]]` matching: `*`, `?`, bracket expressions with `!`
/// or `^` negation and ranges, and backslash escapes. No pathname rules apply,
/// so `*` matches `/` and a leading dot.
pub fn glob_match(pattern: &str, name: &str) -> bool {
    let pat: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = name.chars().collect();
    match_from(&pat, &text)
}

fn match_from(pat: &[char], text: &[char]) -> bool {
    let Some((&first, rest)) = pat.split_first() else {
        return text.is_empty();
    };
    match first {
        '*' => (0..=text.len()).any(|skip| match_from(rest, &text[skip..])),
        '?' => !text.is_empty() && match_from(rest, &text[1..]),
        '[' => match bracket(rest) {
            Some((set, after)) => {
                !text.is_empty() && set.contains(text[0]) && match_from(after, &text[1..])
            }
            None => text.first() == Some(&'[') && match_from(rest, &text[1..]),
        },
        '\\' if !rest.is_empty() => {
            text.first() == Some(&rest[0]) && match_from(&rest[1..], &text[1..])
        }
        literal => text.first() == Some(&literal) && match_from(rest, &text[1..]),
    }
}

struct Bracket {
    negated: bool,
    items: Vec<(char, char)>,
}

impl Bracket {
    fn contains(&self, c: char) -> bool {
        let hit = self.items.iter().any(|&(lo, hi)| lo <= c && c <= hi);
        hit != self.negated
    }
}

/// Parses the body after `[`; `None` when there is no closing `]`, in which
/// case the `[` is literal.
fn bracket(body: &[char]) -> Option<(Bracket, &[char])> {
    let mut i = 0;
    let negated = matches!(body.first(), Some('!' | '^'));
    if negated {
        i += 1;
    }
    let mut items = Vec::new();
    let start = i;
    while i < body.len() {
        let c = body[i];
        if c == ']' && i > start {
            return Some((Bracket { negated, items }, &body[i + 1..]));
        }
        let lo = if c == '\\' && i + 1 < body.len() {
            i += 1;
            body[i]
        } else {
            c
        };
        if i + 2 < body.len() && body[i + 1] == '-' && body[i + 2] != ']' {
            items.push((lo, body[i + 2]));
            i += 3;
        } else {
            items.push((lo, lo));
            i += 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_filter_accepts_everything() {
        assert!(Filter::default().accepts("core.md"));
    }

    #[test]
    fn exclude_wins_over_include() {
        let filter = Filter::new("*.md", "core.*");
        assert!(!filter.accepts("core.md"));
        assert!(filter.accepts("git.md"));
    }

    #[test]
    fn any_of_several_space_separated_patterns_matches() {
        assert!(Filter::new("a.md b.md", "").accepts("b.md"));
        assert!(!Filter::new("a.md\tb.md", "").accepts("c.md"));
        assert!(!Filter::new("", "legacy command-*").accepts("command-review"));
    }

    #[test]
    fn excluding_adds_patterns_to_either_list_shape() {
        assert_eq!(
            Filter::new("a*", "").excluding("command-*"),
            Filter::new("a*", "command-*")
        );
        assert_eq!(
            Filter::new("", "b").excluding("command-*"),
            Filter::new("", "b command-*")
        );
    }

    #[test]
    fn a_skill_pattern_names_the_skill_or_its_category_path() {
        let wrangler = Skill::at("cloudflare/wrangler");
        assert!(!Filter::new("", "cloudflare/*").accepts_skill(&wrangler));
        assert!(!Filter::new("", "wrangler").accepts_skill(&wrangler));
        assert!(Filter::new("", "cloudflare/*").accepts_skill(&Skill::at("flutter/bloc")));
        assert!(Filter::new("flutter/*", "").accepts_skill(&Skill::at("flutter/ui/slivers")));
        assert!(!Filter::new("flutter/*", "").accepts_skill(&Skill::at("backend/auth")));
        assert!(Filter::new("flutter/* commit", "").accepts_skill(&Skill::at("commit")));
    }

    #[test]
    fn globs_follow_bash_pattern_rules() {
        assert!(glob_match("*", ".hidden"));
        assert!(glob_match("a?c", "abc"));
        assert!(glob_match("[a-c]x", "bx"));
        assert!(!glob_match("[!a-c]x", "bx"));
        assert!(glob_match("[x", "[x"));
        assert!(glob_match("\\*", "*"));
        assert!(!glob_match("\\*", "a"));
        assert!(glob_match("*.md", "dir/a.md"));
    }
}
