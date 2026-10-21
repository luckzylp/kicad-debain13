#!/usr/bin/env bash
# Install the host tools needed to download, build, audit, and sign packages.
# The KiCad build dependencies themselves are resolved from debian/control by
# scripts/check-build-deps.sh (apt-get build-dep), not hard-coded here.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE=1
for arg in "$@"; do
  case "$arg" in
    --no-update) UPDATE=0 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/install-build-tools.sh [--no-update]

Installs packaging tools with apt.  Requires root or passwordless sudo.
EOF
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_debian_13
require_cmd apt-get

log "installing Debian packaging tools"
if [[ "$UPDATE" -eq 1 ]]; then
  apt_get update
fi

# Keep this list limited to tools the pipeline actually invokes.  Build
# dependencies are deliberately not duplicated here: apt-get build-dep reads
# them from the vendored debian/control, so a missing Trixie dependency fails
# the gate instead of being papered over.
apt_get install -y --no-install-recommends \
  binutils \
  build-essential \
  ca-certificates \
  curl \
  debian-keyring \
  debhelper \
  devscripts \
  dpkg-dev \
  equivs \
  fakeroot \
  file \
  git \
  gnupg \
  gpgv \
  lintian \
  python3 \
  python3-yaml \
  quilt \
  sudo \
  xz-utils

mkdir -p "$REPORT_DIR"
{
  printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'os: %s\n' "$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
  printf 'kernel: %s\n' "$(uname -r)"
  for cmd in dpkg-buildpackage dpkg-source dscverify lintian quilt curl gpgv python3; do
    printf '%s: %s\n' "$cmd" "$(command -v "$cmd")"
  done
  dpkg-query -W -f='${Package} ${Version}\n' \
    dpkg-dev debhelper devscripts lintian quilt 2>/dev/null || true
} > "${REPORT_DIR}/tool-versions.txt"

ok "build tools installed; report: ${REPORT_DIR}/tool-versions.txt"
