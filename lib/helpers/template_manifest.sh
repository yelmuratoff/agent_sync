#!/usr/bin/env bash
# Template manifest — content-addressed record of every template file copied
# into .ai/src/ via `agentsync init` or `agentsync refresh`. Lets `refresh`
# do three-way diffs (template_old vs template_new vs user_current), so files
# the user hasn't touched can be auto-updated, and only true conflicts
# require interactive review.
#
# Format: one line per file, "<rel-path>\t<sha256>", LC_ALL=C sorted.
# Path: $REPO_ROOT/.ai/.template-manifest. Commit to git so the team shares
# the same baseline (different developers should not see different conflicts).
#
# rel-path is relative to the user's source base (.ai/src/), e.g.
# "rules/foo.md" or "skills/agentsync/SKILL.md".

# Globals owned by this module (parallel arrays — bash 3.2 compatible).
TEMPLATE_MANIFEST_KEYS=()
TEMPLATE_MANIFEST_VALUES=()

# Resolve the manifest path. Honors AGENTSYNC_REPO_ROOT for tests / explicit
# overrides, falls back to PWD.
template_manifest_path() {
    local repo_root="${AGENTSYNC_REPO_ROOT:-$(pwd)}"
    echo "$repo_root/.ai/.template-manifest"
}

# Compute sha256 of a file. Echoes the bare hash on success; returns 1 if no
# hashing tool is available or the file is missing.
template_manifest_hash() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$file" 2>/dev/null) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    else
        return 1
    fi
    echo "${out%% *}"
}

# Load the manifest from disk into TEMPLATE_MANIFEST_{KEYS,VALUES}.
# Missing file is a no-op (empty manifest = "no baseline; treat all conflicts
# as manual review").
template_manifest_load() {
    TEMPLATE_MANIFEST_KEYS=()
    TEMPLATE_MANIFEST_VALUES=()
    local mfile
    mfile=$(template_manifest_path)
    [[ -f "$mfile" ]] || return 0

    local rel hash
    while IFS=$'\t' read -r rel hash || [[ -n "$rel" ]]; do
        [[ -z "$rel" ]] && continue
        [[ "$rel" == \#* ]] && continue
        [[ -z "$hash" ]] && continue
        TEMPLATE_MANIFEST_KEYS+=("$rel")
        TEMPLATE_MANIFEST_VALUES+=("$hash")
    done < "$mfile"
}

# Return the recorded hash for a relative path. Echoes the hash; exits 1 when
# no entry exists (caller should treat that as "no baseline").
template_manifest_lookup() {
    local key="$1"
    local i
    for ((i = 0; i < ${#TEMPLATE_MANIFEST_KEYS[@]}; i++)); do
        if [[ "${TEMPLATE_MANIFEST_KEYS[$i]}" == "$key" ]]; then
            echo "${TEMPLATE_MANIFEST_VALUES[$i]}"
            return 0
        fi
    done
    return 1
}

# Update or insert a single entry. In-memory only — call template_manifest_write
# to persist.
template_manifest_record() {
    local rel="$1" hash="$2"
    [[ -z "$rel" || -z "$hash" ]] && return 0

    local i
    for ((i = 0; i < ${#TEMPLATE_MANIFEST_KEYS[@]}; i++)); do
        if [[ "${TEMPLATE_MANIFEST_KEYS[$i]}" == "$rel" ]]; then
            TEMPLATE_MANIFEST_VALUES[$i]="$hash"
            return 0
        fi
    done
    TEMPLATE_MANIFEST_KEYS+=("$rel")
    TEMPLATE_MANIFEST_VALUES+=("$hash")
}

# Persist the in-memory manifest to disk atomically. Sort and dedupe via
# `sort -u` so output is byte-stable (identical input → identical file).
# Empty manifest removes the file rather than leaving an empty stub.
template_manifest_write() {
    local mfile
    mfile=$(template_manifest_path)
    mkdir -p "$(dirname "$mfile")"

    if [[ ${#TEMPLATE_MANIFEST_KEYS[@]} -eq 0 ]]; then
        rm -f "$mfile"
        return 0
    fi

    local tmp
    tmp=$(tmp_sibling "$mfile") || return 1
    : > "$tmp"
    local i
    for ((i = 0; i < ${#TEMPLATE_MANIFEST_KEYS[@]}; i++)); do
        printf '%s\t%s\n' "${TEMPLATE_MANIFEST_KEYS[$i]}" "${TEMPLATE_MANIFEST_VALUES[$i]}" >> "$tmp"
    done
    LC_ALL=C sort -u -o "$tmp" "$tmp"
    mv "$tmp" "$mfile"
}

# Walk a tree of templates and record manifest entries that mirror what was
# copied into the user's source dir. Used by `init` after scaffolding and as
# the "heal manifest" pass at the start of `refresh`.
#
# Args: <templates_dir> <user_src_base>
# Walks every .md file under templates_dir/{rules,commands,agents} and every
# non-hidden file under templates_dir/skills (and templates_dir/AGENTS.md).
# For each file that ALSO exists in
# user_src_base AND has matching content, records the template hash.
# Files that don't exist in user_src_base or differ are left out — the next
# refresh sees them as NEW or CONFLICT and prompts.
template_manifest_heal_from_match() {
    local templates_dir="$1"
    local user_base="$2"

    local rel src_path user_path src_hash user_hash

    # AGENTS.md
    if [[ -f "$templates_dir/AGENTS.md" && -f "$user_base/AGENTS.md" ]]; then
        src_hash=$(template_manifest_hash "$templates_dir/AGENTS.md") || src_hash=""
        user_hash=$(template_manifest_hash "$user_base/AGENTS.md") || user_hash=""
        if [[ -n "$src_hash" && "$src_hash" == "$user_hash" ]]; then
            template_manifest_record "AGENTS.md" "$src_hash"
        fi
    fi

    # Flat dirs
    local cat
    for cat in rules commands agents; do
        local tdir="$templates_dir/$cat"
        [[ -d "$tdir" ]] || continue
        local f
        for f in "$tdir"/*.md; do
            [[ -f "$f" ]] || continue
            rel="$cat/$(basename "$f")"
            src_path="$f"
            user_path="$user_base/$rel"
            [[ -f "$user_path" ]] || continue
            src_hash=$(template_manifest_hash "$src_path") || continue
            user_hash=$(template_manifest_hash "$user_path") || continue
            [[ "$src_hash" == "$user_hash" ]] && template_manifest_record "$rel" "$src_hash"
        done
    done

    # Skills (nested)
    if [[ -d "$templates_dir/skills" ]]; then
        local fpath
        while IFS= read -r -d '' fpath; do
            rel="${fpath#"$templates_dir/"}"
            user_path="$user_base/$rel"
            [[ -f "$user_path" ]] || continue
            src_hash=$(template_manifest_hash "$fpath") || continue
            user_hash=$(template_manifest_hash "$user_path") || continue
            [[ "$src_hash" == "$user_hash" ]] && template_manifest_record "$rel" "$src_hash"
        done < <(find "$templates_dir/skills" -type f ! -name '.*' -print0 2>/dev/null)
    fi
}
