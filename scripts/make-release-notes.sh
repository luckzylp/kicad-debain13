#!/usr/bin/env bash
# Generate the GitHub Release body.  Deterministic except for the run URL and
# the artifact list, which are metadata rather than build inputs.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
mkdir -p "$DIST_DIR"

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-OWNER/REPO}/actions/runs/${GITHUB_RUN_ID:-unknown}"

main_deb="$(basename "$(find "$DIST_DIR" -maxdepth 1 -type f \
  -name "${BINARY_PACKAGE}_${DEB_VERSION}_${ARCHITECTURE}.deb" -print -quit)")"
[[ -n "$main_deb" ]] || die "main .deb not found in $DIST_DIR"

cat > "${DIST_DIR}/RELEASE-NOTES.md" <<EOF
# KiCad ${UPSTREAM_VERSION} for Debian 13 (${ARCHITECTURE})

This release contains **${main_deb}**, built from the official Debian source
package [\`${DEBIAN_BASE_VERSION}\`](https://packages.debian.org/sid/${SOURCE_NAME})
on Debian 13 (trixie).

- **Version:** \`${DEB_VERSION}\`
- **Architecture:** \`${ARCHITECTURE}\` only
- **Target suite:** Debian 13 (trixie) only
- **Source:** official Debian source package, signed \`.dsc\` and pinned SHA-256
  digests ([\`packaging/sources.sha256\`](https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/blob/${GITHUB_REF_NAME:-main}/packaging/sources.sha256))
- **Build log and provenance:** [GitHub Actions run](${run_url})
- **Signing:** none (unsigned release)

## Install

Download the \`.deb\` and install it with apt so that dependencies are resolved:

\`\`\`bash
sudo apt install ./${main_deb}
\`\`\`

If apt tries to pull Trixie's 9.0.x KiCad library packages and fails, use:

\`\`\`bash
sudo apt install --no-install-recommends ./${main_deb}
\`\`\`

### Important: libraries are not included

This package is the KiCad **application** only.  The symbol, footprint,
template, and 3D-model libraries are separate Debian source packages.  Debian
13 ships 9.0.x libraries, which this package declares incompatible with KiCad
10.  Installing the application may therefore remove the old library
metapackage.  Install matching KiCad 10 libraries from your preferred source
before opening projects that need them.

## Verify the download

This release is **unsigned**.  Download \`SHA256SUMS\` and check the files:

\`\`\`bash
sha256sum -c SHA256SUMS
\`\`\`

\`SHA256SUMS\` covers the \`.deb\`, \`build-info.json\`, the release notes, and
the test/audit reports.  It detects corruption and accidental modification, but
it does **not** prove who published the files.  For authenticity, obtain the
checksum file through an independent trusted channel.

## Scope and limitations

- amd64 only.  No arm64, i386, or other architectures are built.
- Debian 13 (trixie) only.  It is not tested on Debian testing/unstable or
  Ubuntu and is not an official Debian package.
- No automatic updates.  Re-download a newer release to upgrade.
- The GUI is not launched in CI (no display).  CI performs a clean-container
  install, \`kicad-cli\`, Python module, desktop-file, and purge test.
- The build is reproducible in principle but is not yet independently
  reproduced.  \`build-info.json\` records the exact source digests and build
  environment.
EOF

ok "wrote ${DIST_DIR}/RELEASE-NOTES.md"
