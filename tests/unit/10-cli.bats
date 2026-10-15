#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  use_stubs hostname curl rclone systemctl journalctl timedatectl loginctl runuser gdbus xprintidle ffmpeg
}

@test "cli: version, help, unknown command" {
  run screenlog version
  assert_success
  assert_output "1.0.0"
  run screenlog help
  assert_success
  local c
  for c in status test report upload doctor apply-config logs version help; do
    assert_output --partial "  $c"
  done
  assert_output --partial "sudo screenlog apply-config"
  run screenlog
  assert_success
  assert_output --partial "Usage: screenlog"
  run screenlog bogus
  assert_failure 2
  assert_output --partial "unknown command: bogus"
}

@test "cli: every command but version and help refuses a non-root caller before reading anything" {
  need_root
  local c
  for c in status test report upload doctor apply-config logs; do
    run setpriv --reuid=65534 --regid=65534 --clear-groups "$REPO_ROOT/bin/screenlog" "$c"
    assert_failure 4
    assert_output --partial "screenlog $c must run as root (sudo screenlog $c)"
  done
  assert_equal "$(stub_calls systemctl)" 0
}

@test "cli: logs runs journalctl for both units and passes extra arguments through" {
  run screenlog logs
  assert_success
  assert_output --partial "screenlogd v1.0.0 starting"
  run stub_argv journalctl 1
  assert_output --partial "-u screenlog -u screenlog-report -n 200 --no-pager"
  run screenlog logs --since today
  run stub_argv journalctl 2
  assert_output --partial "--no-pager --since today"
  refute_secrets
}

@test "cli: upload pushes every pending day with full retries" {
  make_day 2026-10-13 day-single.csv
  make_day 2026-10-14 day-single.csv
  run screenlog upload
  assert_success
  assert_line "2026-10-13 ok"
  assert_line "2026-10-14 ok"
  assert_line "all local days are uploaded"
  run stub_argv rclone 1
  assert_output --partial "--retries 2"
  refute_output --partial "--retries 1"
  STUB_RCLONE_FAIL=copy run screenlog upload
  assert_success   # nothing pending any more
  make_day 2026-10-15 day-single.csv
  STUB_RCLONE_FAIL=copy run screenlog upload
  assert_failure 1
  assert_output --partial "2026-10-15 failed: rclone exit 1"
}

@test "cli: apply-config renders the timer from REPORT_TIME, reloads and restarts" {
  set_config REPORT_TIME "18:05"
  run screenlog apply-config
  assert_success
  assert_output --partial "config applied: capture 09:00-17:50, ~7 shots/h, report 18:05"
  assert_output --partial "next report: Thu 2026-10-15 17:30:00 +06"
  assert_file_exists "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
  run grep -c 'OnCalendar=\*-\*-\* 18:05:00' "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
  assert_output 1
  run grep -c '@REPORT_TIME@' "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
  assert_output 0
  assert_file_permission 644 "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
  run diff "$REPO_ROOT/systemd/screenlog.service" "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog.service"
  assert_success
  run cat "$STUB_LOG_DIR/systemctl.log"
  assert_line --index 0 --regexp 'systemctl daemon-reload $'
  assert_line --index 1 --regexp 'systemctl restart screenlog-report.timer screenlog.service $'
  run screenlog apply-config
  assert_output --partial "unit screenlog-report.timer: unchanged"
}

@test "cli: apply-config refuses an invalid config without touching systemd" {
  set_config SHOTS_PER_HOUR abc
  run screenlog apply-config
  assert_failure 3
  assert_output --partial "SHOTS_PER_HOUR"
  assert_equal "$(stub_calls systemctl)" 0
  assert_file_not_exists "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
}

@test "cli: test takes a shot, uploads it and posts the test message with a small image" {
  export SCREENLOG_DISPLAY=:1 STUB_FFMPEG_SIZE=1920x1080
  run screenlog test
  assert_success
  assert_output --regexp 'capture: [0-9]+ ms, 10-00-00\.jpg \([0-9]+ bytes\), idle 1s'
  assert_output --regexp 'upload: ok \([0-9.]+ s\)'
  assert_output --partial "discord: HTTP 200"
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output "🧪 Test from Rahim Uddin"
  run identify -format '%w' "$STUB_LOG_DIR/curl.attach.1"
  assert_output 960
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output "2026-10-15T10:00:00+06:00,shot,1,10-00-00.jpg,manual test"
  assert_file_exists "$STUB_REMOTE_DIR/Screenlog/rahim-uddin/2026-10-15/10-00-00.jpg"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
  refute_secrets
}

@test "cli: test without a capturable session or with a dead webhook exits 1" {
  export STUB_LOGINCTL_SCENARIO=locked
  run screenlog test
  assert_failure 1
  assert_output --partial "status: locked"
  assert_equal "$(stub_calls curl)" 0
  export SCREENLOG_DISPLAY=:1
  STUB_CURL_PLAN=404 run screenlog test
  assert_failure 1
  assert_output --partial "discord: failed (HTTP 404"
}
