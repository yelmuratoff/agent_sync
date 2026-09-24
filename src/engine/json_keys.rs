//! The JSON side of `keyed`. `serde_json` keeps no formatting, so an unchanged
//! file comes back byte for byte and a changed one is written pretty-printed
//! with its keys sorted.

use serde_json::{Map, Value};

use crate::engine::keyed::{self, KeyPath, Merged, Owned, UNIT_ROOTS};

pub fn merge(live: &str, desired: &str, previous: Option<&Owned>) -> Result<Merged, String> {
    let declared = declared(desired)?;
    let mut doc = parse(live)?;
    let drifted = match previous {
        Some(previous) => previous.changed(&owned_now(&doc, previous.keys())),
        None => declared
            .iter()
            .filter(|(path, value)| lookup(&doc, path).is_some_and(|live| live != value))
            .map(|(path, _)| path.clone())
            .collect(),
    };
    let mut changed = false;
    for path in previous.into_iter().flat_map(Owned::keys) {
        if !declared.iter().any(|(declared, _)| declared == path) && remove(&mut doc, path) {
            changed = true;
        }
    }
    for (path, value) in &declared {
        if lookup(&doc, path) == Some(value) {
            continue;
        }
        set(&mut doc, path, value.clone());
        changed = true;
    }
    Ok(Merged {
        text: if changed {
            render(&doc)
        } else {
            live.to_string()
        },
        owned: Owned::from_pairs(
            declared
                .iter()
                .map(|(path, value)| (path.clone(), hash_value(Some(value)))),
        ),
        drifted,
    })
}

pub fn owned_in(live: &str, record: &Owned) -> Result<Owned, String> {
    Ok(owned_now(&parse(live)?, record.keys()))
}

pub fn adopt(live: &str, source: &str, keys: &[KeyPath]) -> Result<String, String> {
    let live = parse(live)?;
    let mut doc = parse(source)?;
    for key in keys {
        match lookup(&live, key) {
            Some(value) => set(&mut doc, key, value.clone()),
            None => {
                remove(&mut doc, key);
            }
        }
    }
    Ok(render(&doc))
}

/// Every leaf of `desired` is one owned key; an array and each entry of a
/// server map count as one value.
fn declared(desired: &str) -> Result<Vec<(KeyPath, Value)>, String> {
    let doc = parse(desired)?;
    let mut out = Vec::new();
    collect_leaves(&doc, &mut Vec::new(), &mut out);
    Ok(out)
}

fn parse(text: &str) -> Result<Map<String, Value>, String> {
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(_) => Err("the top level is not a JSON object".into()),
        Err(e) => {
            let message = e.to_string();
            let message = message
                .split(" at line ")
                .next()
                .unwrap_or_default()
                .to_string();
            let mut reason = format!("line {}, column {}: {message}", e.line(), e.column());
            if text.contains("//") || text.contains("/*") {
                reason.push_str(
                    "; comments are not JSON, so own this file whole with targets.<resource>.ownership: file",
                );
            }
            Err(reason)
        }
    }
}

fn render(doc: &Map<String, Value>) -> String {
    let mut text = serde_json::to_string_pretty(doc).unwrap_or_default();
    text.push('\n');
    text
}

fn owned_now<'a>(doc: &Map<String, Value>, keys: impl Iterator<Item = &'a KeyPath>) -> Owned {
    Owned::from_pairs(keys.map(|path| (path.clone(), hash_value(lookup(doc, path)))))
}

fn collect_leaves(map: &Map<String, Value>, path: &mut KeyPath, out: &mut Vec<(KeyPath, Value)>) {
    for (key, value) in map {
        path.push(key.clone());
        let unit_root = path.len() == 1 && UNIT_ROOTS.contains(&key.as_str());
        match value {
            Value::Object(entries) if unit_root => {
                for (entry, server) in entries {
                    out.push((vec![key.clone(), entry.clone()], server.clone()));
                }
            }
            Value::Object(child) => collect_leaves(child, path, out),
            _ => out.push((path.clone(), value.clone())),
        }
        path.pop();
    }
}

fn lookup<'a>(doc: &'a Map<String, Value>, path: &[String]) -> Option<&'a Value> {
    let (last, parents) = path.split_last()?;
    let mut map = doc;
    for key in parents {
        map = map.get(key)?.as_object()?;
    }
    map.get(last)
}

fn set(doc: &mut Map<String, Value>, path: &[String], value: Value) {
    let Some((last, parents)) = path.split_last() else {
        return;
    };
    let mut map = doc;
    for key in parents {
        let slot = map
            .entry(key.clone())
            .or_insert_with(|| Value::Object(Map::new()));
        if !slot.is_object() {
            *slot = Value::Object(Map::new());
        }
        let Some(next) = slot.as_object_mut() else {
            return;
        };
        map = next;
    }
    map.insert(last.clone(), value);
}

/// Removes `path` and any object it leaves empty; `true` when something went.
fn remove(doc: &mut Map<String, Value>, path: &[String]) -> bool {
    let Some((last, parents)) = path.split_last() else {
        return false;
    };
    let removed = {
        let mut map = &mut *doc;
        for key in parents {
            let Some(next) = map.get_mut(key).and_then(Value::as_object_mut) else {
                return false;
            };
            map = next;
        }
        map.remove(last).is_some()
    };
    if removed {
        for depth in (1..=parents.len()).rev() {
            let prefix = &parents[..depth];
            if lookup(doc, prefix)
                .and_then(Value::as_object)
                .is_some_and(Map::is_empty)
            {
                remove(doc, prefix);
            } else {
                break;
            }
        }
    }
    removed
}

