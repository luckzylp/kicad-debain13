#!/usr/bin/env bash
# Install debian/control's build dependencies from Debian 13 binary repos.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOURCE_DIR="${1:-$(source_dir)}"
[[ -r "${SOURCE_DIR}/debian/control" ]] ||
  die "no debian/control under ${SOURCE_DIR}; run scripts/fetch-source.sh first"

load_versions
require_debian_13
require_cmd apt-get dpkg-checkbuilddeps
mkdir -p "$REPORT_DIR" "$LOG_DIR"

log "installing Build-Depends from Debian 13 (trixie)"
apt_get build-dep -y --no-install-recommends "$SOURCE_DIR" \
  2>&1 | tee "${LOG_DIR}/build-deps-install.log"

(
  cd "$SOURCE_DIR"
  dpkg-checkbuilddeps
) 2>&1 | tee "${REPORT_DIR}/dpkg-checkbuilddeps.txt"

# GitHub-hosted runners have only ~14 GiB free.  Reclaim the apt package cache
# before the compilation starts.
apt_get clean

ok "Build-Depends installed and dpkg-checkbuilddeps passes"
