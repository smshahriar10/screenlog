#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  # not tmp_init: its EXIT trap would replace bats' own reporting trap in the test process
  SCREENLOG_TMP="$BATS_TEST_TMPDIR/screenlog-tmp"
  mkdir -p "$SCREENLOG_TMP"
  use_stubs loginctl runuser gdbus xprintidle ffmpeg hostname
  export SCREENLOG_DISPLAY=:1
  SESSION_DISPLAY=:1
  SESSION_XAUTHORITY=""
  mkdir -p "$SCREENLOG_DATA_DIR/shots/2026-10-15"
}

@test "capture: JPEG_QUALITY maps to ffmpeg's quality scale monotonically" {
  local q
  run capture_qscale 95; assert_output 1
  run capture_qscale 90; assert_output 2
  run capture_qscale 85; assert_output 3
  run capture_qscale 80; assert_output 4
  run capture_qscale 70; assert_output 6
  run capture_qscale 60; assert_output 8
  run capture_qscale 30; assert_output 16
  run capture_qscale 1;  assert_output 25
  local prev=0 cur
  for q in 1 10 20 30 40 50 60 70 80 90 100; do
    cur=$(capture_qscale "$q")
    (( prev == 0 || cur <= prev ))
    prev=$cur
  done
}

@test "capture: ffmpeg is called with the designed arguments and environment" {
  SESSION_XAUTHORITY="$BATS_TEST_TMPDIR/xa"
  capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  run stub_argv ffmpeg 1
  assert_output --partial "-f x11grab -draw_mouse 1 -i :1 -frames:v 1"
  assert_output --partial "scale=w='trunc(iw*min(1,1080/ih)/2)*2':h='trunc(min(ih,1080)/2)*2':flags=area"
  assert_output --partial "-c:v mjpeg -pix_fmt yuvj444p -q:v 3 -f image2 -update 1 -y"
  refute_output --partial "-video_size"
  refute_output --partial "-framerate"
  run stub_env ffmpeg 1
  assert_output "DISPLAY=:1 XAUTHORITY=$BATS_TEST_TMPDIR/xa"
  run find "$SCREENLOG_DATA_DIR/shots/2026-10-15" -name '.capture*'
  assert_output ""
}

@test "capture: an empty XAUTHORITY is not exported" {
  capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  run stub_env ffmpeg 1
  assert_output "DISPLAY=:1 XAUTHORITY=<unset>"
}

@test "capture: the first shot of a day creates the folder" {
  rm -rf "$SCREENLOG_DATA_DIR/shots"
  sample_take
  assert_equal "$SAMPLE_STATUS" shot
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
}

@test "capture: ffmpeg failure, empty output and timeout become error statuses with a short detail" {
  STUB_FFMPEG_EXIT=1 run capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/a.jpg"
  assert_failure
  STUB_FFMPEG_EXIT=1 capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/a.jpg" || true
  assert_equal "$CAPTURE_ERROR" "ffmpeg exit 1: [x11grab @ 0x5555] Cannot open display :1, error 1."
  assert_file_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/a.jpg"
  STUB_FFMPEG_EMPTY=1 capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/b.jpg" || true
  assert_equal "$CAPTURE_ERROR" "ffmpeg wrote no JPEG"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/b.jpg"
  local t0 t1
  t0=$EPOCHREALTIME
  STUB_FFMPEG_SLEEP=10 SCREENLOG_CAPTURE_TIMEOUT=1 capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/c.jpg" || true
  t1=$EPOCHREALTIME
  assert_equal "$CAPTURE_ERROR" "ffmpeg timeout"
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) < 6) }'
  run find "$SCREENLOG_DATA_DIR/shots/2026-10-15" -name '.capture*'
  assert_output ""
}

@test "capture: the error detail never leaks the webhook token" {
  local tok
  tok=$DISCORD_WEBHOOK_TOKEN
  rm -f "$SCREENLOG_TEST_BASE/bin/ffmpeg"   # the symlink points into the read-only repo
  printf '#!/usr/bin/env bash\necho "fatal: https://discord.com/api/webhooks/1/%s leaked" >&2; exit 1\n' "$tok" > "$SCREENLOG_TEST_BASE/bin/ffmpeg"
  chmod 755 "$SCREENLOG_TEST_BASE/bin/ffmpeg"
  capture_take "$SCREENLOG_DATA_DIR/shots/2026-10-15/a.jpg" || true
  assert_equal "$CAPTURE_ERROR" "ffmpeg exit 1: fatal: <webhook> leaked"
}

