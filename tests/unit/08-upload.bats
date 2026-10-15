#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  SCREENLOG_TMP="$BATS_TEST_TMPDIR/screenlog-tmp"
  mkdir -p "$SCREENLOG_TMP"
  use_stubs rclone hostname loginctl runuser gdbus xprintidle ffmpeg
  BG_PIDS=()
}

teardown() {
  local p
  for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  return 0
}

# make_shots DAY N: a day folder with N tiny JPEGs (and a dot-file temp that must never upload)
make_shots() {
  local dir="$SCREENLOG_DATA_DIR/shots/$1" i
  mkdir -p "$dir"
  for i in $(seq 1 "$2"); do printf 'jpeg%s' "$i" > "$dir/10-0$i-00.jpg"; done
  printf 'partial' > "$dir/.capture.abc123"
  printf 'timestamp,status,idle_seconds,file,detail\n' > "$dir/samples.csv"
}

remote_day() { printf '%s/Screenlog/rahim-uddin/%s\n' "$STUB_REMOTE_DIR" "$1"; }

@test "upload: rclone copy of the whole day folder with the designed flags, temp files excluded" {
  make_shots 2026-10-15 2
  upload_day 2026-10-15
  run stub_argv rclone 1
  assert_output --partial "--config $SCREENLOG_RCLONE_CONF --contimeout 30s --timeout 120s --retries 2 --low-level-retries 3 --stats 0 copy $SCREENLOG_DATA_DIR/shots/2026-10-15 screenlog-gdrive:Screenlog/rahim-uddin/2026-10-15 --bwlimit 1M --exclude .* --transfers 2 --checkers 4"
  assert_file_exists "$(remote_day 2026-10-15)/10-01-00.jpg"
  assert_file_exists "$(remote_day 2026-10-15)/10-02-00.jpg"
  assert_file_exists "$(remote_day 2026-10-15)/samples.csv"
  assert_file_not_exists "$(remote_day 2026-10-15)/.capture.abc123"
  assert_file_exists "$SCREENLOG_DATA_DIR/state/uploaded/2026-10-15"
  run upload_is_complete 2026-10-15
  assert_success
  upload_day 2026-10-15 quick
  run stub_argv rclone 2
  assert_output --partial "--checkers 4 --retries 1"
}

@test "upload: a failed copy leaves no marker and sets UPLOAD_ERROR without secrets" {
  make_shots 2026-10-15 1
  export STUB_RCLONE_FAIL=copy STUB_RCLONE_STDERR="auth https://discord.com/api/webhooks/1/$DISCORD_WEBHOOK_TOKEN"
  run upload_day 2026-10-15
  assert_failure 1
  upload_day 2026-10-15 || true
  assert_equal "$UPLOAD_ERROR" "rclone exit 1: Failed to copy: couldn't connect (stub)"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/uploaded/2026-10-15"
  unset STUB_RCLONE_FAIL
  mkdir -p "$STUB_REMOTE_DIR/Screenlog"   # lsd succeeds, so the stub's stderr line is the last one
  drive_rclone lsd screenlog-gdrive:Screenlog
  assert_equal "$DRIVE_LAST_ERR" "auth <webhook>"
  run upload_day 2026-10-14
  assert_failure
  upload_day 2026-10-14 || true
  assert_equal "$UPLOAD_ERROR" "no local folder for 2026-10-14"
}

@test "upload: the marker carries the copy's start time, so a shot added during the copy stays pending" {
  make_shots 2026-10-15 1
  export STUB_RCLONE_SLEEP=2
  ( sleep 1; printf 'late' > "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-09-00.jpg" ) </dev/null >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  upload_day 2026-10-15
  run upload_is_complete 2026-10-15
  assert_failure
  run upload_pending
  assert_output "2026-10-15"
  unset STUB_RCLONE_SLEEP
  upload_day 2026-10-15
  run upload_is_complete 2026-10-15
  assert_success
  run upload_pending
  assert_output ""
}

