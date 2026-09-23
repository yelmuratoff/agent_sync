//! The deliberately small, read-only skill-card TSV format.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

pub const MAX_BYTES: usize = 128 * 1024;
pub const MAX_ROWS: usize = 256;
pub const HEADER: &str =
    "id\tsource\tcommit\tpath\toasf_version\toasf_terms\tmapping\tuse_when\tnot_for\trequirements";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Card {
    pub id: String,
    pub source: String,
    pub commit: String,
    pub path: String,
    pub oasf_version: String,
    pub oasf_terms: String,
    pub mapping: String,
    pub use_when: String,
    pub not_for: String,
    pub requirements: String,
}

/// Validate the entire bounded catalog before returning any card.
pub fn read(path: &Path) -> Result<Vec<Card>, String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|err| format!("Cannot inspect catalog {}: {err}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "Catalog must be a regular file, not a symlink: {}",
            path.display()
        ));
    }
    if metadata.len() > MAX_BYTES as u64 {
        return Err(format!("Catalog exceeds {MAX_BYTES} byte limit"));
    }

    let file =
        File::open(path).map_err(|err| format!("Cannot read catalog {}: {err}", path.display()))?;
    if !file
        .metadata()
        .map_err(|err| format!("Cannot inspect catalog {}: {err}", path.display()))?
        .is_file()
    {
        return Err(format!(
            "Catalog must be a regular file: {}",
            path.display()
        ));
    }
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|err| format!("Cannot read catalog {}: {err}", path.display()))?;
    if bytes.len() > MAX_BYTES {
        return Err(format!("Catalog exceeds {MAX_BYTES} byte limit"));
    }
    let text = String::from_utf8(bytes).map_err(|_| "Catalog must be valid UTF-8".to_string())?;
    parse(&text)
}

fn parse(text: &str) -> Result<Vec<Card>, String> {
    let lines: Vec<&str> = text.split('\n').collect();
    let header = lines.first().copied().unwrap_or_default();
    if header != HEADER {
        return Err(
            "Catalog header must exactly match the experimental skill-card TSV contract"
                .to_string(),
        );
    }

    let mut cards = Vec::new();
    let mut ids = BTreeSet::new();
    let end = lines.len() - usize::from(text.ends_with('\n'));
    for (offset, line) in lines[1..end].iter().enumerate() {
        let row = offset + 2;
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() != 10 {
            return Err(format!(
                "Catalog row {row} must contain exactly 10 TAB-separated fields"
            ));
        }
        if fields
            .iter()
            .any(|field| field.is_empty() || has_control(field))
        {
            return Err(format!(
                "Catalog row {row} has an empty or control-containing field"
            ));
        }
        if !slug(fields[0]) || !slug(fields[1]) {
            return Err(format!("Catalog row {row} has an unsafe id or source"));
        }
        if !commit(fields[2]) {
            return Err(format!("Catalog row {row} has an invalid pinned commit"));
        }
        if !safe_path(fields[3]) {
            return Err(format!("Catalog row {row} has an unsafe skill path"));
        }
        if !oasf_version(fields[4]) || !taxonomy_paths(fields[5]) {
            return Err(format!("Catalog row {row} has invalid OASF metadata"));
        }
        if !matches!(fields[6], "clear" | "broad" | "partial" | "unmapped") {
            return Err(format!("Catalog row {row} has an invalid mapping"));
        }
        if !ids.insert(fields[0]) {
            return Err(format!("Duplicate skill id: {}", fields[0]));
        }
        if cards.len() == MAX_ROWS {
            return Err(format!("Catalog exceeds {MAX_ROWS} row limit"));
        }
        cards.push(Card {
            id: fields[0].to_string(),
            source: fields[1].to_string(),
            commit: fields[2].to_string(),
            path: fields[3].to_string(),
            oasf_version: fields[4].to_string(),
            oasf_terms: fields[5].to_string(),
            mapping: fields[6].to_string(),
            use_when: fields[7].to_string(),
            not_for: fields[8].to_string(),
            requirements: fields[9].to_string(),
        });
    }
    if cards.is_empty() {
        return Err("Catalog contains no skill cards".to_string());
    }
    Ok(cards)
}

fn has_control(value: &str) -> bool {
    value.chars().any(|ch| {
        ch.is_control()
            || matches!(
                ch,
                '\u{061c}'
                    | '\u{200b}'..='\u{200f}'
                    | '\u{2028}'..='\u{202e}'
                    | '\u{2060}'..='\u{206f}'
                    | '\u{feff}'
            )
    })
}

