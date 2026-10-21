SHELL := /bin/bash
.DEFAULT_GOAL := help

SCOPE ?= arch
JOBS ?= $(shell nproc)
CONTAINER_ENGINE ?= docker
DEBIAN_IMAGE := debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308

.PHONY: help prepare tools source provenance deps-check deps build test audit checksums \
        build-info smoke all lint clean distclean container-shell release-check

help:
	@printf '%s\n' \
	  'KiCad Debian 13 build targets:' \
	  '  make prepare       Clean build/dist and check resources' \
	  '  make tools         Install packaging tools (sudo)' \
	  '  make source        Fetch/authenticate official Debian source' \
	  '  make provenance    Compare debian/ with official packaging' \
	  '  make deps-check    Resolve Build-Depends against Trixie only' \
	  '  make deps          Install Build-Depends (sudo)' \
	  '  make build         Build package (SCOPE=arch|full, JOBS=N)' \
	  '  make test          Static package/file-layout checks' \
	  '  make audit         Lintian and metadata audit' \
	  '  make checksums     Write dist/SHA256SUMS' \
	  '  make build-info    Write dist/build-info.json and refresh checksums' \
	  '  make smoke         Install/purge test (root, disposable env only)' \
	  '  make all           source + deps-check + build + test + audit + checksums' \
	  '  make lint          shellcheck/yamllint/actionlint/provenance checks' \
	  '  make clean         Remove build/ and dist/' \
	  '  make distclean     Also remove .cache/' \
	  '  make container-shell  Open a Debian 13 container at the repo root' \
	  '  make release-check TAG=v10.0.7  Validate the tag against the manifest'

prepare:
	./scripts/prepare-workspace.sh

tools:
	sudo ./scripts/install-build-tools.sh

source:
	./scripts/fetch-source.sh

provenance:
	./scripts/verify-packaging-provenance.sh

deps-check:
	./scripts/check-build-deps.sh

deps:
	sudo ./scripts/install-build-deps.sh

build:
	JOBS="$(JOBS)" ./scripts/build-deb.sh --scope "$(SCOPE)" --jobs "$(JOBS)"

test:
	./scripts/test-package.sh

audit:
	./scripts/audit-package.sh

checksums:
	./scripts/make-checksums.sh

build-info:
	python3 ./scripts/make-build-info.py --scope "$(SCOPE)" --runner local
	./scripts/make-checksums.sh

smoke:
	sudo ./tests/package-smoke-test.sh

all: prepare source deps-check build test audit checksums

lint:
	./scripts/ci/lint.sh

release-check:
	./scripts/validate-release-tag.sh "$(TAG)"

clean:
	rm -rf build dist

distclean: clean
	rm -rf .cache

container-shell:
	$(CONTAINER_ENGINE) run --rm -it \
	  -v "$(CURDIR):/work" \
	  -w /work \
	  "$(DEBIAN_IMAGE)" \
	  bash
