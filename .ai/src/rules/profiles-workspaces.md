---
paths:
  - "lib/helpers/profile*.sh"
  - "lib/helpers/profiles.sh"
  - "lib/helpers/shared.sh"
  - "lib/helpers/dedupe.sh"
  - "lib/helpers/doctor.sh"
  - "lib/helpers/paths.sh"
  - "lib/sync.sh"
  - ".ai/**"
---

# Profiles and Workspaces

Profiles, shared inheritance, and workspace commands reuse the same overlay and
path-containment primitives. Keep their ordering and cleanup semantics aligned.

## Profiles

- Model a profile as a thin variant tool with `base: <tool>` plus a source overlay; keep format and behavior inherited from the base.
- Derive config-home destinations with `profile_rewrite_dest`. Preserve nested structure instead of reducing paths to `basename`.
- Compose overlays in order: child/base source → optional shared source → profile source, with the most specific source winning.
- Restore `BASE_SOURCE_*` before every profile pass and tear down each overlay before the next pass.
- Protect every configured profile destination from cleanup even when that profile is inactive.
- Remove config-home output and variant files before deleting the profile config entry so output never becomes orphaned.

## Workspaces

- Bound parent discovery to the current git repository unless `shared.path` explicitly names another root.
- Order workspace projects bottom-up and `LC_ALL=C` alphabetical so runs are reproducible.
- Reuse `find_parent_ai_src` and `find_workspace_ai_dirs`; keep walk semantics out of command-local implementations.
- Keep doctor advisories exit-code zero. Reserve warnings for actionable setup problems and failures for invalid or missing required state.
