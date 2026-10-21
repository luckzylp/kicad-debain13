#!/usr/bin/env bash
# Require the pushed tag to be exactly the tag recorded in the manifest.
#
# This is the guard against "just change the tag to v10.0.8" publishing the
# old 10.0.7 source.  It is called by release.yml before the build starts and
# again by the publish job.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
"${REPO_ROOT}/scripts/validate-manifest.sh" >/dev/null

tag="${GITHUB_REF_NAME:-${1:-}}"
[[ -n "$tag" ]] ||
  die "no tag supplied (set GITHUB_REF_NAME or pass the tag as the first argument)"

if [[ "$tag" != "$RELEASE_TAG" ]]; then
  cat >&2 <<EOF
Tag/source mismatch: pushed tag is '${tag}', but packaging/versions.env says
RELEASE_TAG='${RELEASE_TAG}' for source ${UPSTREAM_VERSION} (${DEB_VERSION}).

A tag does not update the source baseline.  To release a new KiCad version:
  1. update packaging/versions.env and packaging/sources.sha256;
  2. add a debian/changelog entry for the new downstream version;
  3. rebuild and pass the full release gate;
  4. create the matching tag.

Refusing to publish the wrong source under a new tag.
EOF
  exit 1
fi

if [[ "$tag" == *"~"* || "$tag" == *"rc"* || "$tag" == *"beta"* ]]; then
  die "refusing to publish a pre-release tag: $tag"
fi

printf 'release tag OK: %s -> %s (%s)\n' "$tag" "$DEB_VERSION" "$ARCHITECTURE"