fn slug(value: &str) -> bool {
    !value.is_empty()
        && value.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

fn commit(value: &str) -> bool {
    matches!(value.len(), 40 | 64) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn safe_path(value: &str) -> bool {
    value == "."
        || (!value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._/-".contains(&byte))
            && value
                .split('/')
                .all(|part| !matches!(part, "" | "." | "..")))
}

fn oasf_version(value: &str) -> bool {
    value == "-"
        || value.strip_prefix('v').is_some_and(|version| {
            version.split('.').count() == 3
                && version
                    .split('.')
                    .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        })
}

/// Taxonomy spelling does not establish OASF membership or meaning.
fn taxonomy_paths(value: &str) -> bool {
    value == "-"
        || value.split(',').all(|path| {
            let mut bytes = path.bytes();
            matches!(bytes.next(), Some(byte) if byte.is_ascii_alphanumeric())
                && bytes.all(|byte| byte.is_ascii_alphanumeric() || b"._/-".contains(&byte))
                && path.split('/').all(|part| !part.is_empty())
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROW: &str = "pdf\tclaude-agents\t1373e46b41ea7418804251066246ca170ef8f866\tclaude-root/skills/pdf\tv1.1.0\t-\tclear\tRead PDFs.\tRun OCR.\tPython.";

    #[test]
    fn parses_the_ten_field_contract() {
        let cards = parse(&format!("{HEADER}\n{ROW}\n")).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].id, "pdf");
    }

    #[test]
    fn validates_every_row_before_returning_any_card() {
        let text = format!("{HEADER}\n{ROW}\nnot-a-row\n");
        assert!(parse(&text).is_err());
    }

    #[test]
    fn paths_may_be_a_dot_or_contain_dots_but_not_traversal() {
        assert!(safe_path("."));
        assert!(safe_path("skills/v1.1/card"));
        assert!(!safe_path("../skill"));
        assert!(!safe_path("skills/./card"));
        assert!(!safe_path("C:/skill"));
    }

    #[test]
    fn oasf_metadata_and_mapping_have_narrow_syntax() {
        assert!(oasf_version("v1.1.0"));
        assert!(oasf_version("-"));
        assert!(!oasf_version("1.1.0"));
        assert!(taxonomy_paths("research/pdf,software/testing"));
        assert!(!taxonomy_paths("research/pdf,"));
    }

    #[test]
    fn rejects_display_formatting_controls_in_curator_text() {
        assert!(has_control("right-to-left\u{202e}override"));
    }

    #[test]
    fn malformed_fields_duplicates_and_row_limits_are_rejected() {
        let fields: Vec<_> = ROW.split('\t').collect();
        for (index, invalid) in [
            (0, ""),
            (0, "../pdf"),
            (1, "UPPER"),
            (2, "main"),
            (3, "../pdf"),
            (4, "latest"),
            (5, "research//pdf"),
            (6, "verified"),
            (7, "escape\u{1b}"),
            (9, "lines\u{2028}here"),
        ] {
            let mut row = fields.clone();
            row[index] = invalid;
            assert!(
                parse(&format!("{HEADER}\n{}\n", row.join("\t"))).is_err(),
                "field {index}"
            );
        }
        assert!(parse(&format!("{HEADER}\n{ROW}\n{ROW}\n")).is_err());
        assert!(parse(&format!("{HEADER}\n")).is_err());
        let mut catalog = format!("{HEADER}\n");
        for i in 0..MAX_ROWS {
            catalog.push_str(&ROW.replacen("pdf", &format!("skill-{i}"), 1));
            catalog.push('\n');
        }
        assert_eq!(parse(&catalog).unwrap().len(), MAX_ROWS);
        catalog.push_str(ROW);
        assert!(parse(&catalog).is_err());
    }

    #[test]
    fn file_boundary_refuses_non_utf8_and_oversized_catalogs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("catalog.tsv");
        std::fs::write(&path, [0xff]).unwrap();
        assert!(read(&path).unwrap_err().contains("UTF-8"));
        std::fs::write(&path, vec![b'a'; MAX_BYTES + 1]).unwrap();
        assert!(read(&path).unwrap_err().contains("byte limit"));
        assert!(read(dir.path()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn catalog_symlinks_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("catalog.tsv");
        std::fs::write(&path, format!("{HEADER}\n{ROW}\n")).unwrap();
        let link = dir.path().join("link.tsv");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read(&link).unwrap_err().contains("symlink"));
    }
}