@test "upload: every rclone call is serialised on state/rclone.lock" {
  local t0 t1
  mkdir -p "$SCREENLOG_DATA_DIR/state"
  flock "$SCREENLOG_DATA_DIR/state/rclone.lock" sleep 2 </dev/null >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  sleep 0.3
  t0=$EPOCHREALTIME
  drive_rclone lsd screenlog-gdrive:
  t1=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) >= 1.5) }'
}

@test "upload: a busy lock gives up after SCREENLOG_LOCK_WAIT with code 75" {
  local t0 t1
  mkdir -p "$SCREENLOG_DATA_DIR/state"
  flock "$SCREENLOG_DATA_DIR/state/rclone.lock" sleep 10 </dev/null >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  sleep 0.3
  t0=$EPOCHREALTIME
  SCREENLOG_LOCK_WAIT=1 run drive_rclone lsd screenlog-gdrive:
  t1=$EPOCHREALTIME
  assert_failure 75
  awk -v a="$t0" -v b="$t1" 'BEGIN { exit !((b - a) < 3) }'
  SCREENLOG_LOCK_WAIT=1 drive_rclone lsd screenlog-gdrive: || true
  assert_equal "$DRIVE_LAST_ERR" "rclone lock busy"
  assert_equal "$(stub_calls rclone)" 0
}

@test "upload: a hung rclone is killed by the outer timeout" {
  export STUB_RCLONE_SLEEP=10 SCREENLOG_RCLONE_TIMEOUT=1
  SCREENLOG_RCLONE_TIMEOUT=1 run drive_rclone lsd screenlog-gdrive:
  assert_failure 124
  drive_rclone lsd screenlog-gdrive: || true
  assert_equal "$DRIVE_LAST_ERR" "rclone timeout"
}

@test "upload: once the probe fails, later calls fail fast without running rclone" {
  export STUB_RCLONE_FAIL=lsd
  run drive_probe
  assert_failure
  drive_probe || true
  assert_equal "$DRIVE_OFFLINE" 1
  make_shots 2026-10-15 1
  run upload_day 2026-10-15
  assert_failure
  assert_equal "$(stub_calls rclone)" 2
  upload_day 2026-10-15 || true
  assert_equal "$UPLOAD_ERROR" "rclone exit 1: Drive unreachable (probe failed this run)"
}

@test "upload: the Drive folder link comes from rclone lsjson, never rclone link" {
  mkdir -p "$(remote_day 2026-10-15)" "$(remote_day 2026-10-14)"
  drive_folder_id 2026-10-15
  assert_equal "$DRIVE_FOLDER_ID" "id-2026-10-15"
  assert_equal "$DRIVE_FOLDER_URL" "https://drive.google.com/drive/folders/id-2026-10-15"
  run stub_argv rclone 1
  assert_output --partial "lsjson --dirs-only --no-mimetype --no-modtime screenlog-gdrive:Screenlog/rahim-uddin"
  run drive_folder_id 2026-10-13
  assert_failure
  drive_folder_id 2026-10-13 || true
  assert_equal "$DRIVE_FOLDER_ID" ""
  assert_equal "$DRIVE_LAST_ERR" "folder 2026-10-13 not found in Drive listing"
  run grep -c ' link ' "$STUB_LOG_DIR/rclone.log"
  assert_output 0
}

@test "upload: pending days, skip_today and upload_all" {
  make_shots 2026-10-13 1
  make_shots 2026-10-14 1
  make_shots 2026-10-15 1
  mkdir -p "$SCREENLOG_DATA_DIR/shots/notes" "$SCREENLOG_DATA_DIR/shots/2026-13-40x"
  upload_day 2026-10-14
  run upload_pending
  assert_output $'2026-10-13\n2026-10-15'
  run upload_pending skip_today
  assert_output "2026-10-13"
  run upload_all quick
  assert_success
  assert_output --partial "upload: 2026-10-13 ok"
  assert_output --partial "upload: 2026-10-15 ok"
  run upload_pending
  assert_output ""
  make_shots 2026-10-12 1
  STUB_RCLONE_FAIL=copy run upload_all
  assert_failure
  assert_output --partial "upload: 2026-10-12 failed (rclone exit 1"
}

