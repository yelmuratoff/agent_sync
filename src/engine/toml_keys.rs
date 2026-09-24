//! The TOML side of `keyed`: parses and edits through `toml_edit`, so comments,
//! quoting, and layout the other program chose survive every merge.

use std::collections::BTreeMap;

use toml_edit::{DocumentMut, Item, Table, TableLike, Value};

use crate::engine::keyed::{self, KeyPath, Merged, Owned, UNIT_ROOTS};

pub fn merge(live: &str, desired: &str, previous: Option<&Owned>) -> Result<Merged, String> {
    let declared = declared(desired)?;
    let mut doc = parse(live, LIVE)?;
    let drifted = match previous {
        Some(previous) => previous.changed(&owned_now(&doc, previous.keys())),
        None => declared
            .iter()
            .filter(|(path, item)| {
                lookup(doc.as_table(), path).is_some_and(|live| canonical(live) != canonical(item))
            })
            .map(|(path, _)| path.clone())
            .collect(),
    };
    let mut changed = false;
    for path in previous.into_iter().flat_map(Owned::keys) {
        if !declared
            .iter()
            .any(|(declared, _)| path.starts_with(declared))
            && remove(doc.as_table_mut(), path)
        {
            changed = true;
        }
    }
    for (path, item) in &declared {
        let current = lookup(doc.as_table(), path);
        if current.is_some_and(|live| canonical(live) == canonical(item)) {
            continue;
        }
        set(doc.as_table_mut(), path, item.clone());
        changed = true;
    }
    let text = if !changed {
        live.to_string()
    } else if live.starts_with('\n') {
        doc.to_string()
    } else {
        doc.to_string().trim_start_matches('\n').to_string()
    };
    Ok(Merged {
        text,
        owned: Owned::from_pairs(
            declared
                .iter()
                .map(|(path, item)| (path.clone(), hash_item(Some(item)))),
        ),
        drifted,
    })
}

pub fn owned_in(live: &str, record: &Owned) -> Result<Owned, String> {
    Ok(owned_now(&parse(live, LIVE)?, record.keys()))
}

pub fn adopt(live: &str, source: &str, keys: &[KeyPath]) -> Result<String, String> {
    let live = parse(live, LIVE)?;
    let mut doc = parse(source, SOURCE)?;
    for key in keys {
        match lookup(live.as_table(), key) {
            Some(item) => set(doc.as_table_mut(), key, item.clone()),
            None => {
                remove(doc.as_table_mut(), key);
            }
        }
    }
    Ok(doc.to_string())
}

/// Every leaf of `desired` is one owned key; an inline table, an array, an
/// array of tables, and each entry of a server map count as one value.
fn declared(desired: &str) -> Result<Vec<(KeyPath, Item)>, String> {
    let doc = parse(desired, SOURCE)?;
    let mut out = Vec::new();
    collect_leaves(doc.as_table(), &mut Vec::new(), &mut out);
    Ok(out)
}

const LIVE: &str = "the live file";
const SOURCE: &str = "the source";

/// toml_edit's report is a location line, a source excerpt, then the message;
/// one log line keeps the location and the message.
fn parse(text: &str, which: &str) -> Result<DocumentMut, String> {
    text.parse::<DocumentMut>().map_err(|e| {
        let report = e.to_string();
        let mut lines = report.lines().filter(|line| !line.trim().is_empty());
        let location = lines
            .next()
            .unwrap_or_default()
            .trim_start_matches("TOML parse error at ");
        match lines.next_back() {
            Some(message) => format!("in {which}, {location}: {}", message.trim()),
            None => format!("in {which}, {location}"),
        }
    })
}

fn owned_now<'a>(doc: &DocumentMut, keys: impl Iterator<Item = &'a KeyPath>) -> Owned {
    Owned::from_pairs(keys.map(|path| (path.clone(), hash_item(lookup(doc.as_table(), path)))))
}

