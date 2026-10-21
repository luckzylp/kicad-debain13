#!/usr/bin/env bash
# Static package checks that do not require installing the package.
# Usage: tests/dependency-check.sh [path/to/kicad_*.deb ...]

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

load_versions
require_cmd dpkg-deb awk grep tar

if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  set -- "$DIST_DIR"/*.deb
  shopt -u nullglob
fi
[[ $# -gt 0 ]] || die "no .deb files supplied"

main_deb=""
for deb in "$@"; do
  [[ -f "$deb" ]] || die "not a file: $deb"
  pkg="$(dpkg-deb -f "$deb" Package)"
  if [[ "$pkg" == "$BINARY_PACKAGE" ]]; then
    [[ -z "$main_deb" ]] || die "more than one ${BINARY_PACKAGE} package found"
    main_deb="$deb"
  fi
done
[[ -n "$main_deb" ]] || die "no ${BINARY_PACKAGE} package found in: $*"

pkg_arch="$(dpkg-deb -f "$main_deb" Architecture)"
pkg_version="$(dpkg-deb -f "$main_deb" Version)"
pkg_section="$(dpkg-deb -f "$main_deb" Section)"
pkg_priority="$(dpkg-deb -f "$main_deb" Priority)"
pkg_depends="$(dpkg-deb -f "$main_deb" Depends)"
pkg_recommends="$(dpkg-deb -f "$main_deb" Recommends || true)"
pkg_size="$(dpkg-deb -f "$main_deb" Installed-Size)"

[[ "$pkg_arch" == "$ARCHITECTURE" ]] ||
  die "$(basename "$main_deb"): architecture $pkg_arch, expected $ARCHITECTURE"
[[ "$pkg_version" == "$DEB_VERSION" ]] ||
  die "$(basename "$main_deb"): version $pkg_version, expected $DEB_VERSION"
[[ "$pkg_section" == "electronics" ]] ||
  die "$(basename "$main_deb"): Section is '$pkg_section', expected electronics"
[[ -z "$pkg_priority" || "$pkg_priority" == "optional" ]] ||
  die "$(basename "$main_deb"): Priority is '$pkg_priority', expected optional"
[[ -n "$pkg_depends" ]] || die "package has no Depends field"
if [[ ! "${pkg_size:-0}" =~ ^[0-9]+$ ]] || (( pkg_size <= 0 )); then
  die "package has an invalid Installed-Size: ${pkg_size:-unset}"
fi

contents="$(mktemp)"
members="$(mktemp)"
trap 'rm -f "$contents" "$members"' EXIT
dpkg-deb --contents "$main_deb" > "$contents"
if ! dpkg-deb --fsys-tarfile "$main_deb" | tar -tf - > "$members"; then
  die "could not list the package filesystem"
fi
[[ -s "$members" ]] || die "package filesystem listing is empty"

for required in ./usr/bin/kicad ./usr/bin/kicad-cli ./usr/share/man/man1/kicad.1.gz; do
  grep -qF " $required" "$contents" ||
    die "missing required path in package: $required"
done
grep -Eq ' \./usr/share/applications/[^ ]+\.desktop$' "$contents" ||
  die "missing desktop file under /usr/share/applications"

# Check tar member names, not dpkg-deb --contents lines: the latter include
# symlink targets such as "../../lib/..." which are legitimate.
if awk '
  {
    if ($0 !~ /^\.\//) {
      printf "non-relative package path: %s\n", $0 > "/dev/stderr"
      bad = 1
      next
    }
    n = split($0, part, "/")
    for (i = 1; i <= n; i++) {
      if (part[i] == "..") {
        printf "path traversal: %s\n", $0 > "/dev/stderr"
        bad = 1
        break
      }
    }
  }
  END { exit(bad ? 0 : 1) }
' "$members"; then
  die "package contains an unsafe path traversal entry"
fi

if awk '$1 ~ /^...s/ || $1 ~ /^......s/ { print; found=1 } END { exit(found ? 0 : 1) }' "$contents" >&2; then
  die "package contains setuid/setgid files"
fi

if awk '$1 ~ /^-[rwx-]{7}w/ { print; found=1 } END { exit(found ? 0 : 1) }' "$contents" >&2; then
  die "package contains world-writable regular files"
fi

{
  printf 'package: %s\n' "$BINARY_PACKAGE"
  printf 'version: %s\n' "$pkg_version"
  printf 'architecture: %s\n' "$pkg_arch"
  printf 'installed-size: %s KiB\n' "$pkg_size"
  printf 'depends: %s\n' "$pkg_depends"
  printf 'recommends: %s\n' "${pkg_recommends:-<none>}"
  printf 'file-count: %s\n' "$(wc -l < "$contents")"
} > "${REPORT_DIR}/dependency-check.txt"

if [[ "$pkg_recommends" == *"kicad-libraries"* ]]; then
  warn "kicad Recommends kicad-libraries, which is a separate Debian source package"
  warn "Trixie's 9.0.x libraries conflict with this 10.0.x application; see README.md"
fi

ok "dependency and file-layout checks passed for $(basename "$main_deb")"
