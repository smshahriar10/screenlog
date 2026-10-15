#!/usr/bin/env bats
# Real ffmpeg x11grab against Xvfb (spec section 11, test-integration).
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"
# shellcheck source=tests/helpers/xvfb.bash
source "$BATS_TEST_DIRNAME/../helpers/xvfb.bash"

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  start_xvfb 1920x1200x24
}

teardown_file() { stop_xvfb; }

setup() {
  screenlog_test_setup
  load_xvfb_env
  use_stubs hostname rclone
  xprintidle_or_stub
}

shot_path() { printf '%s/shots/2026-10-15/10-00-00.jpg\n' "$SCREENLOG_DATA_DIR"; }

@test "capture: a valid JPEG no taller than MAX_HEIGHT, with cursor-capable x11grab, plus a CSV row" {
  run screenlogd --once
  assert_success
  assert_file_exists "$(shot_path)"
  run file -b --mime-type "$(shot_path)"
  assert_output "image/jpeg"
  run identify -format '%m %w %h' "$(shot_path)"
  assert_output "JPEG 1728 1080"
  run identify -format '%[jpeg:sampling-factor]' "$(shot_path)"
  # yuvj444p: all three components share one sampling factor (no chroma subsampling)
  assert_output --regexp '^([0-9]x[0-9]),\1,\1$'
  run identify -format '%[fx:standard_deviation]' "$(shot_path)"
  awk -v sd="$output" 'BEGIN { exit !(sd > 0.05) }'
  run head -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output "timestamp,status,idle_seconds,file,detail"
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output --regexp '^2026-10-15T10:00:00\+06:00,shot,[0-9]+,10-00-00\.jpg,$'
  run find "$SCREENLOG_DATA_DIR/shots" -name '.capture*'
  assert_output ""
}

@test "capture: no upscale when the screen is smaller than MAX_HEIGHT" {
  set_config MAX_HEIGHT 2000
  run screenlogd --once
  assert_success
  run identify -format '%w %h' "$(shot_path)"
  assert_output "1920 1200"
}

@test "capture: JPEG_QUALITY changes the file size" {
  local s30 s95
  set_config JPEG_QUALITY 30
  run screenlogd --once
  assert_success
  s30=$(stat -c %s "$(shot_path)")
  set_config JPEG_QUALITY 95
  set_now "2026-10-15T10:01:00+06:00"
  run screenlogd --once
  assert_success
  s95=$(stat -c %s "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-01-00.jpg")
  (( s30 * 10 < s95 * 8 ))
}

@test "capture: idle time is recorded in seconds" {
  use_stubs xprintidle
  export STUB_IDLE_MS=4321
  run screenlogd --once
  assert_success
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output "2026-10-15T10:00:00+06:00,shot,4,10-00-00.jpg,"
}

@test "capture: a wrong XAUTHORITY gives an error row with a comma-free detail and no JPEG" {
  : > "$BATS_TEST_TMPDIR/empty-xauth"
  export SCREENLOG_XAUTHORITY="$BATS_TEST_TMPDIR/empty-xauth"
  use_stubs xprintidle
  run screenlogd --once
  assert_success
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output --regexp '^2026-10-15T10:00:00\+06:00,error,[0-9]*,,[^,]+$'
  assert_file_not_exists "$(shot_path)"
}

@test "capture: outside capture hours nothing happens" {
  set_now "2026-10-15T18:00:00+06:00"
  run screenlogd --once
  assert_success
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots"
}

@test "capture: loose budget inside the VM (the real numbers are measured on hardware)" {
  run /usr/bin/time -f '%e %U %S %M' -o "$BATS_TEST_TMPDIR/t" screenlogd --once
  assert_success
  read -r wall user sys rss < "$BATS_TEST_TMPDIR/t"
  echo "# screenlogd --once: wall=${wall}s cpu=$(awk -v u="$user" -v s="$sys" 'BEGIN { print u + s }')s rss=${rss}kB" >&3
  awk -v w="$wall" -v u="$user" -v s="$sys" -v m="$rss" 'BEGIN { exit !(w < 3 && u + s < 1.5 && m < 300000) }'
}
