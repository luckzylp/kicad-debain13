#!/usr/bin/env bash
# Install fast, read-only CI checks (does not install the KiCad toolchain).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_debian_13
require_cmd apt-get

log "installing CI lint/provenance tools"
apt_get update
apt_get install -y --no-install-recommends \
  ca-certificates \
  curl \
  debian-keyring \
  devscripts \
  dpkg-dev \
  file \
  git \
  gnupg \
  gpgv \
  python3 \
  python3-yaml \
  shellcheck \
  xz-utils \
  yamllint

# actionlint is not packaged in trixie.  Pin both the release and its digest
# so a compromised download cannot silently change CI behaviour.
ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ACTIONLINT_DIR="${REPO_ROOT}/.cache/tools"
ACTIONLINT_TARBALL="${ACTIONLINT_DIR}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"

if [[ -x "${ACTIONLINT_DIR}/actionlint" ]] && \
   ! "${ACTIONLINT_DIR}/actionlint" --version 2>/dev/null | grep -Fxq "${ACTIONLINT_VERSION}"; then
  rm -f "${ACTIONLINT_DIR}/actionlint"
fi

if [[ ! -x "${ACTIONLINT_DIR}/actionlint" ]]; then
  mkdir -p "$ACTIONLINT_DIR"
  download_verified \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
    "$ACTIONLINT_TARBALL" \
    "$ACTIONLINT_SHA256"
  tar -xzf "$ACTIONLINT_TARBALL" -C "$ACTIONLINT_DIR" actionlint
  chmod 0755 "${ACTIONLINT_DIR}/actionlint"
fi

"${ACTIONLINT_DIR}/actionlint" --version >&2
ok "CI tools installed"
