//! Key-level ownership of a TOML file another program also writes: a sync sets
//! the keys its sources declare, removes the ones it declared before and no
//! longer does, and leaves every other key as the other program wrote it.

use std::collections::BTreeMap;

use toml_edit::{DocumentMut, Item, Table, TableLike, Value};

use crate::transaction::manifest::sha256_hex;

pub type KeyPath = Vec<String>;

/// The keys one file's sync owns, each with a short hash of its value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Owned(BTreeMap<KeyPath, String>);

impl Owned {
    pub fn keys(&self) -> impl Iterator<Item = &KeyPath> {
        self.0.keys()
    }

    /// The manifest column: a JSON array of `[path, hash]` pairs.
    pub fn encode(&self) -> String {
        let pairs: Vec<(&KeyPath, &String)> = self.0.iter().collect();
        serde_json::to_string(&pairs).unwrap_or_default()
    }

    pub fn decode(text: &str) -> Option<Self> {
        let pairs: Vec<(KeyPath, String)> = serde_json::from_str(text).ok()?;
        Some(Self(pairs.into_iter().collect()))
    }

    pub fn digest(&self) -> String {
        sha256_hex(self.encode().as_bytes())
    }

    /// Keys whose value in `now` no longer matches this record.
    pub fn changed(&self, now: &Owned) -> Vec<KeyPath> {
        self.0
            .iter()
            .filter(|(key, hash)| now.0.get(*key) != Some(*hash))
            .map(|(key, _)| key.clone())
            .collect()
    }
}

/// The values a sync declares, by key path, in source order.
#[derive(Debug, Default)]
pub struct Declared(Vec<(KeyPath, Item)>);

impl Declared {
    /// Every leaf of `text` becomes one owned key; an inline table, an array,
    /// and an array of tables each count as one value.
    pub fn from_toml(text: &str) -> Result<Self, String> {
        let doc = parse(text)?;
        let mut declared = Self::default();
        collect_leaves(doc.as_table(), &mut Vec::new(), &mut declared.0);
        Ok(declared)
    }

    /// Each entry of the table at `prefix` in `text` becomes one owned subtree.
    pub fn add_subtrees(&mut self, text: &str, prefix: &str) -> Result<(), String> {
        let doc = parse(text)?;
        if let Some(table) = doc.get(prefix).and_then(Item::as_table_like) {
            for (key, item) in table.iter() {
                let path = vec![prefix.to_string(), key.to_string()];
                self.0.retain(|(existing, _)| *existing != path);
                self.0.push((path, item.clone()));
            }
        }
        Ok(())
    }

    pub fn contains_top_level(&self, key: &str) -> bool {
        self.0
            .iter()
            .any(|(path, _)| path.first().is_some_and(|k| k == key))
    }

    fn contains(&self, path: &KeyPath) -> bool {
        self.0.iter().any(|(existing, _)| existing == path)
    }

    fn owned(&self) -> Owned {
        Owned(
            self.0
                .iter()
                .map(|(path, item)| (path.clone(), hash_item(Some(item))))
                .collect(),
        )
    }
}

#[derive(Debug)]
pub struct Merged {
    pub text: String,
    pub owned: Owned,
    /// Owned keys another program changed since `previous` was recorded, or,
    /// without a record, declared keys whose live value differs.
    pub drifted: Vec<KeyPath>,
}

/// `declared` applied over `live`. Keys `previous` owned and `declared` no
/// longer names are removed; without a record nothing is removed. The text
/// comes back byte for byte when every declared value already matches.
pub fn merge(live: &str, declared: &Declared, previous: Option<&Owned>) -> Result<Merged, String> {
    let mut doc = parse(live)?;
    let drifted = match previous {
        Some(previous) => previous.changed(&owned_now(&doc, previous.keys())),
        None => declared
            .0
            .iter()
            .filter(|(path, item)| {
                lookup(doc.as_table(), path).is_some_and(|live| canonical(live) != canonical(item))
            })
            .map(|(path, _)| path.clone())
            .collect(),
    };
    let mut changed = false;
    for (path, item) in &declared.0 {
        let current = lookup(doc.as_table(), path);
        if current.is_some_and(|live| canonical(live) == canonical(item)) {
            continue;
        }
        set(doc.as_table_mut(), path, item.clone());
        changed = true;
    }
    for path in previous.into_iter().flat_map(Owned::keys) {
        if !declared.contains(path) && remove(doc.as_table_mut(), path) {
            changed = true;
        }
    }
    Ok(Merged {
        text: if changed {
            doc.to_string()
        } else {
            live.to_string()
        },
        owned: declared.owned(),
        drifted,
    })
}

/// The current hashes in `live` of the keys `record` owns; an absent key
/// hashes as empty.
pub fn owned_in(live: &str, record: &Owned) -> Result<Owned, String> {
    Ok(owned_now(&parse(live)?, record.keys()))
}

/// The value `live` holds at `path`, as TOML text for a settings file.
pub fn value_at(live: &str, path: &KeyPath) -> Result<Option<Item>, String> {
    Ok(lookup(parse(live)?.as_table(), path).cloned())
}

/// `text` with `path` set to `item`, every other line kept.
pub fn set_in(text: &str, path: &KeyPath, item: Item) -> Result<String, String> {
    let mut doc = parse(text)?;
    set(doc.as_table_mut(), path, item);
    Ok(doc.to_string())
}

pub fn display(path: &KeyPath) -> String {
    path.join(".")
}

fn parse(text: &str) -> Result<DocumentMut, String> {
    text.parse::<DocumentMut>()
        .map_err(|e| e.to_string().trim_end().replace('\n', " "))
}

