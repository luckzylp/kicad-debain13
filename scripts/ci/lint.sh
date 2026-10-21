#!/usr/bin/env bash
# Fast repository checks for pull requests.  No package build is performed.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

require_cmd bash shellcheck yamllint python3 git
mkdir -p "$REPORT_DIR"

mapfile -t shell_files < <(
  find "$REPO_ROOT/scripts" "$REPO_ROOT/tests" \
    -type f -name '*.sh' -print | LC_ALL=C sort
)

log "syntax-checking ${#shell_files[@]} shell scripts"
for file in "${shell_files[@]}"; do
  bash -n "$file"
done

log "running shellcheck"
shellcheck --version > "${REPORT_DIR}/shellcheck-version.txt"
shellcheck -x "${shell_files[@]}" 2>&1 | tee "${REPORT_DIR}/shellcheck.txt"

log "running yamllint"
yamllint -c "${REPO_ROOT}/.yamllint" \
  "${REPO_ROOT}/.github/workflows" \
  "${REPO_ROOT}/.github/actions" \
  2>&1 | tee "${REPORT_DIR}/yamllint.txt"

if [[ -x "${REPO_ROOT}/.cache/tools/actionlint" ]]; then
  log "running actionlint"
  "${REPO_ROOT}/.cache/tools/actionlint" \
    -config-file "${REPO_ROOT}/.github/actionlint.yaml" \
    -color "${REPO_ROOT}/.github/workflows"/*.yml \
    2>&1 | tee "${REPORT_DIR}/actionlint.txt"
else
  warn "actionlint is not installed; run scripts/install-ci-tools.sh for full workflow linting"
fi

log "compiling Python helpers"
python3 -m py_compile \
  "${REPO_ROOT}/scripts/compare_debian_packaging.py" \
  "${REPO_ROOT}/scripts/make-build-info.py"
find "$REPO_ROOT/scripts" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

log "validating version manifest"
"${REPO_ROOT}/scripts/validate-manifest.sh"

log "verifying vendored Debian packaging provenance"
"${REPO_ROOT}/scripts/verify-packaging-provenance.sh"

# Defence in depth: this repository must never use the privileged
# pull_request_target trigger.
if grep -Rqs 'pull_request_target' "${REPO_ROOT}/.github"; then
  die "pull_request_target is forbidden in this repository"
fi

# No workflow may add a sid apt source; Trixie binaries are the whole point.
if grep -RqsE 'Suites:.*sid|deb .* sid ' "${REPO_ROOT}/.github"; then
  die "workflows must not add a sid apt source"
fi

ok "CI lint checks passed"
