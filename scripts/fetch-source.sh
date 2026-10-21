#!/usr/bin/env bash
# Download, authenticate, and unpack the official Debian source package, then
# overlay this repository's downstream debian/ directory.
#
# No sid apt source or binary repository is added.  The four files are fetched
# directly from the Debian archive and checked against committed SHA-256
# digests and the Debian developer signature on the .dsc.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACKAGING_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --packaging-only) PACKAGING_ONLY=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/fetch-source.sh [--packaging-only]

  --packaging-only  Download and authenticate the .dsc and .debian.tar.xz only.
                    Used by the packaging-provenance CI check.

Environment:
  CACHE_DIR   Download cache (default: .cache/downloads)
  BUILD_DIR   Build workspace (default: build)
EOF
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

load_versions
require_debian_13
require_cmd curl dpkg-source sha256sum gpgv dpkg-parsechangelog
if [[ "$PACKAGING_ONLY" -eq 0 ]]; then
  require_cmd dscverify quilt
fi

if [[ "$PACKAGING_ONLY" -eq 1 ]]; then
  check_disk_space "$REPO_ROOT" 1
else
  check_disk_space "$REPO_ROOT" 10
fi
mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$LOG_DIR" "$REPORT_DIR"

expected_for() {
  awk -v file="$1" '$2 == file { print $1; found=1 } END { exit(found ? 0 : 1) }' \
    "${REPO_ROOT}/packaging/sources.sha256"
}

# shellcheck disable=SC2153  # manifest variables are loaded by load_versions
for file in "$SOURCE_DSC" "$SOURCE_ORIG" "$SOURCE_ORIG_DOC" "$SOURCE_DEBIAN_TAR"; do
  expected_for "$file" >/dev/null ||
    die "packaging/sources.sha256 has no entry for $file"
done

base_url="${DEBIAN_MIRROR}/${DEBIAN_POOL_PATH}"

download_one() {
  local file="$1" expected
  expected="$(expected_for "$file")"
  download_verified "${base_url}/${file}" "${CACHE_DIR}/${file}" "$expected"
}

log "downloading the signed Debian source package for ${DEBIAN_BASE_VERSION}"
download_one "$SOURCE_DSC"
download_one "$SOURCE_DEBIAN_TAR"
if [[ "$PACKAGING_ONLY" -eq 0 ]]; then
  download_one "$SOURCE_ORIG"
  download_one "$SOURCE_ORIG_DOC"
fi

# Verify the .dsc is signed by a Debian key.  debian-keyring is intentionally a
# build-time dependency; the archive keyring alone does not contain uploader
# keys.
KEYRING="${DEBIAN_KEYRING:-}"
if [[ -z "$KEYRING" ]]; then
  for candidate in \
    /usr/share/keyrings/debian-keyring.gpg \
    /usr/share/keyrings/debian-keyring.pgp; do
    if [[ -r "$candidate" ]]; then
      KEYRING="$candidate"
      break
    fi
  done
fi
if [[ -z "$KEYRING" ]]; then
  KEYRING="$(dpkg -L debian-keyring 2>/dev/null |
    awk '/debian-keyring\.(gpg|pgp)$/ { print; exit }')"
fi
[[ -r "${KEYRING:-}" ]] ||
  die "Debian keyring not found; install debian-keyring (apt-get install debian-keyring)"

if ! gpgv --keyring "$KEYRING" "${CACHE_DIR}/${SOURCE_DSC}" \
     > "${LOG_DIR}/dsc-signature.txt" 2>&1; then
  cat "${LOG_DIR}/dsc-signature.txt" >&2
  die "the source .dsc signature did not verify; see ${LOG_DIR}/dsc-signature.txt"
fi

# Cross-check the checksum table inside the signed .dsc with our pinned file.
# This prevents the committed digests from drifting away from the signed source
# metadata even if somebody updates only one of the two.
awk '
  /^Checksums-Sha256:/ { in_table = 1; next }
  /^[^ ]/ { in_table = 0 }
  in_table && $1 ~ /^[0-9a-f]{64}$/ { print $1 "  " $3 }
' "${CACHE_DIR}/${SOURCE_DSC}" > "${BUILD_DIR}/dsc-checksums.sha256"

while read -r hash file; do
  [[ -n "$file" ]] || continue
  expected="$(expected_for "$file")" || die "unexpected file in .dsc: $file"
  [[ "$hash" == "$expected" ]] ||
    die ".dsc checksum for $file does not match packaging/sources.sha256"
done < "${BUILD_DIR}/dsc-checksums.sha256"

if [[ "$PACKAGING_ONLY" -eq 0 ]]; then
  # dscverify checks every referenced tarball as well as the signature.
  if ! ( cd "$CACHE_DIR" && dscverify --keyring "$KEYRING" "$SOURCE_DSC" ) \
       > "${LOG_DIR}/dscverify.txt" 2>&1; then
    cat "${LOG_DIR}/dscverify.txt" >&2
    die "dscverify failed; see ${LOG_DIR}/dscverify.txt"
  fi
  ok "source archives, checksums, and .dsc signature verified"
