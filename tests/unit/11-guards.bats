#!/usr/bin/env bats
# Static guards over the source tree: conventions the design relies on.
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

# src_files [EXCEPT]: every script that exists so far (phases add files), minus basename EXCEPT.
src_files() {
  local f
  for f in "$REPO_ROOT"/bin/* "$REPO_ROOT"/lib/*.sh "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = "${1:-}" ] && continue
    printf '%s\n' "$f"
  done
  return 0
}

# offending PATTERN FILE...: matching lines that are not comments and not tagged guard:ok
offending() {
  local pat=$1
  shift
  grep -nE "$pat" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'guard:ok' || true
}

@test "guards: no set -x or xtrace anywhere in the scripts" {
  mapfile -t files < <(src_files)
  run offending 'set -x|set -o xtrace' "${files[@]}"
  assert_output ""
}

@test "guards: date is only called from lib/time.sh" {
  mapfile -t files < <(src_files time.sh)
  run offending '(^|[^A-Za-z_./-])date([^A-Za-z_-]|$)' "${files[@]}"
  assert_output ""
}

@test "guards: tools are called by bare name, sudo is never run, \$HOSTNAME is never read" {
  mapfile -t files < <(src_files)
  # shellcheck disable=SC2016
  run offending '/usr/bin/(curl|rclone|ffmpeg|xprintidle|loginctl|jq)|(^|[;&|]|\$\()[[:space:]]*sudo |\$HOSTNAME' "${files[@]}"
  assert_output ""
}

@test "guards: the code never assigns PATH" {
  mapfile -t files < <(src_files)
  run offending '^[[:space:]]*(export )?PATH=' "${files[@]}"
  assert_output ""
}

@test "guards: system-path literals live only in lib/config.sh" {
  mapfile -t files < <(src_files config.sh)
  run offending '(/etc/|/opt/|/run/user|/usr/local/|/tmp/\.X11|/var/lib/)' "${files[@]}"
  assert_output ""
}

@test "guards: every lib sources cleanly under bash -u and defines no top-level side effects" {
  local f
  for f in "$REPO_ROOT"/lib/*.sh; do
    run bash -u -c 'source "$1"' _ "$f"
    assert_success
    assert_output ""
  done
}

@test "guards: entry points use the shell options the design requires" {
  local f
  for f in "$REPO_ROOT"/bin/*; do
    [ -f "$f" ] || skip "no bin/ scripts yet"
    run grep -c '^set -uo pipefail$' "$f"
    assert_output 1
  done
  for f in "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"; do
    [ -f "$f" ] || continue
    run grep -c '^set -euo pipefail$' "$f"
    assert_output 1
  done
}

@test "guards: .gitignore keeps secrets, vendor and dist out of git" {
  local line
  for line in config/screenlog.conf config/rclone.conf vendor/ dist/; do
    run grep -qxF "$line" "$REPO_ROOT/.gitignore"
    assert_success
  done
}

@test "guards: the gap generator seeds from /dev/urandom and never uses the shell's random variable" {
  run grep -c '/dev/urandom' "$REPO_ROOT/lib/gap.sh"
  assert_success
  # shellcheck disable=SC2016
  run grep -n '\$RANDOM' "$REPO_ROOT/lib/gap.sh"
  assert_failure
}

@test "guards: contact sheet thumbnails use the jpeg:size read hint" {
  [ -f "$REPO_ROOT/lib/sheet.sh" ] || skip "lib/sheet.sh arrives in phase 4"
  run grep -c 'jpeg:size' "$REPO_ROOT/lib/sheet.sh"
  assert_success
}

@test "guards: the test image mirrors install.sh's apt package list" {
  [ -f "$REPO_ROOT/install.sh" ] || skip "install.sh arrives in phase 6"
  local mirror apt
  mirror=$(sed -n 's/^#   \(ffmpeg .*\)$/\1/p' "$REPO_ROOT/tests/Dockerfile" | head -n1)
  apt=$(sed -n 's/^APT_PACKAGES="\(.*\)"$/\1/p' "$REPO_ROOT/install.sh")
  assert_equal "$apt" "$mirror"
}
