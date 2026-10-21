#!/usr/bin/env bash
# Create a deterministic SHA256SUMS over every release asset except the
# checksum file and its signature.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_versions
require_cmd sha256sum

[[ -d "$DIST_DIR" ]] || die "no dist directory: $DIST_DIR"

# Include reports/ recursively, keep paths relative, and exclude only the
# checksum file and its signature.
mapfile -t assets < <(
  cd "$DIST_DIR"
  find . -type f -printf '%P\n' |
    LC_ALL=C sort |
    while IFS= read -r path; do
      [[ "$path" == "SHA256SUMS" || "$path" == "SHA256SUMS.asc" ]] && continue
      printf '%s\n' "$path"
    done
)
(( ${#assets[@]} > 0 )) || die "no release assets found in $DIST_DIR"

(
  cd "$DIST_DIR"
  sha256sum -- "${assets[@]}" > SHA256SUMS
)

ok "wrote ${DIST_DIR}/SHA256SUMS with ${#assets[@]} asset(s)"
sed 's/^/  /' "${DIST_DIR}/SHA256SUMS" >&2
