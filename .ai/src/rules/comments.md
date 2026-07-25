# Comments

A comment earns its place when it captures something the code itself cannot show — a hidden constraint, an external quirk, a workaround, or a surprise the reader would otherwise question. Everything else lives in the code.

## The test

Read the line without the comment. If a competent reader still understands the code, leave the comment out. Reach for a sharper identifier (`isExpired` beats `// check if expired`) or a smaller function before reaching for prose.

## Where a comment helps

- **Hidden constraint** — a non-obvious invariant, ordering requirement, performance assumption, or external API quirk.
- **Workaround** — a fix for a specific upstream bug or platform behaviour. Name the system, link the issue when you have one.
- **Surprise** — behaviour that would make a reasonable reader pause ("why is this list reversed?", "why catch this error silently?").
- **Public API contract** — inputs, outputs, errors, side effects — via the language's doc-comment syntax (`///`, `/** */`, docstrings). Internal helpers stay quiet unless they hide a constraint.

## Style

- Describe *why*, not *what*. The code shows the mechanism; the comment supplies the reason.
- One line where possible. A paragraph usually signals the surrounding code wants splitting or renaming.
- Single space after the marker: `# like this`.
- Match the file's existing density and tone — scan 5–10 nearby files before changing the style.
- Pair every `TODO` / `FIXME` with an owner or a tracked issue, or resolve it now.
- Delete unused and commented-out code; git keeps the history.

## Examples

```bash
# Sharper name beats a narrating comment:
- # check if a path is safe
- if [[ "$path" == "$root/"* ]]; then ...
+ local is_safe_path=false
+ [[ "$path" == "$root/"* ]] && is_safe_path=true
+ if [[ "$is_safe_path" == "true" ]]; then ...

# Step markers and narration belong in the diff, not the file:
- # Step 1: collect tools
- tools=$(list_tools)
- # loop through tools
- for tool in $tools; do ...
+ tools=$(list_tools)
+ for tool in $tools; do ...

# A real "why" comment earns its keep:
+ # Bash 3.2 has no mapfile; preserve empty lines with a read loop.
+ while IFS= read -r line || [[ -n "$line" ]]; do ...

# Public helper comments capture non-obvious inputs, outputs, and side effects:
+ # Prints one canonical path per safe target; returns 1 for any path escape.
+ resolve_safe_targets() { ... }
```
