#!/usr/bin/env bash
# Create a draft GitHub Release, upload all assets, then publish it.
#
# Recovery: if a previous run created a release but uploaded no assets (for
# example, a zero-byte asset was rejected), this script completes that empty
# release instead of failing.  A release that already has assets is never
# overwritten; it must be handled manually.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_cmd gh dpkg-parsechangelog
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is not set"
[[ -n "${GITHUB_REF_NAME:-}" ]] || die "GITHUB_REF_NAME is not set"
[[ -d "${DIST_DIR}" ]] || die "missing dist directory: ${DIST_DIR}"

shopt -s nullglob
assets=(
  "$DIST_DIR"/*.deb
  "$DIST_DIR"/*.buildinfo
  "$DIST_DIR"/*.changes
  "$DIST_DIR"/SHA256SUMS
  "$DIST_DIR"/build-info.json
  "$DIST_DIR"/RELEASE-NOTES.md
  "$DIST_DIR"/reports/*
)
shopt -u nullglob
(( ${#assets[@]} > 0 )) || die "no release assets found in ${DIST_DIR}"
for asset in "${assets[@]}"; do
  [[ -f "$asset" ]] || die "release asset is not a regular file: $asset"
done

tag="$GITHUB_REF_NAME"
title="KiCad ${UPSTREAM_VERSION} for Debian 13 (${ARCHITECTURE})"
version="$(dpkg-parsechangelog -l "${REPO_ROOT}/debian/changelog" -S Version)"

asset_count=""
if asset_count="$(gh release view "$tag" --json assets --jq '.assets | length' 2>/dev/null)"; then
  [[ "$asset_count" =~ ^[0-9]+$ ]] || die "could not read asset count for $tag"
  if (( asset_count != 0 )); then
    die "release $tag already has ${asset_count} asset(s); refusing to overwrite"
  fi
  warn "release $tag exists but has no assets; completing it"
  gh release upload "$tag" "${assets[@]}" --clobber
  gh release edit "$tag" \
    --draft=false \
    --latest \
    --title "$title" \
    --notes-file "${DIST_DIR}/RELEASE-NOTES.md"
else
  gh release create "$tag" \
    --draft \
    --verify-tag \
    --title "$title" \
    --notes-file "${DIST_DIR}/RELEASE-NOTES.md"
  gh release upload "$tag" "${assets[@]}" --clobber
  gh release edit "$tag" \
    --draft=false \
    --latest \
    --title "$title" \
    --notes-file "${DIST_DIR}/RELEASE-NOTES.md"
fi

ok "published $tag for $version (${#assets[@]} assets)"
