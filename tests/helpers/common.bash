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
# shellcheck source=lib/drive.sh
source "$REPO_ROOT/lib/drive.sh"
# shellcheck source=lib/upload.sh
source "$REPO_ROOT/lib/upload.sh"
# shellcheck source=lib/retention.sh
source "$REPO_ROOT/lib/retention.sh"
# shellcheck source=lib/discord.sh
source "$REPO_ROOT/lib/discord.sh"
# shellcheck source=lib/sheet.sh
source "$REPO_ROOT/lib/sheet.sh"
# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/units.sh
source "$REPO_ROOT/lib/units.sh"
# shellcheck source=lib/system.sh
source "$REPO_ROOT/lib/system.sh"
SCREENLOG_VERSION=$(<"$REPO_ROOT/VERSION")

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
    "$SCREENLOG_SYSROOT/etc/systemd/system" "$SCREENLOG_SYSROOT/run/user/1000" "$SCREENLOG_SYSROOT/tmp/.X11-unix" \
    "$SCREENLOG_SYSROOT/run/systemd/system"
  mkdir -p "$STUB_REMOTE_DIR/Screenlog/rahim-uddin"   # what install.sh's rclone mkdir leaves behind
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
      && chmod 600 "$SCREENLOG_CONFIG.new" && mv "$SCREENLOG_CONFIG.new" "$SCREENLOG_CONFIG"
    shift 2
  done
}

# unset_config KEY...: remove the key's line from the test config.
unset_config() {
  local key
  for key in "$@"; do
    k="$key" awk 'index($0, ENVIRON["k"] "=") != 1' "${SCREENLOG_CONFIG:?}" > "$SCREENLOG_CONFIG.new" \
      && chmod 600 "$SCREENLOG_CONFIG.new" && mv "$SCREENLOG_CONFIG.new" "$SCREENLOG_CONFIG"
  done
}

# append_config_line RAW: append a raw line (for syntax and injection tests).
append_config_line() { printf '%s\n' "$1" >> "${SCREENLOG_CONFIG:?}"; }

# make_day DAY [FIXTURE.csv]: shots/DAY/samples.csv from the fixture (its 2026-10-15 rewritten to
# DAY) plus one tiny JPEG per shot row. Without a fixture: an empty day folder.
make_day() {
  local day=$1 csv=${2:-} dir="${SCREENLOG_DATA_DIR:?}/shots/$1" tpl="${SCREENLOG_TEST_BASE:?}/tiny.jpg" f
  mkdir -p "$dir"
  [ -z "$csv" ] && return 0
  sed "s/^2026-10-15T/${day}T/" "$REPO_ROOT/tests/fixtures/csv/$csv" > "$dir/samples.csv"
  [ -f "$tpl" ] || convert -size 64x48 xc:'#336699' -quality 50 "jpeg:$tpl"
  while IFS= read -r f; do cp "$tpl" "$dir/$f"; done < <(awk -F, 'NR > 1 && $2 == "shot" && $4 != "" { print $4 }' "$dir/samples.csv")
  return 0
}

mark_reported() {
  mkdir -p "${SCREENLOG_DATA_DIR:?}/state"
  printf '%s\n' "$1" >> "$SCREENLOG_DATA_DIR/state/reported-days"
}

# stub_calls NAME: number of recorded invocations of a stub.
stub_calls() {
  if [ -f "${STUB_LOG_DIR:?}/$1.log" ]; then grep -c '' "$STUB_LOG_DIR/$1.log"; else echo 0; fi
}

# stub_reset NAME: forget a stub's recorded calls.
stub_reset() { rm -f "${STUB_LOG_DIR:?}/$1".*; }

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

# curl_posts: number of POSTs the curl stub received; curl_payload N: its payload_json.
curl_posts() { if [ -f "${STUB_LOG_DIR:?}/curl.posts" ]; then grep -c '' "$STUB_LOG_DIR/curl.posts"; else echo 0; fi; }
curl_payload() { cat "${STUB_LOG_DIR:?}/curl.payload.$1.json"; }
curl_content() { jq -r '.content' "${STUB_LOG_DIR:?}/curl.payload.$1.json"; }
curl_attach() { cat "${STUB_LOG_DIR:?}/curl.attach" 2>/dev/null || true; }

# refute_secrets: after `run`, neither fixture secret may appear in the output.
refute_secrets() {
  refute_output --partial TESTtoken
  refute_output --partial RCLONETOKEN
  refute_output --partial RCLONESECRET
}
