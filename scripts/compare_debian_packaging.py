#!/usr/bin/env python3
"""Compare the vendored debian/ directory with the signed Debian packaging.

The only permitted difference is debian/changelog, which carries the
downstream entry.  The official changelog must still be an exact suffix of the
vendored changelog, so upstream entries cannot be silently edited or removed.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def kind(path: Path) -> str:
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def entries(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    if not root.is_dir():
        raise SystemExit(f"not a directory: {root}")
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            path = Path(dirpath) / name
            rel = path.relative_to(root).as_posix()
            result[rel] = path
    return result


def load_allowlist(path: Path) -> set[str]:
    allowed: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        allowed.add(line)
    return allowed


def describe(path: Path) -> str:
    mode = stat.S_IMODE(path.lstat().st_mode)
    if path.is_symlink():
        return f"symlink -> {os.readlink(path)}"
    if path.is_file():
        return f"{kind(path)} mode={mode:04o} sha256={sha256(path)}"
    return f"{kind(path)} mode={mode:04o}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official", required=True, type=Path,
                        help="directory containing the official debian/ tree")
    parser.add_argument("--repo", required=True, type=Path,
                        help="repository root containing debian/")
    parser.add_argument("--allow", required=True, type=Path,
                        help="allowlist of repository-relative paths")
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-suite", required=True)
    parser.add_argument("--expected-base-version", required=True)
    args = parser.parse_args()

    official_root = args.official / "debian"
    repo_root = args.repo / "debian"
    allowed = load_allowlist(args.allow)

    official = entries(official_root)
    vendored = entries(repo_root)
    problems: list[str] = []
    changed: list[str] = []

    for rel in sorted(set(official) | set(vendored)):
        repo_rel = f"debian/{rel}"
        if repo_rel in allowed:
            changed.append(repo_rel)
            continue
        if rel not in official:
            problems.append(f"added: {repo_rel}")
            continue
        if rel not in vendored:
            problems.append(f"removed: {repo_rel}")
            continue
        left = official[rel]
        right = vendored[rel]
        if kind(left) != kind(right):
            problems.append(
                f"type changed: {repo_rel} ({kind(left)} -> {kind(right)})"
            )
            continue
        if left.is_symlink():
            if os.readlink(left) != os.readlink(right):
                problems.append(f"symlink target changed: {repo_rel}")
            continue
        if left.is_file():
            if stat.S_IMODE(left.stat().st_mode) != stat.S_IMODE(right.stat().st_mode):
                problems.append(f"mode changed: {repo_rel}")
            if sha256(left) != sha256(right):
                problems.append(f"content changed: {repo_rel}")
        elif left.is_dir():
            if stat.S_IMODE(left.stat().st_mode) != stat.S_IMODE(right.stat().st_mode):
                problems.append(f"directory mode changed: {repo_rel}")

    repo_changelog = (repo_root / "changelog").read_text(encoding="utf-8")
    official_changelog = (official_root / "changelog").read_text(encoding="utf-8")

    if not repo_changelog.endswith(official_changelog):
        problems.append(
            "debian/changelog does not end with the official Debian changelog; "
            "upstream entries were edited or removed"
        )

    first_line = repo_changelog.splitlines()[0] if repo_changelog else ""
    expected_prefix = f"kicad ({args.expected_version}) {args.expected_suite};"
    if not first_line.startswith(expected_prefix):
        problems.append(
            f"debian/changelog first line is {first_line!r}, expected prefix "
            f"{expected_prefix!r}"
        )

    official_first = official_changelog.splitlines()[0] if official_changelog else ""
    expected_official = f"kicad ({args.expected_base_version}) "
    if not official_first.startswith(expected_official):
        problems.append(
            f"official debian/changelog first line is {official_first!r}, expected "
            f"{expected_official!r}"
        )

    # Prove the changelog really is the only modified path.
    if changed != ["debian/changelog"]:
        problems.append(
            "allowlist is expected to contain exactly debian/changelog; "
            f"got {', '.join(changed) or '(none)'}"
        )

    if problems:
        print("packaging provenance check FAILED", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        "packaging provenance OK: vendored debian/ matches "
        f"{args.expected_base_version}; only debian/changelog differs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
