//! Colour helpers matching `lib/helpers/cli_colors.sh`: decided once from
//! stdout being a terminal and `NO_COLOR` being unset or empty.

use std::io::IsTerminal;

#[derive(Clone, Copy, Debug)]
pub struct Style {
    enabled: bool,
}

impl Style {
    pub fn for_stdout() -> Self {
        let no_color = std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty());
        Self {
            enabled: std::io::stdout().is_terminal() && !no_color,
        }
    }

    pub const fn plain() -> Self {
        Self { enabled: false }
    }

    /// A style decided elsewhere, as the sync log decides `colors` for stderr.
    pub const fn new(enabled: bool) -> Self {
        Self { enabled }
    }

    #[cfg(test)]
    pub(crate) const fn colored() -> Self {
        Self { enabled: true }
    }

    pub fn bold(&self, s: &str) -> String {
        self.wrap("1", s)
    }

    pub fn green(&self, s: &str) -> String {
        self.wrap("32", s)
    }

    pub fn cyan(&self, s: &str) -> String {
        self.wrap("36", s)
    }

    pub fn yellow(&self, s: &str) -> String {
        self.wrap("33", s)
    }

    pub fn red(&self, s: &str) -> String {
        self.wrap("31", s)
    }

    pub fn dim(&self, s: &str) -> String {
        self.wrap("2", s)
    }

    fn wrap(&self, code: &str, s: &str) -> String {
        if self.enabled {
            format!("\x1b[{code}m{s}\x1b[0m")
        } else {
            s.to_string()
        }
    }
}

/// Left-align `s` in `width` cells, counting only what the terminal shows: the
/// `ESC [ … m` sequences a style adds take no cell.
pub fn pad_right(s: &str, width: usize) -> String {
    let len = visible_width(s);
    if len >= width {
        s.to_string()
    } else {
        format!("{s}{}", " ".repeat(width - len))
    }
}

fn visible_width(s: &str) -> usize {
    let mut width = 0;
    let mut chars = s.chars();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            chars.by_ref().find(|c| *c == 'm');
        } else {
            width += 1;
        }
    }
    width
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_style_returns_the_text_unchanged() {
        assert_eq!(Style::plain().red("x"), "x");
    }

    #[test]
    fn enabled_style_wraps_with_the_bash_escape_codes() {
        let style = Style { enabled: true };
        assert_eq!(style.bold("x"), "\x1b[1mx\x1b[0m");
        assert_eq!(style.dim("x"), "\x1b[2mx\x1b[0m");
        assert_eq!(style.green("x"), "\x1b[32mx\x1b[0m");
    }

    #[test]
    fn padding_counts_the_cells_a_terminal_shows() {
        assert_eq!(pad_right("ab", 4), "ab  ");
        assert_eq!(pad_right("abcdef", 4), "abcdef");
        assert_eq!(pad_right("●b", 4), "●b  ");
        let styled = Style { enabled: true }.dim("ab");
        assert_eq!(pad_right(&styled, 12), format!("{styled}          "));
    }
}
