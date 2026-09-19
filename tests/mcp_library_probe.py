#!/usr/bin/env python3
"""Development-only black-box JSON probe; Python is not a CLI dependency.

Compare synthetic manifests with a strict duplicate-rejecting stdlib decoder,
then check CLI acceptance and byte-exact `show`. No MCP servers are started.
Run: python3 tests/mcp_library_probe.py [--cli PATH]
"""

import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def strict_decode(raw):
    def reject_constant(value):
        raise ValueError(value)
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


def manifest():
    return {
        "schema_version": 1, "id": "probe", "title": "Probe",
        "provenance": {"homepage": "https://example.invalid"},
        "connection": {"type": "stdio", "command": "printf", "args": []},
        "requirements": {"binaries": [], "inputs": []},
    }


def cases():
    base = json.dumps(manifest(), separators=(",", ":"))
    yield "compact", base, True
    yield "pretty", json.dumps(manifest(), indent=4), True
    yield "crlf", json.dumps(manifest(), indent=2).replace("\n", "\r\n"), True
    yield "reordered", json.dumps(dict(reversed(list(manifest().items())))), True
    yield "escaped-schema-key", base.replace('"id":', '"\\u0069d":'), True
    yield "raw-nul-in-string", base.encode().replace(b'"Probe"', b'"raw\x00NUL"'), False
    yield "raw-nul-after-document", base.encode() + b"\x00garbage", False
    yield "raw-nul-before-document", b"\x00" + base.encode(), False
    for name, text in [
        ("duplicate-id", base.replace('"id":"probe"', '"id":"probe","id":"probe"')),
        ("escaped-key-duplicate", base.replace('"id":"probe"', '"id":"probe","\\u0069d":"probe"')),
        ("duplicate-nested", base.replace('"type":"stdio"', '"type":"stdio","type":"stdio"')),
        ("trailing-comma", base[:-1] + ",}"),
        ("trailing-document", base + "{}"),
        ("truncated", base[:-1]),
        ("invalid-escape", base.replace('"Probe"', '"bad\\q"')),
        ("unescaped-newline", base.replace('"Probe"', '"bad\ntext"')),
        ("invalid-number", base.replace('"schema_version":1', '"schema_version":01')),
        ("nan", base.replace('"schema_version":1', '"schema_version":NaN')),
        ("bad-whitespace", "\v" + base),
    ]:
        yield name, text, False
    strings = [
        "Unicode äöü 日本語 😀", 'spaces quotes " and \\ and /',
        "literal # not a comment", "line\nbreak\ttab\rcarriage",
        "\\u0061 is literal text", "$(touch SHOULD_NOT_EXIST); `false`",
        "NUL\0and\bbackspace\fformfeed", "A\u2028B\u2029C",
    ]
    rng = random.Random(731)
    alphabet = 'abc123 "\\/\n\t#ä中😀'
    strings += ["".join(rng.choice(alphabet) for _ in range(60)) for _ in range(20)]
    for index, value in enumerate(strings):
        data = manifest()
        data["description"] = value
        data["connection"]["args"] = [value, "", " space "]
        for ascii_only in [True, False]:
            yield f"string-{index}-ascii-{ascii_only}", json.dumps(data, ensure_ascii=ascii_only), True
    data = manifest()
    data["connection"] = {"type": "http", "url": "https://example.invalid/mcp"}
    yield "http", json.dumps(data), True
    data["schema_version"] = 2
    yield "v2-http-without-guidance", json.dumps(data), True
    data["alternatives"] = {"uvx": {
        "connection": {"type": "stdio", "command": "uvx",
                       "args": ["--from", "example-mcp==1.0.0", "example-mcp"]},
        "requirements": {"binaries": ["uvx"], "inputs": []}}}
    data["guidance"] = {"recommended": "default", "authority": "vendor",
                        "source": "https://example.invalid/docs",
                        "checked_at": "2026-09-16", "reason": "Synthetic fixture"}
    yield "v2-guidance-and-local-alternative", json.dumps(data), True
    extension_base = base[:-1] + ',"extensions":{"example.invalid":EXT}}'
    yield "opaque-extension", extension_base.replace("EXT", '[null,true,false,1,-2.5e3,{"x":[{}]}]'), True
    for name, value in [
        ("duplicate-unicode-key", '{"é":1,"\\u00e9":2}'),
        ("duplicate-surrogate-pair-key", '{"😀":1,"\\ud83d\\ude00":2}'),
        ("duplicate-object-key", '{"a":{"x":1},"a":{"y":2}}'),
        ("duplicate-nul-key", '{"\\u0000":1,"\\u0000":2}'),
    ]:
        yield name, extension_base.replace("EXT", value), False
    for name, bad in [("invalid-utf8", b"\xff"), ("overlong-utf8", b"\xc0\xaf"),
                      ("truncated-utf8", b"\xe2\x82")]:
        yield name, base.encode().replace(b'"Probe"', b'"' + bad + b'"'), False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path,
                        default=Path(__file__).resolve().parents[1] / "bin/agentsync.sh")
    parser.add_argument("--compare-jq", action="store_true",
                        help="also report jq -e . acceptance; informational, not the oracle")
    args = parser.parse_args()
    cli = args.cli.resolve()
    results = []
    with tempfile.TemporaryDirectory(prefix="agentsync-mcp-probe-") as scratch:
        root = Path(scratch)
        catalog = root / "catalog"
        entry = catalog / "probe"
        entry.mkdir(parents=True)
        target = entry / "manifest.json"
        env = os.environ.copy()
        for name in list(env):
            if name.startswith(("AGENTSYNC_", "HCOM_", "HERDR_")):
                env.pop(name)
        env.update(AGENTSYNC_HOME=str(cli.parent.parent), AGENTSYNC_REPO_ROOT=str(root))
        for name, text, expected in cases():
            raw = text + b"\n" if isinstance(text, bytes) else (text + "\n").encode("utf-8")
            try:
                strict_decode(raw)
                reference = True
            except (ValueError, UnicodeError):
                reference = False
            if reference != expected:
                raise AssertionError(f"invalid reference fixture: {name}")
            target.write_bytes(raw)
            before = sorted(str(p.relative_to(root)) for p in root.rglob("*"))
            proc = subprocess.run(
                ["bash", str(cli), "mcp", "validate", "--library", str(catalog)],
                cwd=root, env=env, capture_output=True, timeout=15)
            accepted = proc.returncode == 0
            exact_show = None
            exact_render = None
            if accepted and expected:
                shown = subprocess.run(
                    ["bash", str(cli), "mcp", "show", "probe", "--library", str(catalog)],
                    cwd=root, env=env, capture_output=True, timeout=15)
                exact_show = shown.returncode == 0 and shown.stdout == raw
                decoded = strict_decode(raw)
                variants = {"default": decoded["connection"]}
                variants.update({name: value["connection"]
                                 for name, value in decoded.get("alternatives", {}).items()})
                if "guidance" in decoded:
                    variants["recommended"] = variants[decoded["guidance"]["recommended"]]
                exact_render = True
                for variant, connection in variants.items():
                    wanted = dict(connection)
                    if wanted["type"] == "stdio":
                        wanted.pop("type")
                    rendered = subprocess.run(
                        ["bash", str(cli), "mcp", "render", "probe@" + variant,
                         "--library", str(catalog)], cwd=root, env=env,
                        capture_output=True, timeout=15)
                    try:
                        actual = strict_decode(rendered.stdout)
                    except (ValueError, UnicodeError):
                        actual = None
                    exact_render &= (rendered.returncode == 0 and
                                     actual == {"mcpServers": {"probe": wanted}})
            after = sorted(str(p.relative_to(root)) for p in root.rglob("*"))
            unchanged = before == after and target.read_bytes() == raw
            passed = (accepted == expected and exact_show is not False and
                      exact_render is not False and unchanged)
            row = {"case": name, "reference": reference, "accepted": accepted,
                   "exact_show": exact_show, "exact_render": exact_render,
                   "unchanged": unchanged, "pass": passed}
            if args.compare_jq:
                comparison = subprocess.run(["jq", "-e", "."], input=raw,
                                            capture_output=True, timeout=15)
                row["jq_accepts"] = comparison.returncode == 0
            if not passed:
                row["stderr"] = proc.stderr.decode("utf-8", errors="replace")[:500]
            results.append(row)
    print(json.dumps({"passed": sum(r["pass"] for r in results),
                      "total": len(results), "cases": results}, indent=2))
    return 0 if all(r["pass"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
