//! Include/exclude filters, mirroring `matches_filter` in `lib/helpers/filters.sh`.

/// Whether `filename` passes the space-separated glob lists: any exclude match
/// rejects, an empty include accepts everything, otherwise any include match accepts.
pub fn matches(filename: &str, include: &str, exclude: &str) -> bool {
    if split_patterns(exclude).any(|pat| glob_match(pat, filename)) {
        return false;
    }
    if include.is_empty() {
        return true;
    }
    split_patterns(include).any(|pat| glob_match(pat, filename))
}

/// `matches` for a skill: a pattern names either the skill or its path below
/// the skills root, so `cloudflare/*` filters a whole category.
pub fn matches_skill(name: &str, rel: &str, include: &str, exclude: &str) -> bool {
    let hit = |pat: &str| glob_match(pat, name) || glob_match(pat, rel);
    if split_patterns(exclude).any(hit) {
        return false;
    }
    include.is_empty() || split_patterns(include).any(hit)
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
        assert!(matches("core.md", "", ""));
    }

    #[test]
    fn exclude_wins_over_include() {
        assert!(!matches("core.md", "*.md", "core.*"));
        assert!(matches("git.md", "*.md", "core.*"));
    }

    #[test]
    fn any_of_several_space_separated_patterns_matches() {
        assert!(matches("b.md", "a.md b.md", ""));
        assert!(!matches("c.md", "a.md\tb.md", ""));
        assert!(!matches("command-review", "", "legacy command-*"));
    }

    #[test]
    fn a_skill_pattern_names_the_skill_or_its_category_path() {
        assert!(!matches_skill(
            "wrangler",
            "cloudflare/wrangler",
            "",
            "cloudflare/*"
        ));
        assert!(!matches_skill(
            "wrangler",
            "cloudflare/wrangler",
            "",
            "wrangler"
        ));
        assert!(matches_skill("bloc", "flutter/bloc", "", "cloudflare/*"));
        assert!(matches_skill(
            "slivers",
            "flutter/ui/slivers",
            "flutter/*",
            ""
        ));
        assert!(!matches_skill("auth", "backend/auth", "flutter/*", ""));
        assert!(matches_skill("commit", "commit", "flutter/* commit", ""));
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
