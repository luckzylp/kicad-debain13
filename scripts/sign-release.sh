#!/usr/bin/env bash
# Import the release signing key from the environment, verify its fingerprint,
# regenerate SHA256SUMS over every asset, and create SHA256SUMS.asc.
#
# Required environment:
#   RELEASE_GPG_PRIVATE_KEY   ASCII-armored private key (GitHub secret)
#   RELEASE_KEY_FINGERPRINT   expected full fingerprint (repository variable)
# Optional:
#   RELEASE_GPG_PASSPHRASE    passphrase; omit for an unprotected key

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
[[ -d "$DIST_DIR" ]] || die "no dist directory: $DIST_DIR"
require_cmd gpg gpgconf sha256sum

[[ -n "${RELEASE_GPG_PRIVATE_KEY:-}" ]] ||
  die "RELEASE_GPG_PRIVATE_KEY is not set"
[[ -n "${RELEASE_KEY_FINGERPRINT:-}" ]] ||
  die "RELEASE_KEY_FINGERPRINT is not set (repository variable)"

expected_fpr="$(tr -d '[:space:]' <<<"${RELEASE_KEY_FINGERPRINT}" | tr '[:lower:]' '[:upper:]')"
[[ "$expected_fpr" =~ ^[0-9A-F]{40}$ ]] ||
  die "RELEASE_KEY_FINGERPRINT must be a full 40-hex fingerprint"

GNUPGHOME="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kicad-release-gnupg.XXXXXX")"
export GNUPGHOME
chmod 700 "$GNUPGHOME"

cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf -- "$GNUPGHOME"
}
trap cleanup EXIT

log "importing the release signing key"
printf '%s' "$RELEASE_GPG_PRIVATE_KEY" |
  gpg --batch --homedir "$GNUPGHOME" --import >/dev/null 2>&1 ||
  die "could not import RELEASE_GPG_PRIVATE_KEY"

actual_fpr="$(gpg --batch --homedir "$GNUPGHOME" --with-colons \
  --list-secret-keys 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')"
[[ -n "$actual_fpr" ]] || die "no secret key found after import"
actual_fpr="$(tr '[:lower:]' '[:upper:]' <<<"$actual_fpr")"

if [[ "$actual_fpr" != "$expected_fpr" ]]; then
  cat >&2 <<EOF
Release key fingerprint mismatch:
  expected: $expected_fpr
  imported: $actual_fpr
Refusing to sign with an unexpected key.
EOF
  exit 1
fi

log "exporting the public key for the release"
gpg --batch --homedir "$GNUPGHOME" --armor --export "$actual_fpr" \
  > "${DIST_DIR}/release-key.asc"
[[ -s "${DIST_DIR}/release-key.asc" ]] || die "public key export is empty"

log "regenerating checksums over all release assets"
DIST_DIR="$DIST_DIR" "${REPO_ROOT}/scripts/make-checksums.sh"

log "signing SHA256SUMS with ${actual_fpr}"
if [[ -n "${RELEASE_GPG_PASSPHRASE:-}" ]]; then
  printf '%s' "$RELEASE_GPG_PASSPHRASE" |
    gpg --batch --yes --homedir "$GNUPGHOME" \
      --pinentry-mode loopback --passphrase-fd 0 \
      --local-user "$actual_fpr" \
      --armor --detach-sign "${DIST_DIR}/SHA256SUMS"
else
  gpg --batch --yes --homedir "$GNUPGHOME" \
    --pinentry-mode loopback \
    --local-user "$actual_fpr" \
    --armor --detach-sign "${DIST_DIR}/SHA256SUMS"
fi

gpg --batch --homedir "$GNUPGHOME" \
  --verify "${DIST_DIR}/SHA256SUMS.asc" "${DIST_DIR}/SHA256SUMS" \
  >/dev/null 2>&1 || die "signature verification failed immediately after signing"

ok "signed ${DIST_DIR}/SHA256SUMS"
printf 'release key fingerprint: %s\n' "$actual_fpr"
