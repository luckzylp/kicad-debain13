#!/usr/bin/env bash
# Lintian and package-metadata audit.
#
# Errors block the build.  Warnings are recorded for manual review: this
# project does not silently waive all Lintian warnings, but the Debian package
# already carries reviewed overrides in debian/kicad.lintian-overrides.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_cmd lintian dpkg-deb
mkdir -p "$REPORT_DIR"

if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  set -- "$DIST_DIR"/*.deb
  shopt -u nullglob
fi
[[ $# -gt 0 ]] || die "no .deb files supplied"

lintian_log="${REPORT_DIR}/lintian.txt"
: > "$lintian_log"
audit_rc=0

for deb in "$@"; do
  [[ -f "$deb" ]] || die "not a file: $deb"
  log "lintian $(basename "$deb")"
  set +e
  lintian --info --display-info --color never --fail-on error "$deb" \
    >> "$lintian_log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "lintian reported an error for $(basename "$deb")"
    audit_rc=1
  fi
done

if grep -qE '^E:' "$lintian_log"; then
  grep -E '^E:' "$lintian_log" >&2
  audit_rc=1
fi

warning_count="$(grep -cE '^W:' "$lintian_log" || true)"
if (( warning_count > 0 )); then
  warn "lintian reported ${warning_count} warning(s); review ${lintian_log}"
else
  ok "lintian reported no warnings"
fi

if [[ $audit_rc -ne 0 ]]; then
  die "lintian errors found; see ${lintian_log}"
fi

# A small, explicit metadata sanity check independent of Lintian.
for deb in "$@"; do
  pkg="$(dpkg-deb -f "$deb" Package)"
  arch="$(dpkg-deb -f "$deb" Architecture)"
  version="$(dpkg-deb -f "$deb" Version)"
  [[ -n "$pkg" && -n "$arch" && -n "$version" ]] ||
    die "$(basename "$deb"): missing Package/Architecture/Version"
  dpkg-deb --info "$deb" > "${REPORT_DIR}/$(basename "$deb").audit-info.txt"
done

ok "package audit passed"
