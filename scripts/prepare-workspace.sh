#!/usr/bin/env bash
# Clean previous build output, check resources, and write an environment report.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_debian_13
require_cmd df nproc uname

SCOPE="${SCOPE:-$BUILD_SCOPE}"
case "$SCOPE" in
  arch) min_disk=7; recommended=20 ;;
  full) min_disk=25; recommended=30 ;;
  *) die "invalid scope: $SCOPE" ;;
esac

safe_remove "$BUILD_DIR"
safe_remove "$DIST_DIR"
check_disk_space "$REPO_ROOT" "$min_disk"
avail_gb=$(df -Pk "$REPO_ROOT" | awk 'NR==2 {printf "%d", $4/1024/1024}')
if (( avail_gb < recommended )); then
  warn "only ${avail_gb} GiB free; ${recommended} GiB is recommended for scope=${SCOPE}"
  warn "a GitHub-hosted runner has ~14 GiB; use the self-hosted Debian 13 VM for reliable releases"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$REPORT_DIR" "$LOG_DIR" "$CACHE_DIR"

mem_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
if (( mem_kib < 8 * 1024 * 1024 )); then
  warn "less than 8 GiB RAM detected; parallel linking may be slow or fail"
fi

{
  printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'version: %s\n' "$DEB_VERSION"
  printf 'scope: %s\n' "$SCOPE"
  printf 'architecture: %s\n' "$ARCHITECTURE"
  printf 'kernel: %s\n' "$(uname -srmo)"
  printf 'cpus: %s\n' "$(nproc)"
  printf 'memory: %s MiB\n' "$((mem_kib / 1024))"
  printf 'disk available: %s\n' "$(df -Ph "$REPO_ROOT" | awk 'NR==2 {print $4}')"
  printf 'repository commit: %s\n' "$(git_commit)"
  printf 'repository dirty: %s\n' "$(git_dirty)"
  printf 'runner: %s\n' "${RUNNER_NAME:-local}"
  printf 'workflow: %s\n' "${GITHUB_WORKFLOW:-local}"
  printf 'run id: %s\n' "${GITHUB_RUN_ID:-local}"
} | tee "${REPORT_DIR}/environment.txt"

ok "workspace prepared"
