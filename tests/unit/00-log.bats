#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash -c scripts expand $1 themselves
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() { screenlog_test_setup; }

@test "log: die exits with the given code and an ERROR line on stderr" {
  run --separate-stderr bash -c 'source "$1/lib/log.sh"; die 7 "boom"' _ "$REPO_ROOT"
  assert_failure 7
  assert_equal "$output" ""
  assert_equal "$stderr" "ERROR: boom"
}

@test "log: die without a code exits 1" {
  run bash -c 'source "$1/lib/log.sh"; die "plain"' _ "$REPO_ROOT"
  assert_failure 1
  assert_output "ERROR: plain"
}

@test "log: info goes to stdout, warn and error to stderr" {
  run --separate-stderr bash -c 'source "$1/lib/log.sh"; log_info one; log_warn two; log_error three' _ "$REPO_ROOT"
  assert_success
  assert_equal "$output" "INFO: one"
  assert_equal "$stderr" $'WARN: two\nERROR: three'
}

@test "log: a timestamp prefix appears only outside journald" {
  run env -u JOURNAL_STREAM bash -c 'source "$1/lib/log.sh"; log_info hi' _ "$REPO_ROOT"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} INFO: hi$'
  run env JOURNAL_STREAM=9:1234 bash -c 'source "$1/lib/log.sh"; log_info hi' _ "$REPO_ROOT"
  assert_output "INFO: hi"
}

@test "log: redaction hides webhook URLs, the token and control bytes" {
  config_load
  run log_redact_str "failed: https://discord.com/api/webhooks/123456789012345678/$DISCORD_WEBHOOK_TOKEN end"
  assert_output "failed: <webhook> end"
  run log_redact_str "partial webhooks/123/$DISCORD_WEBHOOK_TOKEN tail"
  assert_output "partial webhooks/123/<token> tail"
  run log_redact_str "versioned https://ptb.discordapp.com/api/v9/webhooks/1/abc_DEF-9 x"
  assert_output "versioned <webhook> x"
  run log_redact_str $'ctrl\x01\x1b[0m bytes'
  assert_output "ctrl[0m bytes"
  refute_secrets
}

@test "log: redact filters a stream line by line" {
  config_load
  run log_redact <<< $'a https://discord.com/api/webhooks/1/x\nb'
  assert_line --index 0 "a <webhook>"
  assert_line --index 1 "b"
}

@test "log: sleep_interruptible returns 1 at once when a stop was requested" {
  local t0 t1
  t0=$EPOCHREALTIME
  RUN_STOP=1
  run sleep_interruptible 5
  t1=$EPOCHREALTIME
  assert_failure
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) < 2) }'
}

@test "log: a TERM trap stops a running interruptible sleep within a second" {
  local pid t0 t1
  t0=$EPOCHREALTIME
  bash -c 'source "$1/lib/log.sh"; trap "stop_children; echo child=\$CHILD_PID" TERM; echo ready; sleep_interruptible 30; echo "rc=$?"' _ "$REPO_ROOT" \
    </dev/null >"$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  local i
  for i in $(seq 1 50); do grep -q ready "$BATS_TEST_TMPDIR/out" 2>/dev/null && break; sleep 0.1; done
  sleep 0.2
  kill -TERM "$pid"
  wait "$pid" || true
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) < 8) }'
  run cat "$BATS_TEST_TMPDIR/out"
  assert_line "ready"
  assert_line "rc=1"
  local child
  child=$(sed -n 's/^child=//p' "$BATS_TEST_TMPDIR/out")
  [ -n "$child" ]
  run kill -0 "$child"
  assert_failure
}

@test "log: tmp_init makes a private dir and tmp_cleanup removes it on exit" {
  run bash -c 'source "$1/lib/log.sh"; tmp_init; stat -c %a "$SCREENLOG_TMP"; printf "%s\n" "$SCREENLOG_TMP"' _ "$REPO_ROOT"
  assert_success
  assert_line --index 0 "700"
  assert_dir_not_exists "${lines[1]}"
}

@test "log: require_root refuses a non-root caller with exit 4" {
  need_root
  run setpriv --reuid=65534 --regid=65534 --clear-groups bash -c 'source "$1/lib/log.sh"; require_root status' _ "$REPO_ROOT"
  assert_failure 4
  assert_output --partial "must run as root"
}
