#!/usr/bin/env bash
# Static package validation.  Installation testing lives in
# tests/package-smoke-test.sh and runs in a separate clean Debian 13 container.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_cmd dpkg-deb
mkdir -p "$REPORT_DIR"

if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  set -- "$DIST_DIR"/*.deb
  shopt -u nullglob
fi
[[ $# -gt 0 ]] || die "no .deb files supplied"

for deb in "$@"; do
  [[ -f "$deb" ]] || die "not a file: $deb"
  log "inspecting $(basename "$deb")"
  dpkg-deb --info "$deb" > "${REPORT_DIR}/$(basename "$deb").info.txt"
  dpkg-deb --contents "$deb" > "${REPORT_DIR}/$(basename "$deb").contents.txt"
done

"${REPO_ROOT}/tests/dependency-check.sh" "$@"
ok "static package checks passed"
