#!/usr/bin/env bash
# Build the Debian binary package with dpkg-buildpackage inside Debian 13.
#
# Scope "arch" (-B) builds the amd64 kicad binary package only.
# Scope "full" (-b) additionally builds kicad-demos and the translated docs.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="${SCOPE:-}"
JOBS="${JOBS:-}"
SOURCE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="${2:?missing value for --scope}"; shift 2 ;;
    --jobs) JOBS="${2:?missing value for --jobs}"; shift 2 ;;
    --source-dir) SOURCE_DIR="${2:?missing value for --source-dir}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/build-deb.sh [--scope arch|full] [--jobs N] [--source-dir DIR]

Environment:
  SCOPE, JOBS, SOURCE_DATE_EPOCH, DEB_BUILD_OPTIONS
EOF
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_versions
require_debian_13
require_cmd dpkg-buildpackage dpkg-parsechangelog dpkg-deb dpkg-architecture sha256sum
mkdir -p "$LOG_DIR" "$REPORT_DIR"

SCOPE="${SCOPE:-$BUILD_SCOPE}"
JOBS="${JOBS:-$(nproc)}"
if [[ -z "$SOURCE_DIR" && -r "${BUILD_DIR}/source.env" ]]; then
  # shellcheck disable=SC1091
  source "${BUILD_DIR}/source.env"
fi
SOURCE_DIR="${SOURCE_DIR:-$(source_dir)}"
ARTIFACT_DIR="$(dirname "$SOURCE_DIR")"

case "$SCOPE" in
  arch) BUILD_FLAG="-B"; min_disk=7 ;;
  full) BUILD_FLAG="-b"; min_disk=25 ;;
  *) die "invalid scope '$SCOPE' (expected arch or full)" ;;
esac

[[ -d "$SOURCE_DIR" ]] || die "source tree not found: $SOURCE_DIR; run scripts/fetch-source.sh"
[[ -r "${SOURCE_DIR}/debian/changelog" ]] || die "missing debian/changelog in $SOURCE_DIR"
[[ "$(dpkg-architecture -qDEB_HOST_ARCH)" == "amd64" ]] ||
  die "host architecture is not amd64"

version="$(dpkg-parsechangelog -l "${SOURCE_DIR}/debian/changelog" -S Version)"
[[ "$version" == "$DEB_VERSION" ]] ||
  die "source tree version is $version, expected $DEB_VERSION"

check_disk_space "$REPO_ROOT" "$min_disk"
safe_remove "$DIST_DIR"
mkdir -p "$DIST_DIR" "$LOG_DIR" "$REPORT_DIR"

# Remove artifacts from an earlier build in the same workspace.  Otherwise a
# failed build could leave an old .deb that the collection step would copy.
find "$ARTIFACT_DIR" -maxdepth 1 -type f \
  \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) -delete

changelog_date="$(dpkg-parsechangelog -l "${SOURCE_DIR}/debian/changelog" -S Date)"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u -d "$changelog_date" +%s)}"
export SOURCE_DATE_EPOCH
export DEB_BUILD_OPTIONS="parallel=${JOBS} reproducible=+fixfilepath noautodbgsym ${DEB_BUILD_OPTIONS:-}"
export TZ=UTC
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export DH_VERBOSE="${DH_VERBOSE:-0}"
umask 022

log "building ${DEB_VERSION} (${SCOPE}, -j${JOBS}, SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH})"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_log="${LOG_DIR}/build.log"

set +e
(
  cd "$SOURCE_DIR"
  dpkg-buildpackage "$BUILD_FLAG" -uc -us -j"$JOBS"
) 2>&1 | tee "$build_log"
rc=${PIPESTATUS[0]}
set -e

if [[ $rc -ne 0 ]]; then
  tail -n 250 "$build_log" >&2 || true
  die "dpkg-buildpackage failed with exit code $rc; full log: $build_log"
fi

# dpkg-buildpackage writes its results next to the source directory.
shopt -s nullglob
debs=( "$ARTIFACT_DIR"/*.deb )
buildinfos=( "$ARTIFACT_DIR"/*.buildinfo )
changes=( "$ARTIFACT_DIR"/*.changes )
shopt -u nullglob

(( ${#debs[@]} > 0 )) || die "build succeeded but produced no .deb files"
for file in "${debs[@]}" "${buildinfos[@]}" "${changes[@]}"; do
  cp -v "$file" "$DIST_DIR/"
done

main_deb="${DIST_DIR}/${BINARY_PACKAGE}_${DEB_VERSION}_${ARCHITECTURE}.deb"
[[ -f "$main_deb" ]] ||
  die "expected main package not found: $main_deb (scope $SCOPE)"

for deb in "$DIST_DIR"/*.deb; do
  pkg_arch="$(dpkg-deb -f "$deb" Architecture)"
  pkg_version="$(dpkg-deb -f "$deb" Version)"
  [[ "$pkg_version" == "$DEB_VERSION" ]] ||
    die "$(basename "$deb") has version $pkg_version, expected $DEB_VERSION"
  if [[ "$(basename "$deb")" == "${BINARY_PACKAGE}_"* ]]; then
    [[ "$pkg_arch" == "$ARCHITECTURE" ]] ||
      die "$(basename "$deb") has architecture $pkg_arch, expected $ARCHITECTURE"
  else
    [[ "$pkg_arch" == "all" || "$pkg_arch" == "$ARCHITECTURE" ]] ||
      die "$(basename "$deb") has unexpected architecture $pkg_arch"
  fi
done

finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  printf 'build summary\n'
  printf '  version: %s\n' "$DEB_VERSION"
  printf '  scope: %s (%s)\n' "$SCOPE" "$BUILD_FLAG"
  printf '  jobs: %s\n' "$JOBS"
  printf '  started: %s\n' "$started"
  printf '  finished: %s\n' "$finished"
  printf '  SOURCE_DATE_EPOCH: %s\n' "$SOURCE_DATE_EPOCH"
  printf '  repository commit: %s\n' "$(git_commit)"
  printf '  artifacts:\n'
  for file in "$DIST_DIR"/*.deb "$DIST_DIR"/*.buildinfo "$DIST_DIR"/*.changes; do
    [[ -f "$file" ]] || continue
    printf '    %s  %s\n' "$(sha256_of "$file")" "$(basename "$file")"
  done
} > "${REPORT_DIR}/build-summary.txt"

ok "built ${DEB_VERSION}; artifacts in ${DIST_DIR}"
cat "${REPORT_DIR}/build-summary.txt" >&2