fn hash_value(value: Option<&Value>) -> String {
    match value {
        Some(value) => keyed::short_hash(&serde_json::to_string(value).unwrap_or_default()),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(path: &str) -> KeyPath {
        path.split('.').map(str::to_string).collect()
    }

    #[test]
    fn keeps_keys_it_does_not_own() {
        let live = "{\n  \"model\": \"old\",\n  \"feedbackSurveyState\": {\"last\": 3}\n}\n";
        let merged = merge(live, r#"{"model": "new"}"#, None).unwrap();
        assert_eq!(
            merged.text,
            "{\n  \"feedbackSurveyState\": {\n    \"last\": 3\n  },\n  \"model\": \"new\"\n}\n"
        );
    }

    #[test]
    fn leaves_bytes_unchanged_when_values_match() {
        let live = "{\"theme\":\"dark\",   \"model\": \"a\", \"env\": {\"X\": \"1\"}}";
        let merged = merge(live, "{\"env\": {\"X\": \"1\"}, \"model\": \"a\"}", None).unwrap();
        assert_eq!(merged.text, live);
        assert!(merged.drifted.is_empty());
    }

    #[test]
    fn owns_leaves_so_the_app_can_add_siblings() {
        let desired = r#"{"enabledPlugins": {"a@m": true}, "permissions": {"allow": ["Read"]}}"#;
        let first = merge("{}", desired, None).unwrap();
        let live = first
            .text
            .replace("\"a@m\": true", "\"a@m\": true,\n    \"b@m\": true");
        let second = merge(&live, desired, Some(&first.owned)).unwrap();
        assert_eq!(second.text, live);
        assert!(second.drifted.is_empty());
        assert_eq!(
            first.owned.keys().collect::<Vec<_>>(),
            [&key("enabledPlugins.a@m"), &key("permissions.allow")]
        );
    }

    #[test]
    fn owns_each_server_entry_as_one_value() {
        let live = r#"{"mcpServers": {"ui-added": {"command": "x"}}}"#;
        let desired = r#"{"mcpServers": {"dart": {"command": "dart", "args": ["mcp-server"]}}}"#;
        let first = merge(live, desired, None).unwrap();
        assert_eq!(
            first.owned.keys().collect::<Vec<_>>(),
            [&key("mcpServers.dart")]
        );
        assert!(first.text.contains("\"ui-added\""));
        let second = merge(&first.text, r#"{"mcpServers": {}}"#, Some(&first.owned)).unwrap();
        assert_eq!(
            second.text,
            "{\n  \"mcpServers\": {\n    \"ui-added\": {\n      \"command\": \"x\"\n    }\n  }\n}\n"
        );
    }

    #[test]
    fn removes_owned_keys_and_the_objects_they_empty() {
        let first = merge("{}", r#"{"a": {"b": 1}, "model": "m"}"#, None).unwrap();
        let second = merge(&first.text, r#"{"model": "m"}"#, Some(&first.owned)).unwrap();
        assert_eq!(second.text, "{\n  \"model\": \"m\"\n}\n");
    }

    #[test]
    fn removes_nothing_without_a_previous_record() {
        let live = "{\"model\": \"a\", \"theme\": \"dark\"}\n";
        assert_eq!(merge(live, r#"{"model": "a"}"#, None).unwrap().text, live);
    }

    #[test]
    fn reports_changed_owned_keys_and_first_run_differences() {
        let first = merge("{}", r#"{"model": "a", "tui": "full"}"#, None).unwrap();
        let live = first.text.replace("\"a\"", "\"b\"");
        let second = merge(
            &live,
            r#"{"model": "a", "tui": "full"}"#,
            Some(&first.owned),
        )
        .unwrap();
        assert_eq!(second.drifted, [key("model")]);
        let fresh = merge(r#"{"model": "ui"}"#, r#"{"model": "src"}"#, None).unwrap();
        assert_eq!(fresh.drifted, [key("model")]);
    }

    #[test]
    fn an_empty_live_file_starts_from_an_empty_object() {
        let merged = merge("", r#"{"model": "a"}"#, None).unwrap();
        assert_eq!(merged.text, "{\n  \"model\": \"a\"\n}\n");
    }

    #[test]
    fn refuses_jsonc_with_a_hint() {
        let reason = merge("{\n  // mine\n  \"a\": 1\n}\n", r#"{"a": 1}"#, None).unwrap_err();
        assert!(reason.starts_with("line 2, column "), "{reason}");
        assert!(reason.contains("ownership: file"), "{reason}");
        assert!(
            merge("[1]", "{}", None)
                .unwrap_err()
                .contains("not a JSON object")
        );
    }

    #[test]
    fn adopt_copies_live_values_into_the_source() {
        let live = r#"{"model": "ui", "theme": "light"}"#;
        let source = r#"{"model": "src", "effortLevel": "high"}"#;
        let adopted = adopt(live, source, &[key("model"), key("effortLevel")]).unwrap();
        assert_eq!(adopted, "{\n  \"model\": \"ui\"\n}\n");
    }
}
