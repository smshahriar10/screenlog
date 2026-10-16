#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  use_stubs hostname
}

stats_of() {   # stats_of FIXTURE -> report_stats output
  make_day 2026-10-15 "$1"
  report_stats "$(csv_path 2026-10-15)"
}

@test "stats: the spec example day (58 shots, 49 active, 84%, locked 6x, gap 13:05-14:02)" {
  run stats_of day-normal.csv
  assert_success
  assert_line "samples=64"
  assert_line "shots=58"
  assert_line "active=49"
  assert_line "active_pct=84"
  assert_line "locked=6"
  assert_line "no_session=0"
  assert_line "unsupported_session=0"
  assert_line "error=0"
  assert_line "first=09:12"
  assert_line "last=17:24"
  assert_line "gaps=13:05–14:02"
}

@test "stats: a single shot" {
  run stats_of day-single.csv
  assert_line "shots=1"
  assert_line "active=1"
  assert_line "active_pct=100"
  assert_line "first=09:12"
  assert_line "last=09:12"
  assert_line "gaps="
}

@test "stats: the active percentage rounds half up" {
  run stats_of day-rounding.csv
  assert_line "shots=3"
  assert_line "active=2"
  assert_line "active_pct=67"
  run stats_of day-half.csv      # 1 of 8 = 12.5 -> 13, not banker's 12
  assert_line "shots=8"
  assert_line "active=1"
  assert_line "active_pct=13"
}

@test "stats: gaps count every pause strictly longer than GAP_ALERT_MINUTES between any samples" {
  run stats_of day-gap-edges.csv
  assert_line "samples=6"
  assert_line "shots=4"
  assert_line "error=1"
  assert_line "locked=1"
  assert_line "gaps=09:45–10:31 11:00–12:00"
}

@test "stats: a day of locked samples has zero shots and no division by zero" {
  run stats_of day-all-locked.csv
  assert_line "shots=0"
  assert_line "active=0"
  assert_line "active_pct=0"
  assert_line "locked=5"
  assert_line "first="
  assert_line "last="
}

@test "stats: every status is counted" {
  run stats_of day-mixed-status.csv
  assert_line "samples=5"
  assert_line "shots=1"
  assert_line "no_session=1"
  assert_line "unsupported_session=1"
  assert_line "error=2"
}

@test "stats: malformed rows are skipped" {
  run stats_of day-malformed.csv
  assert_success
  assert_line "samples=1"
  assert_line "shots=1"
  assert_line "first=09:15"
}

@test "stats: a header-only file gives zeros" {
  run stats_of day-header-only.csv
  assert_line "samples=0"
  assert_line "shots=0"
  assert_line "active_pct=0"
}

@test "message: the spec example, byte for byte" {
  make_day 2026-10-15 day-normal.csv
  report_load_stats "$(csv_path 2026-10-15)"
  run report_message 2026-10-15 "Full size: https://drive.google.com/drive/folders/id-2026-10-15"
  assert_success
  assert_output "📸 Rahim Uddin — Thu 15 Oct 2026
58 shots · 49 active (84%) · locked 6× · first 09:12 · last 17:24
⚠️ No samples 13:05–14:02
Full size: https://drive.google.com/drive/folders/id-2026-10-15
dev-pc-03 · v1.0.0"
}

@test "message: no gap line without gaps, zero counts omitted, several gaps joined, no first/last without shots" {
  make_day 2026-10-15 day-single.csv
  report_load_stats "$(csv_path 2026-10-15)"
  run report_message 2026-10-15 "Full size: x"
  assert_equal "${#lines[@]}" 4
  assert_line --index 1 "1 shots · 1 active (100%) · first 09:12 · last 09:12"
  make_day 2026-10-15 day-gap-edges.csv
  report_load_stats "$(csv_path 2026-10-15)"
  run report_message 2026-10-15 "Full size: x"
  assert_line --index 1 "4 shots · 4 active (100%) · locked 1× · error 1× · first 09:00 · last 12:00"
  assert_line --index 2 "⚠️ No samples 09:45–10:31, 11:00–12:00"
  make_day 2026-10-15 day-all-locked.csv
  report_load_stats "$(csv_path 2026-10-15)"
  run report_message 2026-10-15 "⚠️ Drive upload failed: boom — will retry"
  assert_line --index 1 "0 shots · 0 active (0%) · locked 5×"
  assert_line --index 2 "⚠️ Drive upload failed: boom — will retry"
}
