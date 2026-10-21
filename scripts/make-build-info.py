#!/usr/bin/env python3
"""Write a deterministic-ish build-info.json for the release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ASSIGNMENT = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = ASSIGNMENT.match(line)
        if not match:
            continue
        key, value = match.groups()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_value(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path,
                        default=Path("packaging/versions.env"))
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--workflow", default=os.environ.get("GITHUB_WORKFLOW", ""))
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    args = parser.parse_args()

    manifest = parse_env_file(args.manifest)
    required = ["UPSTREAM_VERSION", "DEBIAN_BASE_VERSION", "DFSG_UPSTREAM_VERSION",
                "DOWNSTREAM_REVISION", "DEBIAN_SUITE", "ARCHITECTURE"]
    missing = [key for key in required if key not in manifest]
    if missing:
        print(f"manifest missing keys: {', '.join(missing)}", file=sys.stderr)
        return 1

    version = f"{manifest['DFSG_UPSTREAM_VERSION']}-{manifest['DOWNSTREAM_REVISION']}"
    repo = args.manifest.resolve().parent.parent
    dist = args.dist.resolve()
    output = (args.output or (dist / "build-info.json")).resolve()

    if not dist.is_dir():
        print(f"dist directory does not exist: {dist}", file=sys.stderr)
        return 1

    artifacts = []
    for path in sorted(dist.iterdir()):
        if not path.is_file():
            continue
        if path.name in {"build-info.json", "SHA256SUMS", "SHA256SUMS.asc"}:
            continue
        artifacts.append({
            "name": path.name,
            "size": path.stat().st_size,
            "sha256": sha256(path),
        })

    source_hashes = {}
    checksum_file = repo / "packaging/sources.sha256"
    if checksum_file.is_file():
        for line in checksum_file.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) == 2:
                source_hashes[parts[1]] = parts[0]

    payload = {
        "schema": 1,
        "package": manifest.get("BINARY_PACKAGE", "kicad"),
        "version": version,
        "upstream_version": manifest["UPSTREAM_VERSION"],
        "debian_base_version": manifest["DEBIAN_BASE_VERSION"],
        "suite": manifest["DEBIAN_SUITE"],
        "architecture": manifest["ARCHITECTURE"],
        "scope": args.scope,
        "source": {
            "origin": "Debian archive (official source package)",
            "dsc": manifest.get("SOURCE_DSC", ""),
            "checksums": source_hashes,
        },
        "build": {
            "runner": args.runner,
            "workflow": args.workflow,
            "run_id": args.run_id,
            "repository": os.environ.get("GITHUB_REPOSITORY", ""),
            "commit": git_value(repo, "rev-parse", "HEAD"),
            "dirty": bool(git_value(repo, "status", "--porcelain") not in ("", "unknown")),
            "source_date_epoch": os.environ.get("SOURCE_DATE_EPOCH", ""),
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "artifacts": artifacts,
    }

    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n",
                      encoding="utf-8")
    print(f"wrote {output} ({len(artifacts)} artifact(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