@test "retention: local days are removed only when old, uploaded and reported (or out of the window)" {
  local d
  for d in 2026-10-01 2026-10-07 2026-10-08 2026-10-10; do make_shots "$d" 1; done
  upload_all >/dev/null
  mark_reported 2026-10-07
  mark_reported 2026-10-10
  retention_local
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-01"   # outside the 14-day window: no report needed
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-07"   # 8 days old, uploaded, reported
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/uploaded/2026-10-07"
  assert_dir_exists "$SCREENLOG_DATA_DIR/shots/2026-10-08"       # exactly LOCAL_RETENTION_DAYS old: kept
  assert_dir_exists "$SCREENLOG_DATA_DIR/shots/2026-10-10"       # younger than the retention: kept
  make_shots 2026-10-05 1                                        # old, reported, never uploaded
  mark_reported 2026-10-05
  export STUB_RCLONE_FAIL=copy
  retention_local
  assert_dir_exists "$SCREENLOG_DATA_DIR/shots/2026-10-05"       # the quick upload failed: kept
  unset STUB_RCLONE_FAIL
  retention_local
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-05"   # uploaded now: removed
  make_shots 2026-10-06 1                                        # old, uploaded, not reported, inside the window
  upload_day 2026-10-06
  retention_local
  assert_dir_exists "$SCREENLOG_DATA_DIR/shots/2026-10-06"
}

@test "retention: Drive retention runs delete then rmdirs, and not at all when disabled" {
  mkdir -p "$(remote_day 2026-08-01)" "$(remote_day 2026-10-15)"
  printf 'old' > "$(remote_day 2026-08-01)/09-00-00.jpg"
  touch -d '2026-08-01 09:00:00' "$(remote_day 2026-08-01)/09-00-00.jpg"
  printf 'new' > "$(remote_day 2026-10-15)/09-00-00.jpg"
  retention_run with-remote
  run stub_argv rclone 1
  assert_output --partial "delete screenlog-gdrive:Screenlog/rahim-uddin --min-age 60d --retries 2"
  run stub_argv rclone 2
  assert_output --partial "rmdirs screenlog-gdrive:Screenlog/rahim-uddin --leave-root --retries 2"
  assert_file_not_exists "$(remote_day 2026-08-01)/09-00-00.jpg"
  assert_dir_not_exists "$(remote_day 2026-08-01)"
  assert_file_exists "$(remote_day 2026-10-15)/09-00-00.jpg"
  assert_dir_exists "$STUB_REMOTE_DIR/Screenlog/rahim-uddin"
  REMOTE_RETENTION_DAYS=0
  retention_run with-remote
  assert_equal "$(stub_calls rclone)" 2
  retention_run
  assert_equal "$(stub_calls rclone)" 2
}

@test "screenlogd --once: the shot is uploaded right away and the log line says so" {
  export SCREENLOG_DISPLAY=:1
  run screenlogd --once
  assert_success
  assert_output "INFO: sample day=2026-10-15 status=shot idle=1 file=10-00-00.jpg upload=ok"
  assert_file_exists "$(remote_day 2026-10-15)/10-00-00.jpg"
  assert_file_exists "$(remote_day 2026-10-15)/samples.csv"
  run stub_argv rclone 1
  assert_output --partial "--checkers 4 --retries 1"
}

@test "screenlogd --once: upload failures and a busy lock never fail the sample" {
  export SCREENLOG_DISPLAY=:1
  STUB_RCLONE_FAIL=copy run screenlogd --once
  assert_success
  assert_output --partial 'upload=failed(1) upload_error="rclone exit 1: Failed to copy'
  refute_secrets
  mkdir -p "$SCREENLOG_DATA_DIR/state"
  flock "$SCREENLOG_DATA_DIR/state/rclone.lock" sleep 20 </dev/null >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  sleep 0.3
  SCREENLOG_LOCK_WAIT=1 run screenlogd --once
  assert_success
  assert_output --partial "upload=skipped(lock busy)"
}
