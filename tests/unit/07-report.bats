#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  SCREENLOG_TMP="$BATS_TEST_TMPDIR/screenlog-tmp"
  mkdir -p "$SCREENLOG_TMP"
  use_stubs hostname curl rclone
  set_now "2026-10-15T17:45:00+06:00"
}

remote_day() { printf '%s/Screenlog/rahim-uddin/%s\n' "$STUB_REMOTE_DIR" "$1"; }

@test "report: one day is uploaded, posted with the sheet, linked and marked; a second run posts nothing" {
  make_day 2026-10-15 day-rounding.csv
  run screenlog report --date 2026-10-15
  assert_success
  assert_output --partial "report: posted 2026-10-15 (HTTP 200)"
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output "📸 Rahim Uddin — Thu 15 Oct 2026
3 shots · 2 active (67%) · first 09:00 · last 09:20
Full size: https://drive.google.com/drive/folders/id-2026-10-15
dev-pc-03 · v1.0.0"
  run jq -c '.allowed_mentions' "$STUB_LOG_DIR/curl.payload.1.json"
  assert_output '{"parse":[]}'
  run curl_attach
  assert_output --regexp "^1 $SCREENLOG_DATA_DIR/shots/2026-10-15/contact-sheet.jpg [0-9]+$"
  assert_file_exists "$(remote_day 2026-10-15)/contact-sheet.jpg"
  assert_file_exists "$(remote_day 2026-10-15)/09-00-00.jpg"
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-15"
  run screenlog report --date 2026-10-15
  assert_success
  assert_output "already reported on 2026-10-15; use --dry-run to rebuild"
  assert_equal "$(curl_posts)" 1
  run screenlog report --pending
  assert_equal "$(curl_posts)" 1
}

@test "report: the webhook URL goes to curl through a private file, pinned to API v10, never argv" {
  make_day 2026-10-15 day-single.csv
  run screenlog report --date 2026-10-15
  assert_success
  run cat "$STUB_LOG_DIR/curl.url"
  assert_output "https://discord.com/api/v10/webhooks/123456789012345678/$DISCORD_WEBHOOK_TOKEN"
  run cat "$STUB_LOG_DIR/curl.cfgmode"
  assert_output "600"
  run grep -c "$DISCORD_WEBHOOK_TOKEN" "$STUB_LOG_DIR/curl.log"
  assert_output 0
}

@test "report: a failed post keeps the day pending and exits 1; the next run posts it" {
  make_day 2026-10-15 day-single.csv
  STUB_CURL_PLAN="7 7 7 7" run screenlog report --pending
  assert_failure 1
  assert_output --partial "not posted: curl exit 7"
  assert_equal "$(stub_calls curl)" 4
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/reported-days"
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 5
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-15"
}

@test "report: a 429 waits for retry_after and then succeeds" {
  make_day 2026-10-15 day-single.csv
  STUB_CURL_PLAN="429 200" run screenlog report --pending
  assert_success
  assert_output --partial "rate limited (HTTP 429), waiting 1s"
  assert_equal "$(stub_calls curl)" 2
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-15"
}

@test "report: 401 and 404 are permanent; after a 404 nothing else is posted in that run" {
  make_day 2026-10-14 day-single.csv
  make_day 2026-10-15 day-single.csv
  STUB_CURL_PLAN="404" run screenlog report --pending
  assert_failure 1
  assert_output --partial "HTTP 404: Unknown Webhook"
  assert_output --partial "Discord unreachable; 2026-10-15 waits for the next run"
  assert_equal "$(stub_calls curl)" 1
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/reported-days"
  STUB_CURL_PLAN="401 401" run screenlog report --pending
  assert_failure 1
  assert_output --partial "HTTP 401"
  assert_equal "$(stub_calls curl)" 3
  refute_secrets
}

@test "report: when Drive fails the report is still posted with the warning line and marked" {
  make_day 2026-10-15 day-single.csv
  STUB_RCLONE_FAIL=copy run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_line --index 2 "⚠️ Drive upload failed: rclone exit 1: Failed to copy: couldn't connect (stub) — will retry"
  run cat "$SCREENLOG_DATA_DIR/state/reported-days"
  assert_output "2026-10-15"
  make_day 2026-10-14 day-single.csv
  STUB_RCLONE_FAIL=lsjson run screenlog report --pending
  assert_success
  run curl_content 2
  assert_line --index 2 "⚠️ Drive link unavailable: Failed to lsjson: couldn't connect (stub)"
}

