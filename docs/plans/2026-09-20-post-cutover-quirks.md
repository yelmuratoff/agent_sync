# Post-Cutover Triage: The 54 Known Quirks

> Triage, not an executable port. It classifies the debt and orders it; each accepted line becomes its own change with its own plan or commit.

**Goal:** The design spec's "Known quirks to reproduce now and fix after cutover" (`docs/specs/2026-09-12-rust-migration-design.md:472-601`) listed 55 Bash behaviours the Rust engine reproduces on purpose; item 8 was struck on 2026-09-20 as a ratified deviation, leaving 54. The cutover is past — 0.37.0 shipped the binary, 0.38.0 ships without Bash — so the list's premise is due. This document reads every live item against `src/` as it stands, records where the behaviour lives and what pins it, classifies it, and splits the result into what a minor release can carry and what needs a major-version decision. It changes no engine behaviour and edits neither `src/`, `tests/`, nor the spec.

**Findings, in one line each:** 41 defects, 3 compatibility, 10 cosmetic, **0 already resolved** — every item on the list is still reproduced by the binary, and none of them migrated to the spec's "Accepted deviations" section. The second-order finding is the one that matters for anyone acting on this: **21 of the 54 have no test pinning them at all**, so the migration reproduced them by construction rather than by proof, and nothing would catch them changing by accident.

**Tech stack:** Rust 2024 edition (MSRV 1.85), `unsafe_code = "forbid"`. Design: `docs/specs/2026-09-12-rust-migration-design.md`. Previous plan: `docs/plans/2026-09-19-rust-migration-phase-7b-port-the-suite.md`.

## Global Constraints

- The spec's numbering is load-bearing: source comments (`src/yaml_subset.rs:284`, `src/convert.rs:411`, `src/rules.rs:617`, `src/style.rs:63`, `src/render.rs:1384`, `src/version.rs:72`, `src/changelog.rs:275`, `src/cli/release.rs:286`) and tests cite items by number. A fixed item is struck in place with its number retained, as item 8 was — never renumbered, never deleted.
- An item whose fix changes bytes written into an existing project's tree (`.ai/`, `agent_sync.yaml`, `.ai/.template-manifest`, or any generated output directory) cannot ship in a minor release. That test, not severity, decides the release it lands in.
- An item with no test today gets its pinning test written **first**, asserting today's behaviour, in a separate commit from the fix. Otherwise the fix has no red-green evidence and the blast radius is a guess.
- A fix carries the struck spec line and a CHANGELOG entry under `### Fixed` naming what a user will see change. Items with no user-visible effect go under `### Internal`.
- Nothing here is a regression: 0.37.0 and 0.38.0 shipped every one of these knowingly. There is no deadline and no obligation to clear the list.

## Decisions for the review