@test "csv: header once, columns in order, detail sanitised" {
  local f
  f=$(csv_path 2026-10-15)
  assert_equal "$f" "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  csv_append "$f" "2026-10-15T10:00:00+06:00" shot 12 10-00-00.jpg ""
  csv_append "$f" "2026-10-15T10:05:00+06:00" error "" "" $'ffmpeg exit 1, bad\r\nthing'
  run cat "$f"
  assert_line --index 0 "timestamp,status,idle_seconds,file,detail"
  assert_line --index 1 "2026-10-15T10:00:00+06:00,shot,12,10-00-00.jpg,"
  assert_line --index 2 "2026-10-15T10:05:00+06:00,error,,,ffmpeg exit 1; bad  thing"
  assert_equal "$(grep -c '' "$f")" 3
}

@test "sample: statuses from the session scenarios" {
  unset SCREENLOG_DISPLAY
  export SCREENLOG_SESSION_PIDS=$$
  local sc
  for sc in none greeter remote; do
    STUB_LOGINCTL_SCENARIO=$sc sample_take
    assert_equal "$SAMPLE_STATUS" no_session
    assert_equal "$SAMPLE_FILE" ""
  done
  STUB_LOGINCTL_SCENARIO=wayland sample_take
  assert_equal "$SAMPLE_STATUS" unsupported_session
  STUB_LOGINCTL_SCENARIO=locked sample_take
  assert_equal "$SAMPLE_STATUS" locked
  assert_equal "$(stub_calls ffmpeg)" 0
  assert_equal "$SAMPLE_TS" "2026-10-15T10:00:00+06:00"
  assert_equal "$SAMPLE_DAY" "2026-10-15"
}

@test "sample: no working display is an error row, not a crash" {
  unset SCREENLOG_DISPLAY
  export SCREENLOG_SESSION_PIDS=$$ STUB_XPRINTIDLE_EXIT=1
  sample_take
  assert_equal "$SAMPLE_STATUS" error
  assert_equal "$SAMPLE_DETAIL" "no working DISPLAY for session 3"
  sample_record
  run tail -n1 "$(csv_path 2026-10-15)"
  assert_output "2026-10-15T10:00:00+06:00,error,,,no working DISPLAY for session 3"
}

@test "sample: an unknown lock state is logged once per session and capture goes ahead" {
  unset SCREENLOG_DISPLAY
  export STUB_LOGINCTL_SCENARIO=nolockedhint STUB_GDBUS_FAIL_DEST="org.gnome.Shell.ScreenShield org.gnome.ScreenSaver"
  env -i DISPLAY=:9 sleep 30 </dev/null >/dev/null 2>&1 3>&- &
  local p=$!
  export SCREENLOG_SESSION_PIDS=$p
  sample_take 2> "$BATS_TEST_TMPDIR/err"
  assert_equal "$SAMPLE_STATUS" shot
  sample_take 2>> "$BATS_TEST_TMPDIR/err"
  kill "$p" 2>/dev/null || true
  assert_equal "$SAMPLE_STATUS" shot
  assert_equal "$(grep -c 'lock state unknown' "$BATS_TEST_TMPDIR/err")" 1
}

@test "sample: a second shot in the same second gets a suffix" {
  sample_take
  sample_take
  assert_equal "$SAMPLE_FILE" "10-00-00-1.jpg"
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00-1.jpg"
}

@test "screenlogd --once: a shot inside the window writes the JPEG, the CSV row and one log line" {
  run screenlogd --once
  assert_success
  assert_line --index 0 "INFO: sample day=2026-10-15 status=shot idle=1 file=10-00-00.jpg"
  assert_file_exists "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output "2026-10-15T10:00:00+06:00,shot,1,10-00-00.jpg,"
  refute_secrets
}

@test "screenlogd --once: outside capture hours nothing is captured or written" {
  rm -rf "$SCREENLOG_DATA_DIR/shots"
  set_now "2026-10-15T18:00:00+06:00"
  run screenlogd --once
  assert_success
  assert_output --partial "outside capture hours"
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots"
  assert_equal "$(stub_calls ffmpeg)" 0
}

@test "screenlogd --once: a failed capture is an error row and exit 0" {
  export STUB_FFMPEG_EXIT=1
  run screenlogd --once
  assert_success
  assert_output --partial 'status=error idle=1 file= detail="ffmpeg exit 1'
  run tail -n1 "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv"
  assert_output --partial ",error,1,,ffmpeg exit 1"
}

@test "screenlogd: an invalid config exits 3 before touching anything" {
  set_config SHOTS_PER_HOUR abc
  run screenlogd --once
  assert_failure 3
  assert_output --partial "SHOTS_PER_HOUR"
  assert_equal "$(stub_calls ffmpeg)" 0
  assert_equal "$(stub_calls loginctl)" 0
  run screenlogd --bogus
  assert_failure 2
}
