#!/usr/bin/env bats
# Tests for agentsync add <kind> <name>.

load test_helper

setup_file() { seed_project; }
teardown_file() { teardown_seed_project; }
setup() { clone_seed; }
teardown() { teardown_test_project; }

# ── Happy paths ───────────────────────────────────────────────────────────────

@test "add rule creates .ai/src/rules/<name>.md" {
    run run_agentsync add rule testing
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/testing.md" ]
    grep -q "^# Testing$" .ai/src/rules/testing.md
}

@test "add skill creates .ai/src/skills/<name>/SKILL.md" {
    run run_agentsync add skill deploy
    [ "$status" -eq 0 ]
    [ -f ".ai/src/skills/deploy/SKILL.md" ]
    grep -q '^name: "deploy"$' .ai/src/skills/deploy/SKILL.md
    grep -q "^description:" .ai/src/skills/deploy/SKILL.md
}

@test "add command creates .ai/src/commands/<name>.md with description frontmatter" {
    run run_agentsync add command deploy
    [ "$status" -eq 0 ]
    [ -f ".ai/src/commands/deploy.md" ]
    grep -q "^description:" .ai/src/commands/deploy.md
}

@test "add subagent creates .ai/src/agents/<name>.md" {
    run run_agentsync add subagent reviewer
    [ "$status" -eq 0 ]
    [ -f ".ai/src/agents/reviewer.md" ]
    grep -q '^name: "reviewer"$' .ai/src/agents/reviewer.md
    grep -q "^tools:" .ai/src/agents/reviewer.md
}

@test "add prints next-step hint" {
    run run_agentsync add rule testing
    [ "$status" -eq 0 ]
    [[ "$output" == *"agentsync sync"* ]]
}

# ── Rejections ────────────────────────────────────────────────────────────────

@test "add with no args fails with usage" {
    run run_agentsync add
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
    [[ "$output" == *"<kind>"* ]]
}

@test "add with only kind fails with usage" {
    run run_agentsync add rule
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "add rejects unknown kind" {
    run run_agentsync add banana myname
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown kind"* ]]
}

@test "add rejects name with slash" {
    run run_agentsync add rule "sub/dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path separators"* ]]
    [ ! -e ".ai/src/rules/sub" ]
}

@test "add rejects name with .." {
    run run_agentsync add rule "..evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'..'"* ]] || [[ "$output" == *"cannot start with"* ]]
}

@test "add rejects name with relative traversal" {
    run run_agentsync add rule "../evil"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path separators"* ]]
}

@test "add rejects name starting with dot" {
    run run_agentsync add rule ".hidden"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot start with"* ]]
}

@test "add rejects name with space" {
    run run_agentsync add rule "my rule"
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, digits"* ]]
}

@test "add rejects name with extension" {
    run run_agentsync add rule "testing.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, digits"* ]]
}

# ── Existing-file behavior ────────────────────────────────────────────────────

@test "add refuses existing file without --force" {
    run_agentsync add rule testing >/dev/null
    run run_agentsync add rule testing
    [ "$status" -ne 0 ]
    [[ "$output" == *"Already exists"* ]]
    [[ "$output" == *"--force"* ]]
}

@test "add --force overwrites existing file" {
    run_agentsync add rule testing >/dev/null
    echo "custom content" > .ai/src/rules/testing.md

    run run_agentsync add --force rule testing
    [ "$status" -eq 0 ]
    ! grep -q "custom content" .ai/src/rules/testing.md
    grep -q "^# Testing$" .ai/src/rules/testing.md
}

@test "add --force works with -f short flag" {
    run_agentsync add rule testing >/dev/null
    run run_agentsync add -f rule testing
    [ "$status" -eq 0 ]
}

@test "add refuses existing skill directory without --force" {
    run_agentsync add skill deploy >/dev/null
    run run_agentsync add skill deploy
    [ "$status" -ne 0 ]
    [[ "$output" == *"Already exists"* ]]
}

# ── Name-shape sanity ─────────────────────────────────────────────────────────

@test "add accepts kebab-case name" {
    run run_agentsync add rule "my-rule"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/my-rule.md" ]
}

@test "add accepts snake_case name" {
    run run_agentsync add rule "my_rule"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/my_rule.md" ]
}

@test "add accepts digits in name" {
    run run_agentsync add rule "rule42"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/rules/rule42.md" ]
}

@test "add substitutes name into skill frontmatter" {
    run run_agentsync add skill my-skill
    [ "$status" -eq 0 ]
    grep -q '^name: "my-skill"$' .ai/src/skills/my-skill/SKILL.md
    grep -q "^# My Skill$" .ai/src/skills/my-skill/SKILL.md
}