fn collect_leaves(table: &dyn TableLike, path: &mut KeyPath, out: &mut Vec<(KeyPath, Item)>) {
    for (key, item) in table.iter() {
        path.push(key.to_string());
        let unit_root = path.len() == 1 && UNIT_ROOTS.contains(&key);
        match item {
            Item::None => {}
            _ if unit_root && item.is_table_like() => {
                for (entry, value) in item.as_table_like().into_iter().flat_map(|t| t.iter()) {
                    out.push((vec![key.to_string(), entry.to_string()], value.clone()));
                }
            }
            Item::Table(table) => collect_leaves(table, path, out),
            _ => out.push((path.clone(), item.clone())),
        }
        path.pop();
    }
}

fn clear_positions(item: &mut Item) {
    if let Item::Table(table) = item {
        table.set_position(None);
        for (_, child) in table.iter_mut() {
            clear_positions(child);
        }
    }
}

fn lookup<'a>(root: &'a Table, path: &[String]) -> Option<&'a Item> {
    let (last, parents) = path.split_last()?;
    let mut table: &dyn TableLike = root;
    for key in parents {
        table = table.get(key)?.as_table_like()?;
    }
    table.get(last).filter(|item| !item.is_none())
}

fn set(root: &mut Table, path: &[String], item: Item) {
    let Some((last, parents)) = path.split_last() else {
        return;
    };
    let spaced = !root.is_empty();
    let mut table: &mut dyn TableLike = root;
    for key in parents {
        if !table.get(key).is_some_and(Item::is_table_like) {
            let mut fresh = Table::new();
            fresh.set_implicit(true);
            if spaced {
                fresh.decor_mut().set_prefix("\n");
            }
            table.insert(key, Item::Table(fresh));
        }
        let Some(next) = table.get_mut(key).and_then(Item::as_table_like_mut) else {
            return;
        };
        table = next;
    }
    let replacement = match (table.get_mut(last), item) {
        (Some(Item::Value(old)), Item::Value(mut new)) => {
            *new.decor_mut() = old.decor().clone();
            *old = new;
            return;
        }
        (None, Item::Table(new)) => {
            let mut new = Item::Table(new);
            clear_positions(&mut new);
            if let Some(table) = new.as_table_mut() {
                table.decor_mut().set_prefix(if spaced { "\n" } else { "" });
            }
            new
        }
        (_, item) => item,
    };
    table.insert(last, replacement);
}

/// Removes `path` and any table it leaves empty; `true` when something went.
fn remove(root: &mut Table, path: &[String]) -> bool {
    let Some((last, parents)) = path.split_last() else {
        return false;
    };
    let removed = {
        let mut table: &mut dyn TableLike = root;
        for key in parents {
            let Some(next) = table.get_mut(key).and_then(Item::as_table_like_mut) else {
                return false;
            };
            table = next;
        }
        table.remove(last).is_some()
    };
    if removed {
        for depth in (1..=parents.len()).rev() {
            let prefix = &parents[..depth];
            if lookup(root, prefix)
                .and_then(Item::as_table_like)
                .is_some_and(|table| table.is_empty())
            {
                remove(root, prefix);
            } else {
                break;
            }
        }
    }
    removed
}

fn hash_item(item: Option<&Item>) -> String {
    match item {
        Some(item) => keyed::short_hash(&canonical(item)),
        None => String::new(),
    }
}