1. **The list is closed, not a backlog to burn down.** 10 cosmetic and 3 compatibility items have no defensible fix and are listed under "Not recommended" with their reasons. Treating 54 as 54 tickets would spend a quarter on output nobody complained about.
2. **The security-relevant pair leads.** Items 44 and 45 make `doctor` silently miss a real secret. Both are scanner-only — zero blast radius on generated output — so they can ship in the next patch release. Nothing else on the list can cause harm a user would not notice.
3. **Config-path honesty is one change, not five.** Items 14, 30, 32 and 40 are the same bug in four commands: an ad-hoc `.ai/agent_sync.yaml` → `agent_sync.yaml` search that ignores `AGENTSYNC_CONFIG_PATH`, contradicting the invariant `src/project.rs:19` states. They share one fix (route through `Project`'s resolution) and should share one change so the four commands cannot drift apart again.
4. **The YAML reader's three quirks (1, 2, 13) are one decision.** Items 1 and 13 are both `yaml_subset` answering the wrong occurrence; item 2 is the comment rule. They sit under every config read in the engine, so any change there is a major-version change even where an individual symptom looks harmless.
5. **Blast radius is assessed against a project that already exists**, not a fresh `init`. "Would a user who runs the new binary over an unchanged tree see different files?" is the question each row answers.
6. **Order:** security first (Group A), then the no-output-change defects (Group B), then the config-path change (Group C), then the major-version queue (Group D) only if a major is being cut for another reason. **Recommended:** as listed; Groups A and B are the only ones worth scheduling on their own.

## The 54 live items

`—` in the test column means no test pins the behaviour. "Output" is the blast radius: does fixing it change files in an existing project?

| # | Quirk | Class | Module | Test | Output |
|---|---|---|---|---|---|
| 1 | Empty block key takes the next dash list anywhere later | defect | `src/yaml_subset.rs:121-177` | `src/yaml_subset.rs:285` | yes |
| 2 | Unquoted scalar cut at the first `#`, no space needed | compatibility | `src/yaml_subset.rs:37-48` | `src/yaml_subset.rs:247` | yes |
| 3 | `\n` in a quoted header stays literal until write time | cosmetic | `src/yaml_subset.rs:37-60`, `src/text.rs:88` | `src/yaml_subset.rs:217` | no |
| 4 | No empty-string override; `base:` ignored when a shipped file exists | defect | `src/tool.rs:53-70` | `src/tool.rs:161` | yes |
| 5 | `defaults.enabled` and `lib/config.yaml`'s `defaults:` never read | defect | `src/catalog.rs:95`, `src/render.rs:181-283` | — | no (if removed) |
| 6 | `pad_right` counts escape bytes, so coloured `list` columns drift | cosmetic | `src/style.rs:64-71` | `src/style.rs:90` | no |
| 7 | `outputs` default inferred from `gitignore.update`, rule copied 3× | compatibility | `src/render.rs:211`, `src/cli/check.rs:155`, `src/cli/setup_hooks.rs:122` | `src/cli/check.rs:504`, `src/cli/setup_hooks.rs:344` | yes (rule) / no (de-dup) |
| 8 | *Struck 2026-09-20: ratified deviation, not a quirk.* | — | — | — | — |
| 9 | `read_field` returns the last frontmatter occurrence | defect | `src/convert.rs:123-149` | `src/convert.rs:412` | yes |
| 10 | `rule_paths_csv` takes every list item once a bare `paths:` exists | defect | `src/rules.rs:84-116` | `src/rules.rs:617` | yes |
| 11 | `description: >-` indexes the skill as `-` | defect | `src/render.rs:921-949` | `src/render.rs:1384` | yes |
| 12 | Workspace fan-out labels the *last* failure as "max exit code" | defect | `src/cli/workspace.rs:50-81` | — | no |
| 13 | A scalar `version_pin:` before a `version_pin:` mapping wins | defect | `src/version.rs:14-24` | `src/version.rs:69` | no |
| 14 | `enable`/`disable` ignore `AGENTSYNC_CONFIG_PATH` when writing | defect | `src/cli/enable.rs:44-61` | — | yes (env-var users) |
| 15 | `disable` creates `.ai/agent_sync.yaml` in a project that had none | defect | `src/cli/enable.rs:258` | — | yes |
| 16 | `enable` appends a second `tools:` block when `enabled:` is absent | defect | `src/yaml_edit.rs:96-117` | `src/yaml_edit.rs:315` | yes |
| 17 | `disable` lists unknown and repeated slugs as disabled tools | defect | `src/cli/enable.rs:280-293` | `src/cli/enable.rs:386` | no |
| 18 | `diff <slug>` reports "No user overrides" for any slug | defect | `src/cli/diff.rs:106-117` | `tests/customize.rs:122` (no-slug only) | no |
| 19 | `show` labels an override `base` when its extension differs | defect | `src/cli/show.rs:267-274`, `src/payload.rs:50-82` | — | no |
| 20 | `diff` discovers the project before validating the resource | cosmetic | `src/cli/diff.rs:86-92` | — | no |
| 21 | `simplify`'s payload pass ignores `source.tools` | defect | `src/cli/simplify.rs:340` | — | no |
| 22 | `resolve` off a terminal ignores its tool filter and exits 0 | defect | `src/cli/resolve.rs:42-53` | `src/cli/resolve.rs:242` | no |
| 23 | `yaml_remove_key` swallows the blank lines after the block | cosmetic | `src/yaml_edit.rs:229-249` | `src/yaml_edit.rs:456` | no |
| 24 | `resolve` clears `.pending-resolutions.yaml` off a terminal | defect | `src/cli/resolve.rs:28-41` | `src/cli/resolve.rs:223` | no |
| 25 | `simplify --apply` off a terminal: payload deleted, emptied override kept | defect | `src/cli/simplify.rs:292` vs `:462` | — | yes (scripts) |
| 26 | `profile add --tools` keeps spaces and accepts unknown slugs | defect | `src/cli/profile.rs:184-192` | — | no |
| 27 | `profile add` writes `tools: [a,b]` without spaces | cosmetic | `src/cli/profile.rs:307` | — | no |
| 28 | `profile add <name> --tools` with no value exits 1 in silence | defect | `src/cli/profile.rs:122-129` | `src/cli/profile.rs:669` | no |
| 29 | `profile remove` deletes an adopted config home | defect | `src/cli/profile.rs:356-403`, `:509-518` | — | no |
| 30 | `upgrade-config` rewrites every pin line and ignores the env var | defect | `src/cli/upgrade_config.rs:17-29`, `:59-64` | `src/cli/upgrade_config.rs:108` (rewrite half only) | yes (env-var users) |
| 31 | `dedupe` prunes an emptied category directory, not just skill folders | defect | `src/cli/dedupe.rs:432-451` | — | no |
| 32 | `dedupe` ignores `AGENTSYNC_CONFIG_PATH` for `shared.path` and declines | defect | `src/cli/dedupe.rs:160-167` | — | yes (env-var users) |
| 33 | `adopt` of a merged `.rules` says "not a recognised output" | defect | `src/cli/adopt.rs:213-224` | — | no |
| 34 | `adopt --all` prints `✓ adopted` once per destination | cosmetic | `src/cli/adopt.rs:834-848` | — | no |
| 35 | `migrate --apply --yes` omits the blank line before `Planned moves:` | cosmetic | `src/cli/migrate.rs:528-552` | `src/cli/migrate.rs:908` | no |
| 36 | An extension-less legacy file moves to `tools/README/settings.README` | defect | `src/cli/migrate.rs:255-264`, `:223-228` | `src/cli/migrate.rs:893` | yes (rare) |
| 37 | Off-terminal `migrate --apply` consolidates MCP but keeps `.agent/` | defect | `src/cli/migrate.rs:514-527` vs `:598-609` | `src/cli/migrate.rs:946` | yes |
| 38 | `refresh` heals the manifest outside `--only` and the AGENTS.md gate | compatibility | `src/cli/refresh.rs:260`, `:453`, `src/template_manifest.rs:70-87` | `src/cli/refresh.rs:1420` | yes |
| 39 | Off-terminal `refresh` applies auto-updates without `--yes` | defect | `src/cli/refresh.rs:324-353` | — | yes |
| 40 | `refresh` ignores `AGENTSYNC_CONFIG_PATH` for `template_overrides` | defect | `src/cli/refresh.rs:619-641` | — | no |
| 41 | A file-typed `.clinerules` aborts `init` at the backup step | defect | `src/cli/init.rs:750-770`, `src/backup.rs:130-158` | — | no |
| 42 | `init` strips spaces inside a token; empty flags skip the wizard | defect | `src/cli/init.rs:641-651`, `:298-301` | `src/cli/init.rs:1632` (boundaries only) | no |
| 43 | `init` heals the manifest before adopting, masking the adoption | defect | `src/cli/init.rs:942-954` | — | yes |
| 44 | `doctor` reports only the first matching pattern's lines | defect | `src/cli/doctor.rs:144-165` | `src/cli/doctor.rs:1302` | no |
| 45 | `doctor` drops any line holding `${…}`, or `<…>` without `sk-` | defect | `src/cli/doctor.rs:150-159` | `src/cli/doctor.rs:1318` | no |
| 46 | `add mcp` re-emits only `mcpServers`, dropping other members | defect | `src/cli/add.rs:425-433`, `:490-501` | `src/cli/add.rs:815`, `:830` | yes, if such a file exists |
| 47 | `add mcp` takes the first `"mcpServers"` anywhere in the file | defect | `src/cli/add.rs:425-426`, `:444-446` | `src/cli/add.rs:846` | no |
| 48 | `add mcp` stops at the first non-string key and drops the rest | defect | `src/cli/add.rs:452-476` | `src/cli/add.rs:833` | no |
| 49 | `add mcp` creates the file before validating `--env`; flags read one line | defect | `src/cli/add.rs:606-620`, `:249-250` | — | no |
| 50 | `import` strips `.git` before the trailing `/` | defect | `src/cli/bundle.rs:634-636` | — | no |
| 51 | A directory `import` copies `.ai/` alone, missing `source:` overrides | defect | `src/cli/bundle.rs:742-744` | — | no |
| 52 | `generate` exits 1 in silence when stdin closes | cosmetic | `src/cli/generate.rs:113-115`, `:140-142` | `src/cli/generate.rs:247` | no |
| 53 | `setup-hooks` refuses an unknown option before honouring `--help` | cosmetic | `src/cli/setup_hooks.rs:188-203` | `src/cli/setup_hooks.rs:373` | no |
| 54 | `release` exits 1 in silence when stdin ends at the prompt | cosmetic | `src/cli/release.rs:285-289` | `src/cli/release.rs:555` | no |
| 55 | The changelog renderer matches a `## <version>` heading by prefix | defect | `src/changelog.rs:144-157` | `src/changelog.rs:273` | no |

## Recommended order of work

### Group A — ships in a patch release, do these first

Two items, one change. `doctor` is a scanner: the fix moves only diagnostic text.

- **45**, then **44** (`src/cli/doctor.rs:144-165`). 45 is the dangerous half: a real `ghp_` token on the same line as an unrelated `${GITHUB_TOKEN}` is reported as clean. 44 hides a second secret behind pattern order. Scope the placeholder exclusion to the matched span and union hits across all patterns; update `src/cli/doctor.rs:1292-1329`. A tool whose job is finding secrets and which silently finds none is the only item on this list that can cost a user something.

### Group B — ships in a minor release, no generated output moves

Ordered by user-visible payoff. Each writes its pinning test first where the test column reads `—`.

1. **55** — `## 9.9.90` renders under `9.9.9` and the section never ends. `src/changelog.rs:144-157`; match the heading exactly or require the next byte to be whitespace.
2. **24 and 22** — `resolve` off a terminal both mutates `.pending-resolutions.yaml` and ignores its filter while claiming to be read-only. One commit in `src/cli/resolve.rs:28-53`; both are pinned, so both tests change.
3. **21** — `simplify`'s payload pass reads a literal `.ai/src/tools` where `project.user_tools_dir()` exists one line away. A one-line fix with a missing test.
4. **50** — swap the two `strip_suffix` calls at `src/cli/bundle.rs:634-635`.
5. **28, 26** — `profile add` fails silently on a valueless `--tools` and writes `.ai/src/tools/ codex-hub.yaml` for `'claude, codex'`. `src/cli/profile.rs:122-192`.
6. **18, 19, 33, 12, 17** — the misleading-report cluster: a typo'd slug reads as "nothing to diff", a real override reads as `base`, a Zed `.rules` adoption reads as "not a recognised output", the fan-out calls its last failure the max, and `disable` reports unknown slugs as disabled. Five small commits, all console-only.
7. **31, 41, 42, 47, 48, 49, 51, 29** — the long tail. Each is real and each is cheap; none is urgent. 41 turns an opaque `Backup target parent is not a directory` into an actionable message and is the most likely of these to reach a user.

### Group C — one change, scoped blast radius

**14, 30, 32, 40** — four commands search `.ai/agent_sync.yaml` then `agent_sync.yaml` by hand and ignore `AGENTSYNC_CONFIG_PATH`, against the invariant `src/project.rs:19` states. Route all four through `Project`'s resolution in one change. It changes which file `enable`, `disable`, `upgrade-config`, `dedupe` and `refresh` read and write **only for projects that set the variable** — for everyone else the resolved path is identical. That scoping is a judgement call the maintainer should ratify rather than a rule the table can settle: a minor release is defensible, a major is safer. **Recommended:** minor, with the change named in the CHANGELOG under `### Fixed`.

Item **15** (`disable` creating a config file in a project that had none) belongs to the same module and should ride along, though it changes output for every user, not only env-var users.

### Group D — queued behind a major version

Do not schedule these; attach them to a major when one is cut for another reason. Each changes files in an existing project.

- **1, 2, 13** — the YAML reader. Every config read in the engine sits on it.
- **4** — the tool config layering rule; touches every field of every tool.
- **9, 10, 11** — the three that change generated content: the frontmatter field read, the `paths:` CSV that feeds `.cursor/rules/*.mdc` globs, and the `>-` skill description. Highest user-visible payoff of the four groups and the reason a major is worth cutting.
- **16, 36, 37, 39, 43, 25, 46** — the write-path items. **43** is the one to lead with: `init` heals the manifest before adopting, so a user's adopted `AGENTS.md` is masked from `refresh` as a silently-kept edit on the most common first-run path there is.

## Not recommended — leave these alone

- **Items 3, 6, 20, 23, 27, 34, 35, 52, 53, 54 (all ten cosmetic items).** Display spacing, log wording, a duplicate `✓ adopted` line, a blank line before `Planned moves:`, `[a,b]` without spaces, and three commands that exit 1 in silence when stdin closes. Every one is pinned or trivially pinnable, none has a functional effect, and each fix is a diff a reviewer must read for no benefit a user will notice. Fix one only when the surrounding code is open for another reason.
- **Item 2 — the `#` comment rule.** It has been the config format's rule since the first release. Changing it lengthens any existing unquoted value containing a `#` — URLs with fragments, most of all — silently and without a migration path. The correct response is documentation, not a code change.
- **Item 7 — the `gitignore.update: false` → `committed` inference.** The de-duplication into one helper is worth doing (no blast radius, removes a live three-way drift risk), but the inference itself should stay: removing it flips a project that relies on it from `committed` to `local` outputs, which is the single most disruptive change on this list. If it must go, it goes with an explicit `outputs:` migration that `doctor` reports.
- **Item 38 — `refresh` healing outside `--only`.** Deliberately documented at `src/template_manifest.rs:70-87` and pinned at `src/cli/refresh.rs:1420`. Restricting it would rewrite `.ai/.template-manifest` — a committed file in the team workflow — on the next scoped `refresh` for every project that runs one. The healing is what keeps the manifest honest; scoping it buys nothing.
- **Item 5 — the unread `defaults:` keys.** Wiring them up changes which tools sync for anyone who set the inert keys, and the shipped `lib/config.yaml:11-13` itself carries `enabled: false`. The right fix is the opposite direction: delete the dead block from `lib/config.yaml` and the dead key from the documentation so nothing looks configurable that is not. That is the only version of this change with no blast radius.
- **Item 48** — reachable only through JSON that is already invalid under RFC 8259 (a non-string object key). Fix it only alongside 46 and 47, never on its own.

## Found after the triage

- **A target switched off keeps its last file, and `check` stays green.**
  Disabling `targets.<name>.enabled` stops the pass, so nothing prunes what the
  pass wrote, and `manifest::write` keeps an entry it did not touch. The file
  therefore stays on disk, stays claimed by the manifest, and never changes
  again while `agentsync check` reports the project as synced. Found on
  2026-09-20 while documenting the `AGENTS.md` setup for Claude Code, where a
  leftover `CLAUDE.md` silently wins over the `AGENTS.md` the user switched to.
  Deleting the file resolves it: `check` passes immediately and the next `sync`
  drops the entry.
  *Classification:* defect. *Blast radius:* a fix that prunes the file changes
  behaviour for anyone who disabled a target in order to freeze its output, so
  it needs the same major-versus-minor judgement as the rest of this list. The
  README documents the deletion step in the meantime.
  *Decided 2026-09-28:* sync still leaves the file, and `check` and `doctor`
  name it without changing their exit status (`src/cli/stale_targets.rs`).
- **Group C, 2026-09-28.** 14, 30, 32 and 40 route through the project's
  config resolution, and 15 rides along, ratified for a minor release. 30
  keeps rewriting every top-level `agentsync_version:` line on purpose.
- **The list is closed, 2026-09-28.** Of the 55 items, 49 are fixed, 5 are
  kept with the reason in the spec (2, 3, 7, 37, 38), and 8 stays struck. The
  cosmetic items and 5 and 7 ship with Groups A to C; Group D, 47, 48 and 51
  change what an existing project reads or writes and wait for a major
  release. 47 went in with 46 as planned above, and 51 became the design
  change described there: every import reads the declared `source.*` paths
  and drops the ones the target project would not have.
- **Group B status, 2026-09-28.** 12, 17, 18, 19, 21, 26, 28, 29, 31, 33, 41,
  42, 45 (its `<…>` half), 49 and 50 are fixed; the spec strikes each. Two
  items were left on purpose:
  - **47 waits for 46.** Finding only a top-level `mcpServers` turns a file
    whose only `mcpServers` is nested from today's `Malformed` refusal into
    the "no key" branch, which replaces the file and drops its other members.
    Today's refusal is the safer of the two until 46 keeps those members.
  - **51 is a design change, not a copy.** `plan_import` reads every section
    from `<source>/.ai/src/<section>` for archives and directories alike, so
    no import honours `source.*`, and the imported `agent_sync.yaml` keeps
    `source.*` paths the target project does not have. A fix has to choose
    between rewriting those keys and recreating the declared paths.