# ── add mcp ───────────────────────────────────────────────────────────────────

@test "add mcp creates .ai/src/mcp.json on first run" {
    [ ! -f ".ai/src/mcp.json" ]
    run run_agentsync add mcp github --command "npx @github/mcp-server"
    [ "$status" -eq 0 ]
    [ -f ".ai/src/mcp.json" ]
    python3 -c "import json,sys; d=json.load(open('.ai/src/mcp.json')); \
                assert 'github' in d['mcpServers']; \
                assert d['mcpServers']['github']['command'] == 'npx @github/mcp-server'"
}

@test "add mcp appends a second server without touching the first" {
    run_agentsync add mcp github --command "npx @github/mcp-server" >/dev/null
    run run_agentsync add mcp linear --url "https://mcp.linear.app/sse"
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json')); \
                assert 'github' in d['mcpServers']; \
                assert 'linear' in d['mcpServers']; \
                assert d['mcpServers']['linear']['type'] == 'http'; \
                assert d['mcpServers']['linear']['url'] == 'https://mcp.linear.app/sse'"
}

@test "add mcp parses --args into a list" {
    run run_agentsync add mcp fs --command "fs-server" --args "--root /tmp --debug"
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json')); \
                assert d['mcpServers']['fs']['args'] == ['--root','/tmp','--debug']"
}

@test "add mcp parses --env pairs into a map" {
    run run_agentsync add mcp gh --command "gh-mcp" --env "TOKEN=abc,DEBUG=1"
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json')); \
                env=d['mcpServers']['gh']['env']; \
                assert env['TOKEN']=='abc' and env['DEBUG']=='1'"
}

@test "add mcp refuses duplicate server without --force" {
    run_agentsync add mcp gh --command "gh-mcp" >/dev/null
    run run_agentsync add mcp gh --command "other"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json')); \
                assert d['mcpServers']['gh']['command']=='gh-mcp'"
}

@test "add mcp --force overwrites existing entry" {
    run_agentsync add mcp gh --command "gh-mcp" >/dev/null
    run run_agentsync add mcp gh --command "other" --force
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json')); \
                assert d['mcpServers']['gh']['command']=='other'"
}

@test "add mcp requires --url or --command" {
    run run_agentsync add mcp gh
    [ "$status" -ne 0 ]
    [[ "$output" == *"--url or --command"* ]]
}

@test "add mcp rejects both --url and --command" {
    run run_agentsync add mcp gh --url "https://example" --command "foo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "add mcp rejects invalid server name" {
    run run_agentsync add mcp "bad/name" --command "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"path separators"* ]]
}

@test "add mcp overwrites a middle server without disturbing its siblings" {
    run_agentsync add mcp aaa --command "cmd-a" >/dev/null
    run_agentsync add mcp bbb --command "cmd-b" --args "x y" >/dev/null
    run_agentsync add mcp ccc --url "https://c" >/dev/null
    run run_agentsync add mcp bbb --command "cmd-b2" --force
    [ "$status" -eq 0 ]
    python3 -c "import json; d=json.load(open('.ai/src/mcp.json'))['mcpServers']; \
                assert list(d) == ['aaa','bbb','ccc']; \
                assert d['bbb']['command'] == 'cmd-b2' and 'args' not in d['bbb']; \
                assert d['aaa']['command'] == 'cmd-a'; \
                assert d['ccc']['type'] == 'http'"
}

@test "add mcp JSON-escapes quotes and backslashes in values" {
    run run_agentsync add mcp weird --command 'say "hi" path\to' --env 'MSG=a"b'
    [ "$status" -eq 0 ]
    python3 -c "import json; e=json.load(open('.ai/src/mcp.json'))['mcpServers']['weird']; \
                assert e['command'] == 'say \"hi\" path\\\\to'; \
                assert e['env']['MSG'] == 'a\"b'"
}

@test "add mcp attaches env to an http server" {
    run run_agentsync add mcp h --url "https://x" --env "TOKEN=t"
    [ "$status" -eq 0 ]
    python3 -c "import json; e=json.load(open('.ai/src/mcp.json'))['mcpServers']['h']; \
                assert e['type']=='http' and e['url']=='https://x' and e['env']['TOKEN']=='t'"
}

@test "add mcp output is valid JSON parseable across repeated edits" {
    run_agentsync add mcp one --command "c1" >/dev/null
    run_agentsync add mcp two --command "c2" --args "a b c" --env "K=v" >/dev/null
    run_agentsync add mcp three --url "https://three" >/dev/null
    run python3 -c "import json; json.load(open('.ai/src/mcp.json'))"
    [ "$status" -eq 0 ]
}
