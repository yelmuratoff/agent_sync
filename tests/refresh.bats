#!/usr/bin/env bats
# Tests for agentsync refresh (v2 — three-way diff via .ai/.template-manifest).

load test_helper

setup() {
    setup_test_project
    run run_agentsync init --yes --no-detect --content rules,skills,commands,subagents
    [ "$status" -eq 0 ]
}

teardown() {
    teardown_test_project
}

# Remove a single relative-path entry from the template manifest. Lets a test
# simulate "this template is brand new — the user has never seen it" by
# pretending init never recorded it.
_drop_manifest() {
    local rel="$1"
    [[ -f .ai/.template-manifest ]] || return 0
    local tmp
    tmp="$(mktemp)"
    grep -v $'^'"$rel"$'\t' .ai/.template-manifest > "$tmp" || true
    mv "$tmp" .ai/.template-manifest
}

# Drop every manifest entry whose rel-path begins with a prefix. Used to
# simulate "this whole category is brand-new in the CLI" so refresh classifies
# missing files as NEW (not DELETED).
_drop_manifest_prefix() {
    local prefix="$1"
    [[ -f .ai/.template-manifest ]] || return 0
    local tmp
    tmp="$(mktemp)"
    grep -v $'^'"$prefix" .ai/.template-manifest > "$tmp" || true
    mv "$tmp" .ai/.template-manifest
}

# ── basics ───────────────────────────────────────────────────────────────────

@test "refresh: --help prints usage" {
    run run_agentsync refresh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync refresh"* ]]
    [[ "$output" == *"--only"* ]]
    [[ "$output" == *"--include-agents-md"* ]]
    [[ "$output" == *"--include-deleted"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"PERSISTENT OVERRIDES"* ]]
}

@test "refresh: errors when no .ai/ directory" {
    rm -rf .ai
    run run_agentsync refresh --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"No .ai/"* ]]
}

@test "refresh: rejects unknown --only value" {
    run run_agentsync refresh --yes --only bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown --only"* ]]
}

@test "refresh: errors when no source categories present and no --only" {
    rm -rf .ai/src/rules .ai/src/skills .ai/src/commands .ai/src/agents
    run run_agentsync refresh --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"No source content categories"* ]]
}

@test "refresh: non-TTY without --yes errors with hint when changes pending" {
    rm -f .ai/src/rules/comments.md
    _drop_manifest "rules/comments.md"
    run run_agentsync refresh
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes"* ]]
}

# ── manifest baseline ────────────────────────────────────────────────────────

@test "init: writes template manifest with file hashes" {
    [ -f .ai/.template-manifest ]
    grep -q $'^rules/core.md\t' .ai/.template-manifest
    grep -q $'^skills/agentsync/SKILL.md\t' .ai/.template-manifest
    # Hash column non-empty
    awk -F'\t' 'NF>=2 && length($2)==64 {n++} END{exit !(n>0)}' .ai/.template-manifest
}

# ── three-way diff: AUTO_UPDATE ──────────────────────────────────────────────

@test "refresh: untouched file + missing-from-manifest + matching-template = unchanged" {
    # Drop manifest entry so file is unrecorded; user has the same content as
    # template — should classify as UNCHANGED (not NEW).
    _drop_manifest "rules/core.md"
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already up to date"* ]] || [[ "$output" == *"Done."* ]]
}

@test "refresh: NEW template (no manifest entry, file absent) is added with --yes" {
    rm -f .ai/src/rules/comments.md
    _drop_manifest "rules/comments.md"
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
    # And manifest now records it.
    grep -q $'^rules/comments.md\t' .ai/.template-manifest
}

@test "refresh: USER_EDITED_NO_CHANGE is silent (user edits, template unchanged)" {
    echo "USER LOCAL EDIT" >> .ai/src/rules/core.md
    local before
    before=$(cat .ai/src/rules/core.md)
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ "$(cat .ai/src/rules/core.md)" = "$before" ]
    # Output must NOT report a conflict — template hasn't moved.
    [[ "$output" != *"conflict"* ]]
}

# ── deleted (skip-as-decline + restore) ──────────────────────────────────────

@test "refresh: file removed locally is silent without --include-deleted" {
    rm -f .ai/src/rules/comments.md
    # Manifest entry for comments.md is preserved (init wrote it).
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/rules/comments.md ]
    [[ "$output" == *"Already up to date"* ]] || [[ "$output" == *"Done."* ]]
}

@test "refresh: --include-deleted lists previously declined files in dry-run" {
    rm -f .ai/src/rules/comments.md
    run run_agentsync refresh --include-deleted --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"rules/comments.md"* ]]
    [[ "$output" == *"declined"* ]] || [[ "$output" == *"deleted"* ]]
    [ ! -f .ai/src/rules/comments.md ]
}

@test "refresh: --include-deleted with --yes still skips restoration (interactive only)" {
    rm -f .ai/src/rules/comments.md
    run run_agentsync refresh --yes --include-deleted
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/rules/comments.md ]
    [[ "$output" == *"declined"* ]] || [[ "$output" == *"skipped"* ]]
}

# ── overrides ────────────────────────────────────────────────────────────────

@test "refresh: declined override skips template entirely" {
    cat >> .ai/agent_sync.yaml <<'EOF'

template_overrides:
  declined:
    - rules/comments.md
EOF
    rm -f .ai/src/rules/comments.md
    _drop_manifest "rules/comments.md"
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/rules/comments.md ]
    # Declined entries don't surface in the summary list.
    [[ "$output" != *"+ rules/comments.md"* ]]
}

