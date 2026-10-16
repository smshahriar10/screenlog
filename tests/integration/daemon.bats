#!/usr/bin/env bats
# The real daemon loop: idle footprint, SIGTERM, resilience, first-run announcement.
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  use_stubs curl rclone hostname xprintidle ffmpeg loginctl runuser gdbus
  export SCREENLOG_DISPLAY=:1
  mkdir -p "$SCREENLOG_DATA_DIR/state"
  : > "$SCREENLOG_DATA_DIR/state/setup-announced"
  DPID=""
}

start_daemon() {
  screenlogd </dev/null > "$BATS_TEST_TMPDIR/daemon.log" 2>&1 3>&- &
  DPID=$!
}

teardown() {
  if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; fi
  return 0
}

cpu_ticks() { cut -d')' -f2 "/proc/$1/stat" | awk '{ print $12 + $13 }'; }

@test "daemon: between samples only bash and a sleep exist, under 10 MB, and SIGTERM stops it at once" {
  set_now "2026-10-15T20:00:00+06:00"   # outside hours: the loop only sleeps
  start_daemon
  sleep 1.5
  kill -0 "$DPID"
  local spid rss t0 t1
  spid=$(pgrep -P "$DPID" -x sleep)
  [ -n "$spid" ]
  rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$DPID/status")
  echo "# daemon RSS ${rss} kB" >&3
  (( rss < 10240 ))
  (( $(cpu_ticks "$DPID") < 10 ))
  t0=$EPOCHREALTIME
  kill -TERM "$DPID"
  wait "$DPID" || true
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) < 2) }'
  run kill -0 "$spid"
  assert_failure
  run cat "$BATS_TEST_TMPDIR/daemon.log"
  assert_line --index 0 --partial "screenlogd v1.0.0 starting (window 09:00-17:50, ~7 shots/h)"
  assert_line --partial "screenlogd stopping"
  DPID=""
}

@test "daemon: a failing capture never ends the loop" {
  set_config MIN_GAP_SECONDS 1 MAX_GAP_SECONDS 1 GAP_ALERT_MINUTES 1
  export STUB_FFMPEG_EXIT=1
  start_daemon
  sleep 3.5
  kill -0 "$DPID"
  run grep -c ',error,' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  (( output >= 2 ))
  assert_equal "$(stub_calls rclone)" 0
}

@test "daemon: a failing upload never ends the loop and leaks no secret" {
  set_config MIN_GAP_SECONDS 1 MAX_GAP_SECONDS 1 GAP_ALERT_MINUTES 1
  export STUB_RCLONE_FAIL=copy STUB_RCLONE_STDERR="https://discord.com/api/webhooks/1/$DISCORD_WEBHOOK_TOKEN"
  start_daemon
  sleep 3.5
  kill -0 "$DPID"
  run grep -c ',shot,' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  (( output >= 2 ))
  run cat "$BATS_TEST_TMPDIR/daemon.log"
  assert_output --partial "upload=failed(1)"
  refute_secrets
}

@test "daemon: the first-run announcement waits for a session without spinning, then posts once" {
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  unset SCREENLOG_DISPLAY
  export STUB_LOGINCTL_SCENARIO_FILE="$BATS_TEST_TMPDIR/scenario"
  printf 'none' > "$STUB_LOGINCTL_SCENARIO_FILE"
  env -i DISPLAY=:9 sleep 60 </dev/null >/dev/null 2>&1 3>&- &
  local p=$!
  export SCREENLOG_SESSION_PIDS=$p
  set_config MIN_GAP_SECONDS 1 MAX_GAP_SECONDS 1 GAP_ALERT_MINUTES 1
  start_daemon
  sleep 1.5
  (( $(cpu_ticks "$DPID") < 20 ))
  assert_equal "$(curl_posts)" 0
  printf 'x11' > "$STUB_LOGINCTL_SCENARIO_FILE"
  local i
  for i in $(seq 1 40); do [ -f "$SCREENLOG_DATA_DIR/state/setup-announced" ] && break; sleep 0.25; done
  assert_file_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output "✅ Screenlog is running on Rahim Uddin's PC (dev-pc-03, v1.0.0)"
  run identify -format '%w' "$STUB_LOG_DIR/curl.attach.1"
  (( output <= 960 ))
  sleep 2.5
  assert_equal "$(curl_posts)" 1
  run grep -c ',shot,' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  (( output >= 2 ))
  kill "$p" 2>/dev/null || true
}