/// A value's meaning without its formatting: quoting style, whitespace,
/// comments, inline versus standard tables, and key order all drop out.
fn canonical(item: &Item) -> String {
    match item {
        Item::None => String::new(),
        Item::Value(value) => canonical_value(value),
        Item::Table(table) => canonical_pairs(table.iter().map(|(k, i)| (k, canonical(i)))),
        Item::ArrayOfTables(tables) => format!(
            "[{}]",
            tables
                .iter()
                .map(|t| canonical_pairs(t.iter().map(|(k, i)| (k, canonical(i)))))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

fn canonical_value(value: &Value) -> String {
    match value {
        Value::String(s) => serde_json::to_string(s.value()).unwrap_or_default(),
        Value::Integer(i) => i.value().to_string(),
        Value::Float(f) => format!("{:?}", f.value()),
        Value::Boolean(b) => b.value().to_string(),
        Value::Datetime(d) => format!("t{}", d.value()),
        Value::Array(array) => format!(
            "[{}]",
            array
                .iter()
                .map(canonical_value)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::InlineTable(table) => {
            canonical_pairs(table.iter().map(|(k, v)| (k, canonical_value(v))))
        }
    }
}

fn canonical_pairs<'a>(pairs: impl Iterator<Item = (&'a str, String)>) -> String {
    let sorted: BTreeMap<&str, String> = pairs.collect();
    let body = sorted
        .iter()
        .map(|(k, v)| format!("{}:{v}", serde_json::to_string(k).unwrap_or_default()))
        .collect::<Vec<_>>()
        .join(",");
    format!("{{{body}}}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(path: &str) -> KeyPath {
        path.split('.').map(str::to_string).collect()
    }

    #[test]
    fn keeps_keys_it_does_not_own() {
        let live = "model = \"old\"\n\n[projects.\"/tmp/x\"]\ntrust_level = \"trusted\" # app\n";
        let merged = merge(live, "model = \"new\"\n", None).unwrap();
        assert_eq!(
            merged.text,
            "model = \"new\"\n\n[projects.\"/tmp/x\"]\ntrust_level = \"trusted\" # app\n"
        );
    }

    #[test]
    fn a_rewritten_key_keeps_its_comments() {
        let live = "# chosen in the app\nmodel = \"old\" # note\n";
        let merged = merge(live, "model = \"new\"\n", None).unwrap();
        assert_eq!(merged.text, "# chosen in the app\nmodel = \"new\" # note\n");
    }

    #[test]
    fn sets_declared_keys_inside_existing_tables() {
        let merged = merge("[tui]\nnux = 1\n", "[tui]\ntheme = \"dark\"\n", None).unwrap();
        assert_eq!(merged.text, "[tui]\nnux = 1\ntheme = \"dark\"\n");
    }

    #[test]
    fn leaves_bytes_unchanged_when_values_match() {
        let live = "model  =  'gpt'   # mine\n[tui]\ntheme = \"dark\"\nnux = 1\n";
        let merged = merge(live, "model = \"gpt\"\n[tui]\ntheme = 'dark'\n", None).unwrap();
        assert_eq!(merged.text, live);
        assert!(merged.drifted.is_empty());
    }

    #[test]
    fn removes_keys_it_owned_before_and_no_longer_declares() {
        let first = merge("", "model = \"a\"\n[tui]\ntheme = \"x\"\n", None).unwrap();
        let live = format!("{}\n[projects.p]\ntrust_level = \"trusted\"\n", first.text);
        let second = merge(&live, "model = \"a\"\n", Some(&first.owned)).unwrap();
        assert_eq!(
            second.text,
            "model = \"a\"\n\n[projects.p]\ntrust_level = \"trusted\"\n"
        );
        assert_eq!(second.owned.keys().collect::<Vec<_>>(), [&key("model")]);
    }

    #[test]
    fn removes_nothing_without_a_previous_record() {
        let live = "model = \"a\"\nsandbox = \"x\"\n";
        assert_eq!(merge(live, "model = \"a\"\n", None).unwrap().text, live);
    }

    #[test]
    fn reports_owned_keys_changed_since_the_record() {
        let settings = "model = \"a\"\neffort = \"low\"\n";
        let first = merge("", settings, None).unwrap();
        let live = first.text.replace("\"a\"", "\"b\"") + "extra = 1\n";
        let second = merge(&live, settings, Some(&first.owned)).unwrap();
        assert_eq!(second.drifted, [key("model")]);
        let now = owned_in(&live, &first.owned).unwrap();
        assert_eq!(first.owned.changed(&now), [key("model")]);
    }

    #[test]
    fn reports_differing_declared_keys_on_the_first_run() {
        let merged = merge("model = \"ui\"\nother = 1\n", "model = \"src\"\n", None).unwrap();
        assert_eq!(merged.drifted, [key("model")]);
    }

    #[test]
    fn refuses_live_toml_that_does_not_parse_in_one_line() {
        let reason = merge("model = \n", "model = \"a\"\n", None).unwrap_err();
        assert!(
            reason.starts_with("in the live file, line 1, column "),
            "{reason}"
        );
        assert!(!reason.contains('\n') && !reason.contains('|'), "{reason}");
    }

    #[test]
    fn owns_each_server_entry_as_one_value() {
        let desired =
            "[mcp_servers.dart]\ncommand = \"dart\"\n\n[mcp_servers.dart.env]\nA = \"1\"\n";
        let first = merge("[mcp_servers.repl]\ncommand = \"app\"\n", desired, None).unwrap();
        assert_eq!(
            first.text,
            "[mcp_servers.repl]\ncommand = \"app\"\n\n[mcp_servers.dart]\ncommand = \"dart\"\n\n[mcp_servers.dart.env]\nA = \"1\"\n"
        );
        assert_eq!(
            first.owned.keys().collect::<Vec<_>>(),
            [&key("mcp_servers.dart")]
        );
        let second = merge(&first.text, "", Some(&first.owned)).unwrap();
        assert_eq!(second.text, "[mcp_servers.repl]\ncommand = \"app\"\n");
    }

    #[test]
    fn ownership_moving_from_a_value_to_its_leaves_keeps_the_leaves() {
        let first = merge("", "srv = { command = \"dart\" }\n", None).unwrap();
        let leaves = "[srv]\ncommand = \"dart2\"\n";
        let second = merge(&first.text, leaves, Some(&first.owned)).unwrap();
        assert_eq!(second.text, "[srv]\ncommand = \"dart2\"\n");
        let third = merge(&second.text, leaves, Some(&second.owned)).unwrap();
        assert_eq!(third.text, second.text);
    }

    #[test]
    fn ownership_moving_from_leaves_to_their_inline_parent_keeps_the_parent() {
        let first = merge("", "[tui]\ntheme = \"dark\"\n", None).unwrap();
        let parent = "tui = { theme = \"light\" }\n";
        let second = merge(&first.text, parent, Some(&first.owned)).unwrap();
        assert_eq!(second.text, "tui = { theme = \"light\" }\n");
        let third = merge(&second.text, parent, Some(&second.owned)).unwrap();
        assert_eq!(third.text, second.text);
    }

    #[test]
    fn a_leaf_record_from_0_41_keeps_a_server_now_owned_whole_in_place() {
        let live = "model = \"a\"\n\n# app server\n[mcp_servers.repl]\ncommand = \"app\"\n\n[mcp_servers.repl.env]\nA = \"1\"\n\n[desktop]\nmode = \"q\"\n";
        let paths = [
            "model",
            "mcp_servers.repl.command",
            "mcp_servers.repl.env.A",
        ];
        let record = Owned::from_pairs(paths.iter().map(|path| (key(path), String::new())));
        let leaves = owned_in(live, &record).unwrap();
        let desired = "model = \"a\"\n\n[mcp_servers.repl]\ncommand = \"app\"\n\n[mcp_servers.repl.env]\nA = \"1\"\n";
        let merged = merge(live, desired, Some(&leaves)).unwrap();
        assert_eq!(merged.text, live);
        assert!(merged.drifted.is_empty());
    }

    #[test]
    fn a_removed_key_takes_its_emptied_tables_with_it() {
        let first = merge("", "[a.b]\nc = 1\n", None).unwrap();
        assert_eq!(merge(&first.text, "", Some(&first.owned)).unwrap().text, "");
    }

    #[test]
    fn adopt_copies_live_values_and_keeps_source_comments() {
        let live = "model = \"ui\"\n[tui]\nnux = 1\n";
        let source = "# mine\nmodel = \"src\" # pick\neffort = \"low\"\n";
        let adopted = adopt(live, source, &[key("model"), key("effort")]).unwrap();
        assert_eq!(adopted, "# mine\nmodel = \"ui\" # pick\n");
    }
}