@test "refresh: pinned override silences conflict on user-edited file when template moves" {
    cat >> .ai/agent_sync.yaml <<'EOF'

template_overrides:
  pinned:
    - rules/core.md
EOF
    # Make user file diverge from manifest baseline (i.e. they edited).
    echo "USER LOCAL EDIT" >> .ai/src/rules/core.md
    # Drop manifest entry for core.md to also make t_old absent (covers the
    # "no baseline" branch that would otherwise classify as CONFLICT).
    _drop_manifest "rules/core.md"
    local before
    before=$(cat .ai/src/rules/core.md)
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ "$(cat .ai/src/rules/core.md)" = "$before" ]
    [[ "$output" != *"conflict"* ]]
}

# ── flags / scope ────────────────────────────────────────────────────────────

@test "refresh: --dry-run does not write" {
    rm -f .ai/src/rules/comments.md
    _drop_manifest "rules/comments.md"
    run run_agentsync refresh --dry-run
    [ "$status" -eq 0 ]
    [ ! -f .ai/src/rules/comments.md ]
    [[ "$output" == *"Dry run"* ]]
}

@test "refresh: --only filters by category" {
    rm -f .ai/src/rules/comments.md
    rm -rf .ai/src/skills/comments
    _drop_manifest "rules/comments.md"
    _drop_manifest "skills/comments/SKILL.md"
    run run_agentsync refresh --yes --only rules
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
    [ ! -d .ai/src/skills/comments ]
}

@test "refresh: --only subagents alias maps to agents dir" {
    rm -rf .ai/src/agents
    _drop_manifest_prefix "agents/"
    run run_agentsync refresh --yes --only subagents
    [ "$status" -eq 0 ]
    [ -d .ai/src/agents ]
}

@test "refresh: --only=value form (= separator)" {
    rm -f .ai/src/rules/comments.md
    rm -rf .ai/src/skills/comments
    _drop_manifest "rules/comments.md"
    _drop_manifest "skills/comments/SKILL.md"
    run run_agentsync refresh --yes --only=rules
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/comments.md ]
    [ ! -d .ai/src/skills/comments ]
}

@test "refresh: idempotent — second run reports up to date" {
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already up to date"* ]]
}

@test "refresh: AGENTS.md excluded by default" {
    echo "USER LOCAL EDIT" >> .ai/src/AGENTS.md
    local before
    before=$(cat .ai/src/AGENTS.md)
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ "$(cat .ai/src/AGENTS.md)" = "$before" ]
}

@test "refresh: --include-agents-md surfaces AGENTS.md but conflict still skipped under --yes" {
    echo "USER LOCAL EDIT" >> .ai/src/AGENTS.md
    _drop_manifest "AGENTS.md"
    local before
    before=$(cat .ai/src/AGENTS.md)
    run run_agentsync refresh --yes --include-agents-md
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENTS.md"* ]]
    [ "$(cat .ai/src/AGENTS.md)" = "$before" ]
}

@test "refresh: leaves user's custom files alone (not in templates)" {
    cat > .ai/src/rules/my-custom.md <<'EOF'
# My Custom Rule
Custom content.
EOF
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/src/rules/my-custom.md ]
    grep -q "My Custom Rule" .ai/src/rules/my-custom.md
}

@test "refresh: scope auto-detection skips categories absent from .ai/src/" {
    rm -rf .ai/src/commands .ai/src/agents
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ ! -d .ai/src/commands ]
    [ ! -d .ai/src/agents ]
    [ -f .ai/src/rules/core.md ]
    [ -d .ai/src/skills ]
}

@test "refresh: explicit --only opts into a category not yet in tree" {
    rm -rf .ai/src/commands
    _drop_manifest_prefix "commands/"
    run run_agentsync refresh --yes --only commands
    [ "$status" -eq 0 ]
    [ -d .ai/src/commands ]
    local count
    count=$(ls -1 .ai/src/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -ge 1 ]
}

@test "refresh: nested skill references files added when missing (NEW)" {
    rm -rf .ai/src/skills/agentsync/references
    # init was shallow on skill subdirs — references aren't in manifest yet.
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/src/skills/agentsync/references/maintenance.md ] || \
    [ -f .ai/src/skills/agentsync/references/writing-skills.md ]
}

# ── manifest semantics under --yes ───────────────────────────────────────────

@test "refresh: --yes records new manifest entries when adding NEW files" {
    rm -f .ai/src/rules/comments.md
    _drop_manifest "rules/comments.md"
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    grep -q $'^rules/comments.md\t' .ai/.template-manifest
}

@test "refresh: backward compat — works on project with no manifest at all" {
    rm -f .ai/.template-manifest
    # Modify a file so refresh has to make a decision.
    echo "USER LOCAL EDIT" >> .ai/src/rules/core.md
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    # Without a manifest baseline, a divergence is treated as a CONFLICT and
    # --yes skips it; user's edit is preserved.
    grep -q "USER LOCAL EDIT" .ai/src/rules/core.md
}

@test "refresh: heals manifest from current matches when no manifest existed" {
    rm -f .ai/.template-manifest
    run run_agentsync refresh --yes
    [ "$status" -eq 0 ]
    [ -f .ai/.template-manifest ]
    grep -q $'^rules/core.md\t' .ai/.template-manifest
}
