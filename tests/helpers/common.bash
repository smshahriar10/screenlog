# shellcheck shell=bash
# tests/helpers/common.bash - shared setup for every bats file (sourced, not loaded, so that
# `shellcheck -x` follows it). Every test gets a private SCREENLOG_* world under its tmp dir and a
# stub dir at the front of PATH; the repo is never written to.
bats_require_minimum_version 1.5.0
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME:?}/../.." && pwd)"
export REPO_ROOT
export SCREENLOG_HOME="$REPO_ROOT"
export TZ=Asia/Dhaka LANG=C.UTF-8 LC_ALL=C.UTF-8
export SCREENLOG_DISCORD_BACKOFF="0 0 0"     # no real sleeps between Discord retries
export SCREENLOG_ANNOUNCE_INTERVAL=0.2       # announcement poll; the code clamps anything below 0.2
export SCREENLOG_LOCK_WAIT=5                 # a deadlock on rclone.lock fails in 5 s, not 900

# shellcheck source=lib/log.sh
source "$REPO_ROOT/lib/log.sh"
# shellcheck source=lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=lib/time.sh
source "$REPO_ROOT/lib/time.sh"
# shellcheck source=lib/gap.sh
source "$REPO_ROOT/lib/gap.sh"
# shellcheck source=lib/slug.sh
source "$REPO_ROOT/lib/slug.sh"
# shellcheck source=lib/session.sh
source "$REPO_ROOT/lib/session.sh"
# shellcheck source=lib/capture.sh
source "$REPO_ROOT/lib/capture.sh"
# shellcheck source=lib/sample.sh
source "$REPO_ROOT/lib/sample.sh"

# screenlog_test_setup: the base dir is BATS_TEST_TMPDIR (per test). From setup_file, where bats
# 1.10 does not set BATS_TEST_TMPDIR, export SCREENLOG_TEST_BASE_DIR="$BATS_FILE_TMPDIR/filesetup" first.
screenlog_test_setup() {
  local base=${BATS_TEST_TMPDIR:-${SCREENLOG_TEST_BASE_DIR:?screenlog_test_setup: no base dir}}
  export SCREENLOG_TEST_BASE="$base"
  export SCREENLOG_SYSROOT="$base/sys"
  export SCREENLOG_DATA_DIR="$base/data"
  export SCREENLOG_CONFIG="$base/etc/screenlog.conf"
  export SCREENLOG_RCLONE_CONF="$base/etc/rclone.conf"
  export TMPDIR="$base/tmp"
  export STUB_LOG_DIR="$base/stub-log"
  export STUB_REMOTE_DIR="$base/remote"
  mkdir -p "$SCREENLOG_DATA_DIR" "$base/etc" "$base/bin" "$TMPDIR" "$STUB_LOG_DIR" "$STUB_REMOTE_DIR" \
    "$SCREENLOG_SYSROOT/etc/systemd/system" "$SCREENLOG_SYSROOT/run/user/1000" "$SCREENLOG_SYSROOT/tmp/.X11-unix"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  cp "$REPO_ROOT/tests/fixtures/rclone.conf" "$SCREENLOG_RCLONE_CONF"
  chmod 600 "$SCREENLOG_CONFIG" "$SCREENLOG_RCLONE_CONF"
  export SCREENLOG_NOW="2026-10-15T10:00:00+06:00"   # a Thursday, inside capture hours
  export JOURNAL_STREAM=9:1                           # log lines without timestamps, as under systemd
  # stubs first (they shadow real tools), then the code under test, then the system
  export PATH="$base/bin:$REPO_ROOT/bin:$PATH"
  paths_init
}

# use_stubs NAME...: put the named stubs from tests/stubs on PATH for this test.
use_stubs() {
  local s
  for s in "$@"; do
    ln -sf "$REPO_ROOT/tests/stubs/$s" "${SCREENLOG_TEST_BASE:?}/bin/$s"
  done
}

set_now() { export SCREENLOG_NOW="$1"; }

# set_config KEY VALUE [KEY VALUE...]: rewrite or append KEY="VALUE" in the test config.
# awk reads the values through ENVIRON (not -v, which would expand backslash escapes).
set_config() {
  while [ $# -ge 2 ]; do
    k="$1" v="$2" awk 'BEGIN { k = ENVIRON["k"]; v = ENVIRON["v"]; line = k "=\"" v "\"" }
      index($0, k "=") == 1 { print line; done = 1; next }
      { print }
      END { if (!done) print line }' "${SCREENLOG_CONFIG:?}" > "$SCREENLOG_CONFIG.new" \
      && mv "$SCREENLOG_CONFIG.new" "$SCREENLOG_CONFIG"
    shift 2
  done
}

# unset_config KEY...: remove the key's line from the test config.
unset_config() {
  local key
  for key in "$@"; do
    k="$key" awk 'index($0, ENVIRON["k"] "=") != 1' "${SCREENLOG_CONFIG:?}" > "$SCREENLOG_CONFIG.new" \
      && mv "$SCREENLOG_CONFIG.new" "$SCREENLOG_CONFIG"
  done
}

# append_config_line RAW: append a raw line (for syntax and injection tests).
append_config_line() { printf '%s\n' "$1" >> "${SCREENLOG_CONFIG:?}"; }

mark_reported() {
  mkdir -p "${SCREENLOG_DATA_DIR:?}/state"
  printf '%s\n' "$1" >> "$SCREENLOG_DATA_DIR/state/reported-days"
}

# stub_calls NAME: number of recorded invocations of a stub.
stub_calls() {
  if [ -f "${STUB_LOG_DIR:?}/$1.log" ]; then grep -c '' "$STUB_LOG_DIR/$1.log"; else echo 0; fi
}

# stub_call NAME N: the %q-quoted argv of invocation N.
stub_call() { sed -n "${2}p" "${STUB_LOG_DIR:?}/$1.log"; }

# stub_argv NAME N: the raw argv of invocation N, space-joined (decodes the %q quoting).
stub_argv() {
  local line
  line=$(stub_call "$1" "$2")
  eval "set -- $line"
  printf '%s\n' "$*"
}

# stub_env NAME N: the DISPLAY/XAUTHORITY line recorded by invocation N of an X client stub.
stub_env() { sed -n "${2}p" "${STUB_LOG_DIR:?}/$1.env"; }

# refute_secrets: after `run`, neither fixture secret may appear in the output.
refute_secrets() {
  refute_output --partial TESTtoken
  refute_output --partial RCLONETOKEN
  refute_output --partial RCLONESECRET
}
