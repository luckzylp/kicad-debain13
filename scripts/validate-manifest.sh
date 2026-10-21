#!/usr/bin/env bash
# Validate the version manifest, changelog, and source checksum inventory.
# This is deterministic and does not need network access.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_cmd dpkg dpkg-parsechangelog

[[ "$UPSTREAM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "UPSTREAM_VERSION must be a stable x.y.z release, got: $UPSTREAM_VERSION"

dpkg --validate-version "$DEB_VERSION" >/dev/null 2>&1 ||
  die "invalid Debian version: $DEB_VERSION"
dpkg --compare-versions "$DEB_VERSION" gt "$DEBIAN_BASE_VERSION" ||
  die "$DEB_VERSION must sort above the official $DEBIAN_BASE_VERSION"

[[ "$RELEASE_TAG" == "v${UPSTREAM_VERSION}" ||
   "$RELEASE_TAG" == "v${UPSTREAM_VERSION}-"* ]] ||
  die "RELEASE_TAG ($RELEASE_TAG) does not identify upstream $UPSTREAM_VERSION"
[[ "$RELEASE_TAG" != *"~"* && "$RELEASE_TAG" != *"rc"* &&
   "$RELEASE_TAG" != *"beta"* ]] ||
  die "RELEASE_TAG must identify a stable release, got: $RELEASE_TAG"

changelog="${REPO_ROOT}/debian/changelog"
[[ -r "$changelog" ]] || die "missing debian/changelog"
actual_version="$(dpkg-parsechangelog -l "$changelog" -S Version)"
actual_suite="$(dpkg-parsechangelog -l "$changelog" -S Distribution)"
actual_source="$(dpkg-parsechangelog -l "$changelog" -S Source)"
[[ "$actual_version" == "$DEB_VERSION" ]] ||
  die "debian/changelog version is $actual_version, expected $DEB_VERSION"
[[ "$actual_suite" == "$DEBIAN_SUITE" ]] ||
  die "debian/changelog distribution is $actual_suite, expected $DEBIAN_SUITE"
[[ "$actual_source" == "$SOURCE_NAME" ]] ||
  die "debian/changelog source is $actual_source, expected $SOURCE_NAME"

[[ "$(cat "${REPO_ROOT}/debian/source/format")" == "3.0 (quilt)" ]] ||
  die "debian/source/format must be 3.0 (quilt)"

control="${REPO_ROOT}/debian/control"
[[ -r "$control" ]] || die "missing debian/control"
grep -qx "Source: ${SOURCE_NAME}" "$control" ||
  die "debian/control does not declare Source: ${SOURCE_NAME}"
grep -q '^Build-Depends:' "$control" ||
  die "debian/control has no Build-Depends"
grep -q "^Package: ${BINARY_PACKAGE}$" "$control" ||
  die "debian/control does not declare Package: ${BINARY_PACKAGE}"

checksum_file="${REPO_ROOT}/packaging/sources.sha256"
[[ -r "$checksum_file" ]] || die "missing packaging/sources.sha256"
for file in "$SOURCE_DSC" "$SOURCE_ORIG" "$SOURCE_ORIG_DOC" "$SOURCE_DEBIAN_TAR"; do
  count="$(awk -v f="$file" '$2 == f { n++ } END { print n + 0 }' "$checksum_file")"
  [[ "$count" -eq 1 ]] ||
    die "packaging/sources.sha256 must contain exactly one entry for $file (found $count)"
done
bad_lines="$(awk 'NF != 2 || $1 !~ /^[0-9a-f]{64}$/ { n++ } END { print n + 0 }' "$checksum_file")"
[[ "$bad_lines" -eq 0 ]] ||
  die "packaging/sources.sha256 contains malformed or commented lines"

printf 'manifest OK\n'
printf '  upstream:        %s\n' "$UPSTREAM_VERSION"
printf '  official Debian: %s\n' "$DEBIAN_BASE_VERSION"
printf '  downstream:      %s\n' "$DEB_VERSION"
printf '  suite/arch:      %s/%s\n' "$DEBIAN_SUITE" "$ARCHITECTURE"
printf '  release tag:     %s\n' "$RELEASE_TAG"