else
  ok "source .dsc signature and packaging tarball checksum verified"
  printf '%s\n' "${CACHE_DIR}/${SOURCE_DSC}"
  exit 0
fi

SOURCE_DIR="$(source_dir)"
safe_remove "$SOURCE_DIR"

log "unpacking the official source package"
(
  cd "$CACHE_DIR"
  dpkg-source -x "$SOURCE_DSC" "$SOURCE_DIR"
) > "${LOG_DIR}/dpkg-source-extract.txt" 2>&1 ||
  die "dpkg-source -x failed; see ${LOG_DIR}/dpkg-source-extract.txt"

# Start from an unpatched tree so our vendored debian/patches are the only
# patches applied, and so a downstream patch addition is handled by quilt.
(
  cd "$SOURCE_DIR"
  QUILT_PATCHES=debian/patches quilt pop -a
) > "${LOG_DIR}/quilt-pop.txt" 2>&1 || {
  cat "${LOG_DIR}/quilt-pop.txt" >&2
  die "could not unapply the official patch series"
}

safe_remove "${SOURCE_DIR}/debian"
cp -a "${REPO_ROOT}/debian" "${SOURCE_DIR}/debian"

log "applying downstream debian/patches"
(
  cd "$SOURCE_DIR"
  dpkg-source --before-build .
) > "${LOG_DIR}/dpkg-source-before-build.txt" 2>&1 || {
  cat "${LOG_DIR}/dpkg-source-before-build.txt" >&2
  die "dpkg-source --before-build failed while applying patches"
}

changelog="${SOURCE_DIR}/debian/changelog"
actual_version="$(dpkg-parsechangelog -l "$changelog" -S Version)"
actual_suite="$(dpkg-parsechangelog -l "$changelog" -S Distribution)"
actual_source="$(dpkg-parsechangelog -l "$changelog" -S Source)"
[[ "$actual_version" == "$DEB_VERSION" ]] ||
  die "debian/changelog version is $actual_version, expected $DEB_VERSION"
[[ "$actual_suite" == "$DEBIAN_SUITE" ]] ||
  die "debian/changelog distribution is $actual_suite, expected $DEBIAN_SUITE"
[[ "$actual_source" == "$SOURCE_NAME" ]] ||
  die "debian/changelog source is $actual_source, expected $SOURCE_NAME"

{
  printf 'SOURCE_DIR=%q\n' "$SOURCE_DIR"
  printf 'DEB_VERSION=%q\n' "$DEB_VERSION"
  printf 'DEBIAN_BASE_VERSION=%q\n' "$DEBIAN_BASE_VERSION"
  printf 'DEBIAN_SUITE=%q\n' "$DEBIAN_SUITE"
  printf 'ARCHITECTURE=%q\n' "$ARCHITECTURE"
  printf 'SOURCE_DSC=%q\n' "$SOURCE_DSC"
  printf 'SOURCE_DSC_SHA256=%q\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_DSC}")"
  printf 'SOURCE_ORIG=%q\n' "$SOURCE_ORIG"
  printf 'SOURCE_ORIG_SHA256=%q\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_ORIG}")"
  printf 'SOURCE_ORIG_DOC=%q\n' "$SOURCE_ORIG_DOC"
  printf 'SOURCE_ORIG_DOC_SHA256=%q\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_ORIG_DOC}")"
  printf 'SOURCE_DEBIAN_TAR=%q\n' "$SOURCE_DEBIAN_TAR"
  printf 'SOURCE_DEBIAN_TAR_SHA256=%q\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_DEBIAN_TAR}")"
} > "${BUILD_DIR}/source.env"

{
  printf 'source package: %s\n' "$SOURCE_NAME"
  printf 'official Debian version: %s\n' "$DEBIAN_BASE_VERSION"
  printf 'downstream version: %s\n' "$DEB_VERSION"
  printf 'suite: %s\n' "$DEBIAN_SUITE"
  printf 'architecture: %s\n' "$ARCHITECTURE"
  printf 'downloaded: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'repository commit: %s\n' "$(git_commit)"
  printf 'repository dirty: %s\n' "$(git_dirty)"
  printf '\nArtifacts:\n'
  printf '  %s  %s\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_DSC}")" "$SOURCE_DSC"
  printf '  %s  %s\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_ORIG}")" "$SOURCE_ORIG"
  printf '  %s  %s\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_ORIG_DOC}")" "$SOURCE_ORIG_DOC"
  printf '  %s  %s\n' "$(sha256_of "${CACHE_DIR}/${SOURCE_DEBIAN_TAR}")" "$SOURCE_DEBIAN_TAR"
  printf '\nSignature verification:\n'
  sed 's/^/  /' "${LOG_DIR}/dsc-signature.txt"
} > "${BUILD_DIR}/source-provenance.txt"

ok "source tree ready at ${SOURCE_DIR} (version ${DEB_VERSION})"
