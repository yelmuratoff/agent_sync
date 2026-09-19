#!/usr/bin/env python3
"""Offline metadata check and review queue. Never fetch sources or read credentials."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlparse


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_url(value):
    require(isinstance(value, str), "source must be a string")
    parsed = urlparse(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment,
            "source must be credential-free HTTPS without query or fragment")


def posix_shell_path_from_resolved(resolved, platform):
    value = resolved.as_posix()
    if platform == "nt" and re.fullmatch(r"[A-Za-z]:", resolved.drive):
        return f"/{resolved.drive[0].lower()}{value[len(resolved.drive):]}"
    return value


def posix_shell_path(path):
    """Return an absolute path Git Bash can pass to a shell script."""
    return posix_shell_path_from_resolved(path.resolve(), os.name)


def check(path, today):
    data = json.loads(path.read_text(encoding="utf-8"))
    meta = data["extensions"]["agentsync.dev"]
    require(isinstance(meta, dict), "requirements metadata must be an object")
    require(set(meta) == {"requirements_version", "checked_at", "review_after_days", "sources",
                          "variants", "optional_methods"}, "unknown or missing requirements metadata field")
    require(type(meta["requirements_version"]) is int and meta["requirements_version"] == 1,
            "unknown requirements metadata version")
    checked = dt.date.fromisoformat(meta["checked_at"])
    interval = meta["review_after_days"]
    require(type(interval) is int and 1 <= interval <= 365, "invalid review interval")
    require(checked <= today, "checked_at is in the future")
    require(isinstance(meta["sources"], list) and meta["sources"], "missing evidence sources")
    for source in meta["sources"]:
        source_url(source)
    if "guidance" in data:
        source_url(data["guidance"]["source"])
    connections = {"default": data, **data.get("alternatives", {})}
    require(isinstance(meta["variants"], dict) and set(meta["variants"]) == set(connections),
            "metadata must cover exactly selectable variants")
    for variant, details in meta["variants"].items():
        require(isinstance(details, dict) and set(details) == {"auth", "runtime", "network_hosts", "capabilities", "notes"},
                "unknown or missing variant metadata field")
        auth = details["auth"]
        require(isinstance(auth, dict) and {"kind", "owner", "required_for"} <= set(auth)
                <= {"kind", "owner", "required_for", "environment_any_of"}, "unknown auth metadata field")
        require(auth["kind"] in {"none", "oauth", "provider-managed"}, "unsupported auth kind")
        require(auth["owner"] in {"none", "client", "server"}, "unsupported auth owner")
        require((auth["kind"] == "none") == (auth["owner"] == "none"), "inconsistent auth owner")
        for field in ("network_hosts", "capabilities", "notes"):
            require(isinstance(details[field], list) and all(isinstance(x, str) for x in details[field]),
                    f"invalid {field}")
        require(isinstance(auth["required_for"], list) and all(isinstance(x, str) for x in auth["required_for"]),
                "invalid auth conditions")
        env = auth.get("environment_any_of", [])
        require(isinstance(env, list) and all(isinstance(x, str)
                and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", x) for x in env),
                "environment entries are names, never values")
        require(isinstance(details["runtime"], dict) and all(isinstance(k, str) and isinstance(v, str)
                for k, v in details["runtime"].items()), "invalid runtime metadata")
        if connections[variant]["connection"]["type"] == "http":
            require(not connections[variant]["requirements"]["binaries"], "remote variant inherits local binaries")
    require(isinstance(meta["optional_methods"], list), "optional methods must be an array")
    optional_ids = set()
    for option in meta["optional_methods"]:
        require(isinstance(option, dict) and set(option) == {"id", "status", "source", "notes"}, "unknown optional method field")
        require(isinstance(option["id"], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", option["id"]),
                "invalid optional method id")
        require(option["id"] not in optional_ids, "duplicate optional method id")
        optional_ids.add(option["id"])
        require(isinstance(option["notes"], str), "optional method notes must be a string")
        require(option["status"] == "documented-only", "optional methods must not pretend to be selectable")
        require(option["id"] not in connections, "documented-only method shadows a selectable variant")
        source_url(option["source"])
    due = checked + dt.timedelta(days=interval)
    return {"id": data["id"], "status": "due" if today >= due else "current",
            "checked_at": checked.isoformat(), "review_due": due.isoformat(), "sources": meta["sources"]}


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=root / "catalog/mcp")
    parser.add_argument("--bash", type=Path, default=Path("bash"))
    parser.add_argument("--as-of", type=dt.date.fromisoformat, default=dt.date.today())
    parser.add_argument("--fail-stale", action="store_true")
    args = parser.parse_args()
    shell_root = posix_shell_path(root)
    subprocess.run([args.bash.as_posix(), posix_shell_path(root / "bin/agentsync.sh"), "mcp", "validate", "--library",
                    posix_shell_path(args.catalog)], check=True, stdout=sys.stderr,
                   env=dict(os.environ, AGENTSYNC_HOME=shell_root))
    paths = sorted(args.catalog.glob("*/manifest.json"))
    require(bool(paths), "catalog is empty")
    records = [check(path, args.as_of) for path in paths]
    print(json.dumps({"as_of": str(args.as_of), "entries": records}, indent=2))
    return int(args.fail_stale and any(record["status"] == "due" for record in records))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Catalog metadata check failed: {error}", file=sys.stderr)
        sys.exit(2)