@test "report: a day with locked samples only is posted without an attachment" {
  make_day 2026-10-15 day-all-locked.csv
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_line --index 1 "0 shots · 0 active (0%) · locked 5×"
  run curl_attach
  assert_output ""
}

@test "report: --dry-run writes the message, the sheet and the manifest, and has no side effects" {
  make_day 2026-10-15 day-normal.csv
  find "$SCREENLOG_DATA_DIR" -printf '%p %s\n' | sort > "$BATS_TEST_TMPDIR/before"
  run screenlog report --dry-run --date 2026-10-15
  assert_success
  local dir
  dir=$(sed -n 's/^dry-run dir: //p' <<< "$output")
  assert_dir_exists "$dir"
  assert_line "message: $dir/message.json"
  assert_line "contact-sheet: $dir/contact-sheet.jpg"
  run jq -r '.content' "$dir/message.json"
  assert_line --index 0 "📸 Rahim Uddin — Thu 15 Oct 2026"
  assert_line --index 1 "58 shots · 49 active (84%) · locked 6× · first 09:12 · last 17:24"
  assert_line --index 2 "⚠️ No samples 13:05–14:02"
  assert_line --index 3 "Full size: (dry run — not uploaded)"
  run identify -format '%m' "$dir/contact-sheet.jpg"
  assert_output "JPEG"
  assert_equal "$(grep -c '' "$dir/tiles.tsv")" 59
  run sed -n '2p' "$dir/tiles.tsv"
  assert_output --partial $'1\t09-12-33.jpg\t09:12 · active\tactive\t'
  assert_equal "$(grep -c $'\tidle\t' "$dir/tiles.tsv")" 9
  # the first idle row of the fixture, caption text computed independently of the code under test
  local row ts idle f hhmm
  row=$(awk -F, 'NR > 1 && $2 == "shot" && $3 + 0 >= 300 { print; exit }' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv")
  IFS=, read -r ts _ idle f _ <<< "$row"
  hhmm=${ts:11:5}
  run grep -c $'\t'"$f"$'\t'"$hhmm · idle $(( idle / 60 ))m"$'\tidle\t' "$dir/tiles.tsv"
  assert_output 1
  run find "$SCREENLOG_DATA_DIR/shots/2026-10-15" "$dir" -name '*.tmp' -o -name '.contact-sheet.*'
  assert_output ""
  find "$SCREENLOG_DATA_DIR" -printf '%p %s\n' | sort > "$BATS_TEST_TMPDIR/after"
  run diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  assert_success
  assert_equal "$(stub_calls curl)" 0
  assert_equal "$(stub_calls rclone)" 0
  run cat "$dir/message.json"
  refute_secrets
  run screenlog report --dry-run --pending
  assert_success
  assert_output --partial "message: "
  assert_equal "$(stub_calls curl)" 0
}

@test "report: shots taken after the report keep uploading but the posted sheet is unchanged" {
  make_day 2026-10-15 day-normal.csv
  run screenlog report --pending
  assert_success
  run find "$SCREENLOG_DATA_DIR/shots/2026-10-15" -name '*.tmp' -o -name '.contact-sheet.*'
  assert_output ""
  local c1
  c1=$(cksum < "$SCREENLOG_DATA_DIR/shots/2026-10-15/contact-sheet.jpg")
  use_stubs loginctl runuser gdbus xprintidle ffmpeg
  export SCREENLOG_DISPLAY=:1
  set_now "2026-10-15T17:48:00+06:00"
  run screenlogd --once
  assert_success
  assert_output --partial "upload=ok"
  assert_file_exists "$(remote_day 2026-10-15)/17-48-00.jpg"
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 1
  assert_equal "$(cksum < "$SCREENLOG_DATA_DIR/shots/2026-10-15/contact-sheet.jpg")" "$c1"
}

@test "report: a run that posted triggers Drive retention; retention never blocks a report" {
  make_day 2026-10-15 day-single.csv
  run screenlog report --pending
  assert_success
  run grep -c ' delete ' "$STUB_LOG_DIR/rclone.log"
  assert_output 1
  run grep -c ' rmdirs ' "$STUB_LOG_DIR/rclone.log"
  assert_output 1
  make_day 2026-10-07 day-single.csv
  set_config LOCAL_RETENTION_DAYS 7
  run screenlog report --pending
  assert_success
  assert_equal "$(curl_posts)" 2
  assert_dir_not_exists "$SCREENLOG_DATA_DIR/shots/2026-10-07"   # reported this run, uploaded, old enough
}

@test "report: the deadline stops further days and a second run holding the lock is refused" {
  make_day 2026-10-13 day-single.csv
  make_day 2026-10-14 day-single.csv
  SCREENLOG_REPORT_DEADLINE=0 run screenlog report --pending
  assert_failure 1
  assert_output --partial "deadline reached"
  assert_equal "$(curl_posts)" 0
  make_day 2026-10-15 day-single.csv   # no missing-day notice now; the days themselves are deferred
  SCREENLOG_REPORT_DEADLINE=0 run screenlog report --pending
  assert_failure 1
  assert_output --partial "deadline reached; 2026-10-13 and later days"
  assert_equal "$(curl_posts)" 0
  mkdir -p "$SCREENLOG_DATA_DIR/state"
  flock "$SCREENLOG_DATA_DIR/state/report.lock" sleep 5 </dev/null >/dev/null 2>&1 3>&- &
  local p=$!
  sleep 0.3
  run screenlog report --pending
  assert_failure 5
  assert_output --partial "another report run is in progress"
  kill "$p" 2>/dev/null || true
}

@test "report: usage errors" {
  run screenlog report --date 2026-10-15 --pending
  assert_failure 2
  run screenlog report --date 2026-10-15
  assert_failure 2
  assert_output --partial "no local folder"
  run screenlog report --bogus
  assert_failure 2
  run screenlog bogus
  assert_failure 2
  run screenlog version
  assert_output "1.0.0"
  run screenlog help
  assert_output --partial "report [--date YYYY-MM-DD]"
}

@test "report: every command but version and help needs root" {
  need_root
  run setpriv --reuid=65534 --regid=65534 --clear-groups "$REPO_ROOT/bin/screenlog" report --pending
  assert_failure 4
  assert_output --partial "must run as root"
  run setpriv --reuid=65534 --regid=65534 --clear-groups "$REPO_ROOT/bin/screenlog" version
  assert_success
}

@test "discord: the production backoff default is 60 240 600 and respects the deadline" {
  tmp_init
  DISCORD_DEADLINE=$(( EPOCHSECONDS + 1 ))
  # shellcheck disable=SC2016  # the inner bash expands $1 and $2 itself
  STUB_CURL_PLAN="7 7 7 7" run env -u SCREENLOG_DISCORD_BACKOFF bash -c 'source "$1/lib/log.sh"; source "$1/lib/config.sh"; source "$1/lib/time.sh"; source "$1/lib/discord.sh"; config_load; SCREENLOG_TMP=$2; DISCORD_DEADLINE=$(( EPOCHSECONDS + 1 )); discord_post hi; echo "kind=$DISCORD_LAST_KIND"' _ "$REPO_ROOT" "$SCREENLOG_TMP"
  assert_output --partial "attempt 1 failed (curl exit 7"
  assert_output --partial "retrying in 60s"
  assert_output --partial "kind=deadline"
  assert_equal "$(stub_calls curl)" 1
  tmp_cleanup
}

@test "discord: validation GETs the webhook and never prints the body" {
  tmp_init
  run discord_validate
  assert_success
  discord_validate
  assert_equal "$DISCORD_WEBHOOK_NAME" screenlog
  run stub_call curl 1
  assert_output --partial "-X GET"
  refute_output --partial payload_json
  stub_reset curl
  STUB_CURL_PLAN="404" run discord_validate
  assert_failure
  stub_reset curl
  STUB_CURL_PLAN="404" discord_validate || true
  assert_equal "$DISCORD_LAST_ERROR" "HTTP 404"
  stub_reset curl
  STUB_CURL_PLAN="7" run discord_validate
  assert_failure
  tmp_cleanup
}

@test "discord: images for single posts are at most 960 px wide" {
  convert -size 1920x1080 xc:'#336699' "jpeg:$BATS_TEST_TMPDIR/big.jpg"
  convert -size 800x600 xc:'#336699' "jpeg:$BATS_TEST_TMPDIR/small.jpg"
  discord_prepare_image "$BATS_TEST_TMPDIR/big.jpg" "$BATS_TEST_TMPDIR/big-out.jpg"
  discord_prepare_image "$BATS_TEST_TMPDIR/small.jpg" "$BATS_TEST_TMPDIR/small-out.jpg"
  run identify -format '%w' "$BATS_TEST_TMPDIR/big-out.jpg"
  assert_output 960
  run identify -format '%w' "$BATS_TEST_TMPDIR/small-out.jpg"
  assert_output 800
}
