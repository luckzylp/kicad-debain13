#!/usr/bin/env bash
# Prove that the vendored debian/ directory is the official Debian packaging
# (10.0.7+dfsg-1) plus a changelog entry, and nothing else.
#
# Only the .dsc and .debian.tar.xz are downloaded, so this check is cheap
# enough to run on every pull request.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_debian_13
require_cmd python3 tar xz

"${REPO_ROOT}/scripts/fetch-source.sh" --packaging-only >/dev/null

official_dir="${BUILD_DIR}/provenance/official"
safe_remove "$official_dir"
mkdir -p "$official_dir"

tar -xJf "${CACHE_DIR}/${SOURCE_DEBIAN_TAR}" -C "$official_dir"

python3 "${REPO_ROOT}/scripts/compare_debian_packaging.py" \
  --official "$official_dir" \
  --repo "$REPO_ROOT" \
  --allow "${REPO_ROOT}/packaging/allowed-packaging-diff.txt" \
  --expected-version "$DEB_VERSION" \
  --expected-suite "$DEBIAN_SUITE" \
  --expected-base-version "$DEBIAN_BASE_VERSION"

ok "vendored debian/ provenance verified against ${DEBIAN_BASE_VERSION}"
