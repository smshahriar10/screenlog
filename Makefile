# Makefile - screenlog. Compatible with GNU make 3.81 (macOS) and 4.3 (Ubuntu):
# no .ONESHELL / != / $(file) / undefine; recipes are POSIX sh.
# On macOS, lint and test targets run inside the ubuntu:24.04 test image (tests/Dockerfile).
SHELL := /bin/sh

VERSION      := $(shell cat VERSION)
UNAME_S      := $(shell uname -s)
DOCKER       ?= docker
# Image tag = checksum of the Dockerfile: editing it yields a new tag and an automatic rebuild.
IMAGE_TAG    := $(shell cksum tests/Dockerfile 2>/dev/null | cut -d' ' -f1)
DOCKER_IMAGE ?= screenlog-test:$(IMAGE_TAG)
BATS_BASE_FLAGS := --print-output-on-failure
BATS_FLAGS   ?=
DIST         ?= dist
BUNDLE       := $(DIST)/screenlog-$(VERSION)

SCRIPTS    := $(wildcard bin/*) $(wildcard install.sh uninstall.sh) $(wildcard lib/*.sh) \
              $(wildcard tests/stubs/*) $(wildcard tests/helpers/*.bash) $(wildcard tests/fixtures/*.sh)
BATS_FILES := $(wildcard tests/unit/*.bats) $(wildcard tests/integration/*.bats)

DOCKER_OK  = command -v $(DOCKER) >/dev/null 2>&1 && $(DOCKER) info >/dev/null 2>&1
# --rm: throwaway. --init: PID 1 reaps Xvfb/ffmpeg/sleep and forwards SIGTERM.
# --network none: nothing in the suite may touch the network; a missed stub fails loudly.
# :ro mount: tests never write into the repo (everything goes under /tmp in the container).
# -it only when both stdin and stdout are terminals (decided inside the recipe, not via $(shell)).
DOCKER_RUN = $(DOCKER) run --rm $$( [ -t 0 ] && [ -t 1 ] && echo -it ) --init --network none \
             -v "$(CURDIR):/work:ro" -w /work -e TERM -e CI -e NO_COLOR $(DOCKER_IMAGE)

.PHONY: all lint lint-native test test-integration test-all bundle clean shell \
        docker-check docker-image docker-rebuild docker-clean \
        check-lint-tools check-test-tools check-x-tools

all: lint test

ifeq ($(UNAME_S),Linux)
# ---------- native: Ubuntu host, CI runner, or inside the container ----------
TAR_FLAGS := --owner=root --group=root --numeric-owner --no-xattrs
check-lint-tools:
	@command -v shellcheck >/dev/null 2>&1 || { echo "missing: shellcheck (apt install shellcheck)"; exit 1; }
check-test-tools:
	@for t in bats convert identify jq file awk flock; do command -v $$t >/dev/null 2>&1 || \
	  { echo "missing tool: $$t (see tests/Dockerfile)"; exit 1; }; done
	@[ -f /usr/lib/bats/bats-assert/load.bash ] || { echo "missing: bats-support bats-assert bats-file"; exit 1; }
check-x-tools:
	@for t in Xvfb xauth xdpyinfo xsetroot xprintidle ffmpeg montage setpriv pgrep /usr/bin/time; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing tool: $$t (see tests/Dockerfile)"; exit 1; }; done
lint: check-lint-tools lint-native
test: check-test-tools
	bats $(BATS_BASE_FLAGS) $(BATS_FLAGS) tests/unit
test-integration: check-test-tools check-x-tools
	bats $(BATS_BASE_FLAGS) $(BATS_FLAGS) tests/integration
else
# ---------- macOS (or anything else): delegate to the container ----------
TAR_FLAGS := --no-xattrs --no-mac-metadata --no-acls --no-fflags --uid 0 --gid 0 --uname root --gname root
docker-check:
	@command -v $(DOCKER) >/dev/null 2>&1 || { echo "docker CLI not installed: brew install colima docker && colima start"; exit 1; }
	@$(DOCKER) info >/dev/null 2>&1 || { echo "docker daemon not reachable (Colima stopped?): colima start"; exit 1; }

docker-image: docker-check
	@$(DOCKER) image inspect $(DOCKER_IMAGE) >/dev/null 2>&1 || { \
	  if $(DOCKER) buildx version >/dev/null 2>&1; then bk=1; else bk=0; fi; \
	  echo "building $(DOCKER_IMAGE) (first time: 2-5 min, about 1 GB of packages)"; \
	  DOCKER_BUILDKIT=$$bk $(DOCKER) build -t $(DOCKER_IMAGE) - < tests/Dockerfile; }

docker-rebuild: docker-check
	@if $(DOCKER) buildx version >/dev/null 2>&1; then bk=1; else bk=0; fi; \
	  DOCKER_BUILDKIT=$$bk $(DOCKER) build --no-cache --pull -t $(DOCKER_IMAGE) - < tests/Dockerfile

docker-clean:
	-$(DOCKER) image ls --filter reference='screenlog-test' -q | xargs $(DOCKER) rmi

lint:
	@if $(DOCKER_OK); then $(MAKE) docker-image && $(DOCKER_RUN) make lint; \
	elif command -v shellcheck >/dev/null 2>&1; then \
	  echo "WARNING: Docker unavailable; running host shellcheck (the container pins 0.9.0)"; $(MAKE) lint-native; \
	else echo "Docker unavailable and no host shellcheck: brew install shellcheck (partial) or colima start (full)"; exit 1; fi

test test-integration:
	@if $(DOCKER_OK); then $(MAKE) docker-image && $(DOCKER_RUN) make $@ BATS_FLAGS='$(BATS_FLAGS)'; \
	else $(MAKE) docker-check || true; $(MAKE) lint || true; \
	  echo "ERROR: $@ NOT run: bats tests need the ubuntu:24.04 container (see above)."; exit 1; fi

shell: docker-image
	$(DOCKER_RUN) bash
endif

lint-native:
	shellcheck -x -P SCRIPTDIR:. -f gcc $(SCRIPTS) $(BATS_FILES)
	@! grep -rnE 'set -[A-Za-z]*x([[:space:]]|$$)|set -o xtrace|bash -x' bin lib install.sh uninstall.sh 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' \
	  || { echo "lint: 'set -x' is not allowed"; exit 1; }
	@echo "lint: ok"

test-all: lint test test-integration

# bundle runs natively everywhere (on the Mac it must). Secrets are never copied: the owner puts
# config/screenlog.conf and config/rclone.conf into the bundle's config/ folder afterwards.
bundle:
	@test -n "$(VERSION)" || { echo "VERSION is empty"; exit 1; }
	@grep -q "^## \[$(VERSION)\]" CHANGELOG.md || { echo "CHANGELOG.md has no entry for $(VERSION)"; exit 1; }
	rm -rf "$(BUNDLE)" "$(BUNDLE).tar.gz"
	mkdir -p "$(BUNDLE)/config" "$(BUNDLE)/vendor"
	cp -R bin lib systemd docs "$(BUNDLE)/"
	cp README.md CHANGELOG.md VERSION install.sh uninstall.sh "$(BUNDLE)/"
	cp config/screenlog.conf.example "$(BUNDLE)/config/"
	@if ls vendor/rclone-*.deb >/dev/null 2>&1; then cp vendor/rclone-*.deb "$(BUNDLE)/vendor/"; \
	  cp vendor/SHA256SUMS "$(BUNDLE)/vendor/" 2>/dev/null || true; fi
	find "$(BUNDLE)" -name .DS_Store -delete
	find "$(BUNDLE)" -type d -exec chmod 755 {} +
	find "$(BUNDLE)" -type f -exec chmod 644 {} +
	chmod 755 "$(BUNDLE)/install.sh" "$(BUNDLE)/uninstall.sh" "$(BUNDLE)"/bin/*
	@test ! -e "$(BUNDLE)/config/screenlog.conf" && test ! -e "$(BUNDLE)/config/rclone.conf"
	cd "$(DIST)" && COPYFILE_DISABLE=1 tar $(TAR_FLAGS) -czf "screenlog-$(VERSION).tar.gz" "screenlog-$(VERSION)"
	@echo "bundle: $(BUNDLE)/ and $(BUNDLE).tar.gz"
	@echo "next: copy the filled-in config/screenlog.conf and config/rclone.conf into $(BUNDLE)/config/"

clean:
	rm -rf "$(DIST)"
