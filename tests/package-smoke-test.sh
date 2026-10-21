#!/usr/bin/env bash
# Install the freshly built package in a clean Debian 13 environment and run
# the core executable, Python module, desktop-file, and uninstall checks.
#
# This script mutates the machine (apt install/purge).  Run it in a disposable
# container or VM.  CI runs it in a fresh debian:13 container after the build.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

[[ ${EUID} -eq 0 ]] || die "smoke test must run as root in a disposable Debian 13 environment"
require_debian_13
require_cmd apt-get dpkg dpkg-query

if [[ $# -eq 0 ]]; then
  shopt -s nullglob
  set -- "$DIST_DIR"/*.deb
  shopt -u nullglob
fi
[[ $# -gt 0 ]] || die "no .deb files supplied"

main_deb=""
for deb in "$@"; do
  [[ -f "$deb" ]] || die "not a file: $deb"
  if [[ "$(dpkg-deb -f "$deb" Package)" == "$BINARY_PACKAGE" ]]; then
    [[ -z "$main_deb" ]] || die "more than one ${BINARY_PACKAGE} package found"
    main_deb="$deb"
  fi
done
[[ -n "$main_deb" ]] || die "no ${BINARY_PACKAGE} package found"

load_versions
mkdir -p "$REPORT_DIR"
report="${REPORT_DIR}/smoke-test.txt"
: > "$report"
exec > >(tee -a "$report") 2>&1

purge_package() {
  if dpkg-query -W -f='${Status}' "$BINARY_PACKAGE" 2>/dev/null |
       grep -q "install ok installed"; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$BINARY_PACKAGE" >/dev/null 2>&1 || true
  fi
}
trap purge_package EXIT

log "updating clean Debian 13 package index"
apt_get update

log "installing test-only utilities"
apt_get install -y --no-install-recommends desktop-file-utils

log "installing $(basename "$main_deb")"
# --no-install-recommends keeps the test focused on the application package.
# kicad-libraries is a separate source package and Trixie's 9.0.x libraries
# are intentionally not mixed into this KiCad 10 test.
apt_get install -y --no-install-recommends "$main_deb"

dpkg-query -W -f='${Status} ${Package} ${Version} ${Architecture}\n' "$BINARY_PACKAGE" |
  tee "${REPORT_DIR}/installed-package.txt"
grep -q "install ok installed" "${REPORT_DIR}/installed-package.txt" ||
  die "package did not reach the installed state"

version_output="$(kicad-cli version)"
printf 'kicad-cli version: %s\n' "$version_output"
grep -Fq "$UPSTREAM_VERSION" <<<"$version_output" ||
  die "kicad-cli version did not report $UPSTREAM_VERSION"

kicad-cli --help >/dev/null
command -v kicad >/dev/null

if ldd "$(command -v kicad-cli)" | grep -q 'not found'; then
  ldd "$(command -v kicad-cli)" >&2
  die "kicad-cli has unresolved shared libraries"
fi

desktop_file="$(dpkg -L "$BINARY_PACKAGE" | grep -E '^/usr/share/applications/.*\.desktop$' | head -n1)"
[[ -n "$desktop_file" ]] || die "package did not install a desktop file"
desktop-file-validate "$desktop_file"

log "testing the pcbnew Python module"
python3 -c 'import pcbnew; print("pcbnew module:", pcbnew.__file__)'

apt-get check

log "purging the package and checking for leftovers"
purge_package
if dpkg-query -W -f='${Status}' "$BINARY_PACKAGE" 2>/dev/null |
     grep -q "install ok installed"; then
  die "package is still installed after purge"
fi
[[ ! -e /usr/bin/kicad ]] || die "/usr/bin/kicad remains after purge"
[[ ! -e /usr/bin/kicad-cli ]] || die "/usr/bin/kicad-cli remains after purge"

audit_output="$(dpkg --audit || true)"
[[ -z "$audit_output" ]] || {
  printf '%s\n' "$audit_output" >&2
  die "dpkg --audit reported problems"
}

trap - EXIT
ok "clean Debian 13 install, CLI, Python, desktop-file, and purge checks passed"
