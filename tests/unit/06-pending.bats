#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  use_stubs hostname curl rclone
}

@test "pending: days of the last 14 days that are not reported, ignoring other folders" {
  set_now "2026-10-15T17:29:00+06:00"
  local d
  for d in 2026-10-15 2026-10-14 2026-10-12 2026-10-02 2026-10-01; do make_day "$d" day-single.csv; done
  mkdir -p "$SCREENLOG_DATA_DIR/shots/notes" "$SCREENLOG_DATA_DIR/shots/2026-13-40x"
  mark_reported 2026-10-14
  run report_pending_days
  assert_output $'2026-10-02\n2026-10-12\n2026-10-15'
  run report_due_days
  assert_output $'2026-10-02\n2026-10-12'
}

@test "pending: today becomes due at REPORT_TIME exactly; yesterday is due at once" {
  make_day 2026-10-15 day-single.csv
  set_now "2026-10-15T17:29:59+06:00"
  run report_due_days
  assert_output ""
  set_now "2026-10-15T17:30:00+06:00"
  run report_due_days
  assert_output "2026-10-15"
  set_now "2026-10-16T00:01:00+06:00"
  run report_due_days
  assert_output "2026-10-15"
}

@test "pending: the 14-day window is today-13 .. today" {
  set_now "2026-10-15T18:00:00+06:00"
  make_day 2026-10-02 day-single.csv
  make_day 2026-10-01 day-single.csv
  run report_pending_days
  assert_output "2026-10-02"
}

@test "pending: catch-up after missed days posts each day once, in order, and a rerun does nothing" {
  set_now "2026-10-15T10:00:00+06:00"
  local d
  for d in 2026-10-12 2026-10-13 2026-10-14; do make_day "$d" day-single.csv; done
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 3
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output $'2026-10-12\n2026-10-13\n2026-10-14'
  run curl_content 1
  assert_line --index 0 "📸 Rahim Uddin — Mon 12 Oct 2026"
  run screenlog report --pending
  assert_success
  assert_output --partial "nothing to do"
  assert_equal "$(curl_posts)" 3
}

@test "pending: the missing-day notice on a work day after REPORT_TIME, once" {
  set_now "2026-10-15T17:31:00+06:00"   # Thursday
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output "⚠️ No screenshots from Rahim Uddin today (dev-pc-03)"
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-15"
  run screenlog report --pending
  assert_equal "$(curl_posts)" 1
}

@test "pending: no missing-day notice on a non-work day, before REPORT_TIME, or with WORK_DAYS empty" {
  set_now "2026-10-16T17:31:00+06:00"   # Friday
  run screenlog report --pending
  assert_equal "$(curl_posts)" 0
  set_now "2026-10-15T17:00:00+06:00"
  run screenlog report --pending
  assert_equal "$(curl_posts)" 0
  set_config WORK_DAYS ""
  set_now "2026-10-15T17:31:00+06:00"
  run screenlog report --pending
  assert_equal "$(curl_posts)" 0
}

@test "pending: a header-only CSV today counts as no samples; a reported day gets no notice" {
  set_now "2026-10-15T17:31:00+06:00"
  make_day 2026-10-15 day-header-only.csv
  run screenlog report --pending
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output --partial "No screenshots"
  run screenlog report --pending
  assert_equal "$(curl_posts)" 1
}

@test "pending: an empty folder of a past day is skipped and marked, today's follows the missing-day rule" {
  set_now "2026-10-15T10:00:00+06:00"
  make_day 2026-10-13
  make_day 2026-10-15
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 0
  assert_output --partial "2026-10-13 has no samples, skipping"
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-13"
}

@test "pending: an invalid config stops the report before any network call" {
  set_config SHOTS_PER_HOUR abc
  make_day 2026-10-14 day-single.csv
  run screenlog report --pending
  assert_failure 3
  assert_output --partial "SHOTS_PER_HOUR"
  assert_equal "$(stub_calls curl)" 0
  assert_equal "$(stub_calls rclone)" 0
}

@test "pending: the hourly run with nothing due only retries pending uploads of earlier days" {
  set_now "2026-10-15T11:00:00+06:00"
  make_day 2026-10-14 day-single.csv
  make_day 2026-10-15 day-single.csv
  mark_reported 2026-10-14
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 0
  run grep -c ' copy ' "$STUB_LOG_DIR/rclone.log"
  assert_output 1
  run stub_argv rclone 2
  assert_output --partial "copy $SCREENLOG_DATA_DIR/shots/2026-10-14 "
  assert_output --partial "--retries 1"
}
