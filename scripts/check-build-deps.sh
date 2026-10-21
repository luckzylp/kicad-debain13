#!/usr/bin/env bash
# Resolve debian/control's Build-Depends against Debian 13 only.
#
# This is the central compatibility gate.  It intentionally uses apt's normal
# Trixie binary repositories; no sid binary repository is configured.  If the
# sid packaging asks for a version Trixie does not have, this fails and a human
# must decide whether to patch, backport, or defer the release.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOURCE_DIR="${1:-$(source_dir)}"
[[ -r "${SOURCE_DIR}/debian/control" ]] ||
  die "no debian/control under ${SOURCE_DIR}; run scripts/fetch-source.sh first"

load_versions
require_debian_13
require_cmd apt-get dpkg-checkbuilddeps
mkdir -p "$REPORT_DIR" "$LOG_DIR"

log "simulating Build-Depends resolution on Debian 13 (trixie)"
set +e
DEBIAN_FRONTEND=noninteractive apt-get -s build-dep --no-install-recommends "$SOURCE_DIR" \
  > "${LOG_DIR}/build-deps-simulation.log" 2>&1
rc=$?
set -e

if [[ $rc -ne 0 ]] || grep -qE '^E:' "${LOG_DIR}/build-deps-simulation.log"; then
  cat "${LOG_DIR}/build-deps-simulation.log" >&2
  die "Build-Depends cannot be satisfied from Debian 13; refusing to use sid binaries"
fi

{
  printf 'Build-Depends resolution for %s on %s/%s\n' \
    "$DEB_VERSION" "$DEBIAN_SUITE" "$ARCHITECTURE"
  printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'result: satisfiable from Debian 13 binary repositories\n\n'
  cat "${LOG_DIR}/build-deps-simulation.log"
} > "${REPORT_DIR}/build-deps.txt"

new_packages="$(awk '
  /^The following NEW packages will be installed:/ { in_list = 1; next }
  in_list && /^  / { n += NF; next }
  in_list { in_list = 0 }
  END { print n + 0 }
' "${LOG_DIR}/build-deps-simulation.log")"

ok "all Build-Depends resolve on Debian 13 (${new_packages} new packages would be installed)"
printf 'report: %s\n' "${REPORT_DIR}/build-deps.txt"