fn owned_now<'a>(doc: &DocumentMut, keys: impl Iterator<Item = &'a KeyPath>) -> Owned {
    Owned(
        keys.map(|path| (path.clone(), hash_item(lookup(doc.as_table(), path))))
            .collect(),
    )
}

fn collect_leaves(table: &dyn TableLike, path: &mut KeyPath, out: &mut Vec<(KeyPath, Item)>) {
    for (key, item) in table.iter() {
        path.push(key.to_string());
        match item {
            Item::Table(table) => collect_leaves(table, path, out),
            Item::None => {}
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
    let replacement = match (table.get(last), item) {
        (Some(Item::Value(old)), Item::Value(mut new)) => {
            *new.decor_mut() = old.decor().clone();
            Item::Value(new)
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
        Some(item) => sha256_hex(canonical(item).as_bytes())[..16].to_string(),
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

    fn declared(settings: &str) -> Declared {
        Declared::from_toml(settings).unwrap()
    }

    #[test]
    fn keeps_keys_it_does_not_own() {
        let live = "model = \"old\"\n\n[projects.\"/tmp/x\"]\ntrust_level = \"trusted\" # app\n";
        let merged = merge(live, &declared("model = \"new\"\n"), None).unwrap();
        assert_eq!(
            merged.text,
            "model = \"new\"\n\n[projects.\"/tmp/x\"]\ntrust_level = \"trusted\" # app\n"
        );
    }

    #[test]
    fn sets_declared_keys_inside_existing_tables() {
        let live = "[tui]\nnux = 1\n";
        let merged = merge(live, &declared("[tui]\ntheme = \"dark\"\n"), None).unwrap();
        assert_eq!(merged.text, "[tui]\nnux = 1\ntheme = \"dark\"\n");
    }

    #[test]
    fn leaves_bytes_unchanged_when_values_match() {
        let live = "model  =  'gpt'   # mine\n[tui]\ntheme = \"dark\"\nnux = 1\n";
        let merged = merge(
            live,
            &declared("model = \"gpt\"\n[tui]\ntheme = 'dark'\n"),
            None,
        )
        .unwrap();
        assert_eq!(merged.text, live);
        assert!(merged.drifted.is_empty());
    }

    #[test]
    fn removes_keys_it_owned_before_and_no_longer_declares() {
        let first = merge("", &declared("model = \"a\"\n[tui]\ntheme = \"x\"\n"), None).unwrap();
        let live = format!("{}\n[projects.p]\ntrust_level = \"trusted\"\n", first.text);
        let second = merge(&live, &declared("model = \"a\"\n"), Some(&first.owned)).unwrap();
        assert_eq!(
            second.text,
            "model = \"a\"\n\n[projects.p]\ntrust_level = \"trusted\"\n"
        );
        assert_eq!(second.owned.keys().collect::<Vec<_>>(), [&key("model")]);
    }

    #[test]
    fn removes_nothing_without_a_previous_record() {
        let live = "model = \"a\"\nsandbox = \"x\"\n";
        let merged = merge(live, &declared("model = \"a\"\n"), None).unwrap();
        assert_eq!(merged.text, live);
    }

    #[test]
    fn reports_owned_keys_changed_since_the_record() {
        let settings = "model = \"a\"\neffort = \"low\"\n";
        let first = merge("", &declared(settings), None).unwrap();
        let live = first.text.replace("\"a\"", "\"b\"") + "extra = 1\n";
        let second = merge(&live, &declared(settings), Some(&first.owned)).unwrap();
        assert_eq!(second.drifted, [key("model")]);
        let now = owned_in(&live, &first.owned).unwrap();
        assert_eq!(first.owned.changed(&now), [key("model")]);
    }

    #[test]
    fn reports_differing_declared_keys_on_the_first_run() {
        let merged = merge(
            "model = \"ui\"\nother = 1\n",
            &declared("model = \"src\"\n"),
            None,
        )
        .unwrap();
        assert_eq!(merged.drifted, [key("model")]);
    }

    #[test]
    fn refuses_live_toml_that_does_not_parse() {
        assert!(merge("model = \n", &declared("model = \"a\"\n"), None).is_err());
    }

    #[test]
    fn owns_a_table_entry_as_one_subtree() {
        let mut declared = declared("");
        declared
            .add_subtrees("[mcp_servers.dart]\ncommand = \"dart\"\n", "mcp_servers")
            .unwrap();
        let first = merge("[mcp_servers.repl]\ncommand = \"app\"\n", &declared, None).unwrap();
        assert_eq!(
            first.text,
            "[mcp_servers.repl]\ncommand = \"app\"\n\n[mcp_servers.dart]\ncommand = \"dart\"\n"
        );
        assert_eq!(
            first.owned.keys().collect::<Vec<_>>(),
            [&key("mcp_servers.dart")]
        );
        let second = merge(&first.text, &Declared::default(), Some(&first.owned)).unwrap();
        assert_eq!(second.text, "[mcp_servers.repl]\ncommand = \"app\"\n");
    }

    #[test]
    fn a_removed_key_takes_its_emptied_tables_with_it() {
        let first = merge("", &declared("[a.b]\nc = 1\n"), None).unwrap();
        let second = merge(&first.text, &Declared::default(), Some(&first.owned)).unwrap();
        assert_eq!(second.text, "");
    }

    #[test]
    fn owned_records_round_trip_through_the_manifest_column() {
        let settings = "model = \"a\"\n[\"odd\\tkey\"]\nx = 1\n";
        let owned = merge("", &declared(settings), None).unwrap().owned;
        assert!(!owned.encode().contains('\t'));
        assert_eq!(Owned::decode(&owned.encode()), Some(owned));
        assert_eq!(Owned::decode("not json"), None);
    }
}