@test "daemon: a rejected webhook stops the announcement but not the sampling" {
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  export STUB_CURL_PLAN="404 404 404 404 404 404"
  set_config MIN_GAP_SECONDS 1 MAX_GAP_SECONDS 1 GAP_ALERT_MINUTES 1
  start_daemon
  sleep 4
  kill -0 "$DPID"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  run cat "$BATS_TEST_TMPDIR/daemon.log"
  assert_output --partial "announce: webhook rejected (HTTP 404"
  run grep -c ',shot,' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  (( output >= 2 ))
  assert_equal "$(curl_posts)" 1
}

@test "daemon: a login after the start-up bound is still announced within seconds" {
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  unset SCREENLOG_DISPLAY SCREENLOG_NOW                     # real clock: timestamps must differ
  export STUB_LOGINCTL_SCENARIO_FILE="$BATS_TEST_TMPDIR/scenario" SCREENLOG_ANNOUNCE_BOUND=1
  printf 'none' > "$STUB_LOGINCTL_SCENARIO_FILE"
  env -i DISPLAY=:9 sleep 60 </dev/null >/dev/null 2>&1 3>&- &
  local p=$!
  export SCREENLOG_SESSION_PIDS=$p
  set_config MIN_GAP_SECONDS 2 MAX_GAP_SECONDS 2 GAP_ALERT_MINUTES 1 CAPTURE_START 00:00 CAPTURE_END 23:59
  local csv
  csv="$SCREENLOG_DATA_DIR/shots/$(date +%F)/samples.csv"
  start_daemon
  sleep 2.5                                 # the bound (1 s) is over; the loop is sleeping its gap
  run cat "$BATS_TEST_TMPDIR/daemon.log"
  assert_output --partial "announce: not posted yet; sampling starts"
  assert_equal "$(curl_posts)" 0
  printf 'x11' > "$STUB_LOGINCTL_SCENARIO_FILE"
  local i
  for i in $(seq 1 40); do [ -f "$SCREENLOG_DATA_DIR/state/setup-announced" ] && break; sleep 0.25; done
  assert_file_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  assert_equal "$(curl_posts)" 1
  sleep 2.5
  assert_equal "$(curl_posts)" 1
  run grep -c ',shot,' "$csv"
  (( output >= 1 ))
  # the announcement shot was that gap's sample: no two shots within the same second
  run awk -F, 'NR > 1 { if ($1 == prev) dup = 1; prev = $1 } END { exit dup }' "$csv"
  assert_success
  kill "$p" 2>/dev/null || true
}

@test "daemon: the announcement shot outside capture hours is uploaded but not recorded" {
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  set_now "2026-10-15T20:00:00+06:00"
  run screenlogd --announce
  assert_success
  assert_equal "$(curl_posts)" 1
  assert_file_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/20-00-00.jpg"
  assert_file_exists "$STUB_REMOTE_DIR/Screenlog/rahim-uddin/2026-10-15/20-00-00.jpg"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
}

@test "daemon: --announce alone posts and creates the flag; a network failure leaves no flag" {
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  run screenlogd --announce
  assert_success
  assert_file_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  assert_equal "$(curl_posts)" 1
  rm -f "$SCREENLOG_DATA_DIR/state/setup-announced"
  STUB_CURL_PLAN="7 7 7 7 7 7 7 7 7 7" SCREENLOG_ANNOUNCE_BOUND=1 run screenlogd --announce
  assert_failure 1
  assert_output --partial "announce: post failed (curl exit 7"
  assert_output --partial "retried as soon as a session is seen"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
}
