#!/usr/bin/env bash
# Shared helpers for the kicad-debian13 build scripts.
#
# This file is intended to be sourced, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${CACHE_DIR:-${REPO_ROOT}/.cache/downloads}"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
REPORT_DIR="${REPORT_DIR:-${BUILD_DIR}/reports}"
LOG_DIR="${LOG_DIR:-${BUILD_DIR}/logs}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_RED=""
  C_YELLOW=""
  C_GREEN=""
  C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

load_versions() {
  local file="${REPO_ROOT}/packaging/versions.env"
  [[ -r "$file" ]] || die "missing version manifest: $file"
  # shellcheck disable=SC1090
  source "$file"

  local var
  for var in UPSTREAM_VERSION DEBIAN_BASE_VERSION DFSG_UPSTREAM_VERSION \
             DEBIAN_BASE_REVISION DOWNSTREAM_REVISION DEB_VERSION \
             SOURCE_NAME BINARY_PACKAGE DEBIAN_SUITE ARCHITECTURE RELEASE_TAG \
             DEBIAN_MIRROR DEBIAN_POOL_PATH SOURCE_DSC SOURCE_ORIG \
             SOURCE_ORIG_DOC SOURCE_DEBIAN_TAR BUILD_SCOPE; do
    [[ -n "${!var:-}" ]] || die "version manifest is missing $var"
  done

  [[ "$DEB_VERSION" == "${DFSG_UPSTREAM_VERSION}-${DOWNSTREAM_REVISION}" ]] ||
    die "DEB_VERSION ($DEB_VERSION) does not match <dfsg-upstream>-<downstream-revision>"
  [[ "$DEBIAN_BASE_VERSION" == "${DFSG_UPSTREAM_VERSION}-${DEBIAN_BASE_REVISION}" ]] ||
    die "DEBIAN_BASE_VERSION ($DEBIAN_BASE_VERSION) is inconsistent"
  [[ "$ARCHITECTURE" == "amd64" ]] ||
    die "this repository intentionally supports amd64 only (got $ARCHITECTURE)"
  [[ "$DEBIAN_SUITE" == "trixie" ]] ||
    die "this repository intentionally targets trixie only (got $DEBIAN_SUITE)"
}

require_debian_13() {
  [[ "${SKIP_OS_CHECK:-0}" == "1" ]] && return 0
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] ||
    die "build must run on Debian 13 (found ID=${ID:-unknown})"
  [[ "${VERSION_ID:-}" == "13" ]] ||
    die "build must run on Debian 13 (found VERSION_ID=${VERSION_ID:-unknown})"
}

check_disk_space() {
  local path="$1" min_gb="$2" avail_gb
  mkdir -p "$path"
  avail_gb=$(df -Pk "$path" | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if (( avail_gb < min_gb )); then
    die "not enough free disk space under $path: ${avail_gb} GiB available, ${min_gb} GiB required"
  fi
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || return 1
  actual="$(sha256_of "$file")"
  [[ "$actual" == "$expected" ]]
}

# download_verified URL DEST EXPECTED_SHA256
# Re-downloads on mismatch, never leaves a partially verified file in place.
download_verified() {
  local url="$1" dest="$2" expected="$3" attempt
  local tmp="${dest}.part"

  if verify_sha256 "$dest" "$expected"; then
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  for attempt in 1 2 3 4; do
    log "downloading $(basename "$dest") (attempt ${attempt}/4)"
    rm -f "$tmp"
    if curl --fail --location --silent --show-error \
         --retry 3 --retry-all-errors --retry-delay 2 \
         --connect-timeout 20 --max-time 1800 \
         --proto '=https' --tlsv1.2 \
         --output "$tmp" "$url"; then
      if verify_sha256 "$tmp" "$expected"; then
        mv -f "$tmp" "$dest"
        return 0
      fi
      warn "checksum mismatch for $(basename "$dest"); retrying"
    else
      warn "download failed for $url; retrying"
    fi
    sleep $((attempt * 2))
  done
  rm -f "$tmp"
  die "could not download and verify $url"
}

# safe_remove PATH: refuse to remove anything outside the repository.
safe_remove() {
  local path="$1" resolved
  resolved="$(realpath -m "$path")"
  case "$resolved" in
    "${REPO_ROOT}"/*) ;;
    *) die "refusing to remove path outside repository: $resolved" ;;
  esac
  [[ "$resolved" != "$REPO_ROOT" ]] || die "refusing to remove the repository root"
  rm -rf -- "$resolved"
}

git_commit() {
  local sha
  if sha="$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
    printf '%s\n' "$sha"
  else
    printf 'unknown\n'
  fi
}

git_dirty() {
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
  else
    printf 'unknown\n'
  fi
}

# Print the source directory produced by fetch-source.sh.
source_dir() {
  printf '%s/source\n' "$BUILD_DIR"
}

# Load build/source.env written by fetch-source.sh, if present.
load_source_env() {
  local file="${BUILD_DIR}/source.env"
  [[ -r "$file" ]] || die "missing $file; run scripts/fetch-source.sh first"
  # shellcheck disable=SC1090
  source "$file"
  [[ -d "${SOURCE_DIR:-}" ]] || die "SOURCE_DIR does not exist: ${SOURCE_DIR:-unset}"
}

# apt-get wrapper.  It handles sudo itself because shell functions cannot be
# passed to sudo.  apt's -y plus the dpkg force options avoid configuration
# prompts, so DEBIAN_FRONTEND does not need to be preserved across sudo.
apt_get() {
  local -a cmd=(
    apt-get
    -o Acquire::Retries=5
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
  )
  if [[ ${EUID} -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive "${cmd[@]}" "$@"
  else
    command -v sudo >/dev/null 2>&1 ||
      die "apt-get needs root or passwordless sudo"
    DEBIAN_FRONTEND=noninteractive sudo -- "${cmd[@]}" "$@"
  fi
}
