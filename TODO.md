# TODO

Deferred work for future releases. Scoped out of the 0.6.0 layered-config release.

---

## 1. Content-layer: `agentsync add <kind> <name>`

**Goal:** extend the CLI from tool-config management (already shipped in 0.6.0) to source-content management. Today users create rule/skill/command files by hand in `.ai/src/`. An `add` command should scaffold them with correct frontmatter and register them in the right index.

**Scope:**

- `agentsync add rule <name>` — scaffold `.ai/src/rules/<name>.md` with default frontmatter (`globs`, `applyTo`, `trigger` — match the per-tool defaults already documented).
- `agentsync add skill <name>` — scaffold `.ai/src/skills/<name>.md`.
- `agentsync add command <name>` — scaffold `.ai/src/commands/<name>.md` with TOML-friendly frontmatter.
- `agentsync add subagent <name>` — scaffold `.ai/src/agents/<name>.md` (maps to `.claude/agents/` etc.).

**Design constraints:**

- No new dependencies. Pure Bash + existing `lib/helpers/`.
- Templates live in `lib/templates/content/` (new dir) — one per kind.
- Reject existing files by default; `--force` overwrites.
- Reject names with path separators or `..` — security, per `lib/helpers/paths.sh` patterns.
- Print the created path + next-step hint (`agentsync sync` to propagate).

**Checklist:**

- [x] `lib/templates/content/rule.md` — default frontmatter + stub body
- [x] `lib/templates/content/skill.md`
- [x] `lib/templates/content/command.md`
- [x] `lib/templates/content/subagent.md`
- [x] `lib/helpers/add.sh` — `cmd_add <kind> <name> [--force]` dispatcher
- [x] Name validation (no `/`, no `..`, no empty)
- [x] Wire `cmd_add` into `bin/agentsync.sh` (source, help, examples, dispatch, update-check allowlist)
- [x] `tests/add.bats` — create each kind, refuse existing, refuse bad names, `--force` overwrite
- [x] Update `agentsync` skill docs with the new command
- [x] ShellCheck pass on `add.sh`

---

## 2. Snapshot-based conflict detection on `update`

**Goal:** when `agentsync update` pulls a new release, detect cases where the user has an override on a field that the upstream base template just changed. Today this is only surfaced later via `diff` / `resolve` — the user may miss important upstream improvements.

**Scope:**

- Before `update` swaps in the new engine, snapshot the current install-dir tool catalog (`lib/templates/tools/*.yaml`) field-by-field.
- After the swap, compare each field against the new base. For every field that changed AND the project has a user override for it, emit a warning.
- Print a grouped summary: `<tool>: <field> — base changed from X to Y, your override is Z`.
- Exit 0 with warnings (non-blocking), or exit 1 if `--strict` is passed.
- Writes a `.ai/.pending-resolutions.yaml` (or similar) that `agentsync resolve` can consume — turns a stale warning list into an actionable queue.

**Design constraints:**

- Snapshot format: flat `tool.field: hash` map, SHA of the YAML value. Cheap to diff.
- No network calls beyond what `update` already does (the update tarball is the "new" side).
- Degrade gracefully if snapshot file is missing (first run after this feature ships) — just skip detection that time.
- Don't block `update` — the user may have intentionally overridden, and we shouldn't make upgrades painful.

**Checklist:**

- [x] Design snapshot file format (location: `$AGENTSYNC_HOME/.snapshot/tools/`)
- [x] `lib/helpers/snapshot.sh` — `snapshot_save` / `snapshot_diff` / `snapshot_find_conflicts` / `snapshot_write_pending_resolutions` / `snapshot_read_pending_pairs` / `snapshot_clear_pending`
- [x] Hook snapshot write into `cmd_update` pre-swap
- [x] Hook snapshot diff into `cmd_update` post-swap
- [x] Integrate per-project override check — read project `.ai/src/tools/*.yaml`
- [x] Write `.ai/.pending-resolutions.yaml` when conflicts found
- [x] Extend `cmd_resolve` to consume the pending-resolutions file (flag fields with ⚡, clear queue when walked)
- [x] `--strict` flag for CI: non-zero exit on any upstream-vs-override conflict
- [x] `tests/update_snapshot.bats` — fake old/new catalogs, verify detection
- [x] Document the `.pending-resolutions.yaml` file in the `agentsync` skill
- [x] ShellCheck pass

---

## 3. `agentsync simplify`

**Goal:** clean up overrides that have drifted into redundancy. After a user runs `customize <tool> --full`, they may only edit a few fields — but the override still carries the whole base verbatim. Over time those redundant fields pin stale values and silently block upstream updates. `simplify` compresses a full override into a minimal per-field override.

**Scope:**

- `agentsync simplify [<tool>]` — with no args, process all user overrides; with a tool name, process just that one.
- For each field in the user override, compare against the current base. If values are byte-equal, remove the field from the override.
- If the override ends up empty, offer to delete the file entirely (with `-y` auto-accepts).
- Dry-run by default (`--apply` actually writes). Print a diff preview of what would be removed.

**Design constraints:**

- Idempotent: running twice in a row with `--apply` should be a no-op the second time.
- Preserve user comments inside the YAML override where possible (a stretch — may require parser work).
- Safe: never touch `.ai/src/tools/` without `--apply`.

**Checklist:**

- [ ] `lib/helpers/simplify.sh` — `cmd_simplify [tool] [--apply] [-y]`
- [ ] Field-by-field equality check using existing `tool_resolver.sh` / `yaml.sh` helpers
- [ ] Dry-run output format: unified-diff-ish preview
- [ ] `--apply` mutation via `yaml_edit.sh` (`yaml_remove_key` per redundant field)
- [ ] Auto-delete empty override files (`-y` to skip prompt)
- [ ] Preserve comments — investigate feasibility, document limitation if deferred
- [ ] Wire into `bin/agentsync.sh` (source, help, examples, dispatch, update-check allowlist)
- [ ] `tests/simplify.bats` — redundant-field removal, empty-file deletion, idempotency, `--apply` gating
- [ ] Update `agentsync` skill docs
- [ ] ShellCheck pass

---

## Release sequencing

Suggested order for future releases:

- **0.6.x** patches: bug fixes on the layered-config surface shipped in 0.6.0.
- **0.7.0**: `add` command (content-layer) — natural extension of the CLI surface, low risk.
- **0.8.0**: `simplify` — builds on 0.6.0's override model, independent from snapshot work.
- **0.9.0** or **1.0.0**: snapshot-based conflict detection on `update` — biggest and most sensitive (touches the upgrade path). Ship after the ecosystem has settled on the 0.6.0 override model.
