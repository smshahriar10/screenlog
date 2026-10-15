#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() { screenlog_test_setup; config_load; }

@test "time: capture window at minute boundaries (inclusive start, exclusive end)" {
  local hhmm
  for hhmm in 09:00 09:01 12:00 17:49; do
    set_now "2026-10-15T$hhmm:00+06:00"
    run time_in_window 09:00 17:50
    assert_success
  done
  for hhmm in 00:00 08:59 17:50 17:51 23:59; do
    set_now "2026-10-15T$hhmm:00+06:00"
    run time_in_window 09:00 17:50
    assert_failure
  done
}

@test "time: capture window ignores seconds within the minute" {
  set_now "2026-10-15T08:59:59+06:00"; run time_in_window 09:00 17:50; assert_failure
  set_now "2026-10-15T09:00:00+06:00"; run time_in_window 09:00 17:50; assert_success
  set_now "2026-10-15T17:49:59+06:00"; run time_in_window 09:00 17:50; assert_success
  set_now "2026-10-15T17:50:00+06:00"; run time_in_window 09:00 17:50; assert_failure
}

@test "time: SCREENLOG_NOW with another offset is converted to local time" {
  set_now "2026-10-15T03:00:00+00:00"   # 09:00 in Dhaka
  run time_in_window 09:00 17:50
  assert_success
  run time_hhmm
  assert_output "09:00"
  set_now "2026-10-15T02:59:00+00:00"
  run time_in_window 09:00 17:50
  assert_failure
}

@test "time: formatting helpers" {
  run time_iso; assert_output "2026-10-15T10:00:00+06:00"
  run time_day; assert_output "2026-10-15"
  run time_hms; assert_output "10-00-00"
  run time_hhmm; assert_output "10:00"
  run time_clock; assert_output "10:00:00"
  run time_dow; assert_output "Thu"
  run time_day_human 2026-10-15; assert_output "Thu 15 Oct 2026"
  run time_day_dow 2026-10-18; assert_output "Sun"
  run time_hhmm_to_min 17:30; assert_output "1050"
  run time_min_of_day; assert_output "600"
  run time_parse "2026-10-15T10:00:00+06:00"; assert_output "$(time_now_epoch)"
}

@test "time: an epoch argument overrides the clock" {
  local e
  e=$(time_parse "2026-10-16T17:24:05+06:00")
  run time_iso "$e"; assert_output "2026-10-16T17:24:05+06:00"
  run time_hms "$e"; assert_output "17-24-05"
  run time_in_window 09:00 17:50 "$e"; assert_success
}

@test "time: day arithmetic" {
  run time_day_offset 2026-10-15 -3; assert_output "2026-10-12"
  run time_day_offset 2026-10-15 2; assert_output "2026-10-17"
  run time_day_offset 2026-11-01 -1; assert_output "2026-10-31"
  run time_day_offset 2026-10-15 -13; assert_output "2026-10-02"
}

@test "time: REPORT_TIME is passed at the exact minute" {
  set_now "2026-10-15T17:29:59+06:00"; run time_is_at_or_after 17:30; assert_failure
  set_now "2026-10-15T17:30:00+06:00"; run time_is_at_or_after 17:30; assert_success
  set_now "2026-10-15T23:59:00+06:00"; run time_is_at_or_after 17:30; assert_success
}

@test "time: work days" {
  run time_is_work_day Thu; assert_success
  run time_is_work_day Fri; assert_failure
  WORK_DAYS=""
  run time_is_work_day Thu; assert_failure
}

@test "time: day names stay English under a real non-English locale" {
  run env LC_ALL=de_DE.UTF-8 date -d 2026-10-15 +%a
  assert_output "Do"   # proves the locale exists; otherwise the rest proves nothing
  LC_ALL=de_DE.UTF-8 run time_day_dow 2026-10-15
  assert_output "Thu"
  LC_ALL=de_DE.UTF-8 run time_day_human 2026-10-15
  assert_output "Thu 15 Oct 2026"
  LC_ALL=de_DE.UTF-8 run time_dow
  assert_output "Thu"
}

@test "time: an invalid SCREENLOG_NOW is a usage error" {
  set_now "garbage"
  run time_now_epoch
  assert_failure 2
  assert_output --partial "SCREENLOG_NOW is not a date"
}

@test "time: without SCREENLOG_NOW the real clock is used" {
  unset SCREENLOG_NOW
  local now
  now=$(time_now_epoch)
  (( now > 1700000000 ))
  (( now - EPOCHSECONDS <= 1 ))
}
