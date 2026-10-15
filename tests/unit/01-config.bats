#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() { screenlog_test_setup; }

expect_config_error() {   # expect_config_error PARTIAL: config_check fails and names the problem
  run config_check "$SCREENLOG_CONFIG"
  assert_failure
  assert_output --partial "$1"
  refute_secrets
}

@test "config: the fixture loads and every key is set" {
  config_load
  assert_equal "$EMPLOYEE_NAME" "Rahim Uddin"
  assert_equal "$EMPLOYEE_SLUG" "rahim-uddin"
  assert_equal "$RCLONE_REMOTE" "screenlog-gdrive"
  assert_equal "$DRIVE_ROOT" "Screenlog"
  assert_equal "$SHOTS_PER_HOUR" 7
  assert_equal "$MIN_GAP_SECONDS" 60
  assert_equal "$MAX_GAP_SECONDS" 1800
  assert_equal "$CAPTURE_START" "09:00"
  assert_equal "$CAPTURE_END" "17:50"
  assert_equal "$IDLE_THRESHOLD_SECONDS" 300
  assert_equal "$JPEG_QUALITY" 85
  assert_equal "$MAX_HEIGHT" 1080
  assert_equal "$REPORT_TIME" "17:30"
  assert_equal "$WORK_DAYS" "Sun Mon Tue Wed Thu"
  assert_equal "$GAP_ALERT_MINUTES" 45
  assert_equal "$LOCAL_RETENTION_DAYS" 7
  assert_equal "$REMOTE_RETENTION_DAYS" 60
  assert_equal "$UPLOAD_BWLIMIT" "1M"
  assert_equal "$DISCORD_WEBHOOK_ID" "123456789012345678"
  assert_equal "$DISCORD_API_URL" "https://discord.com/api/v10/webhooks/123456789012345678/$DISCORD_WEBHOOK_TOKEN"
  assert_equal "$REMOTE_EMPLOYEE" "screenlog-gdrive:Screenlog/rahim-uddin"
  assert_equal "$SHOTS_DIR" "$SCREENLOG_DATA_DIR/shots"
}

@test "config: missing optional keys get their defaults" {
  unset_config SHOTS_PER_HOUR WORK_DAYS UPLOAD_BWLIMIT RCLONE_REMOTE
  config_load
  assert_equal "$SHOTS_PER_HOUR" 7
  assert_equal "$WORK_DAYS" "Sun Mon Tue Wed Thu"
  assert_equal "$UPLOAD_BWLIMIT" "1M"
  assert_equal "$RCLONE_REMOTE" "screenlog-gdrive"
}

@test "config: missing required keys are reported by name" {
  unset_config EMPLOYEE_SLUG
  expect_config_error "missing required key EMPLOYEE_SLUG"
  unset_config DISCORD_WEBHOOK_URL
  expect_config_error "missing required key DISCORD_WEBHOOK_URL"
}

@test "config: unknown keys are rejected with their line number and never assigned" {
  append_config_line 'FOO="1"'
  expect_config_error "line 20: unknown key FOO"
  append_config_line 'PATH="/evil"'
  config_check "$SCREENLOG_CONFIG" 2>/dev/null || true
  [[ $PATH != /evil* ]]
}

@test "config: webhook URL formats" {
  local bad
  for bad in "http://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz" \
             "https://example.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz" \
             "https://discord.com/api/webhooks/notanumber/abcdefghijklmnopqrstuvwxyz" \
             "https://discord.com/api/webhooks/123456789012345678/short" \
             ""; do
    set_config DISCORD_WEBHOOK_URL "$bad"
    expect_config_error "DISCORD_WEBHOOK_URL: must look like"
  done
  set_config DISCORD_WEBHOOK_URL "https://discordapp.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz_-0123"
  config_load
  assert_equal "$DISCORD_API_URL" "https://discord.com/api/v10/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz_-0123"
  set_config DISCORD_WEBHOOK_URL "https://ptb.discord.com/api/v9/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz_-0123/"
  config_load
  assert_equal "$DISCORD_API_URL" "https://discord.com/api/v10/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz_-0123"
}

@test "config: GAP_ALERT_MINUTES must exceed MAX_GAP_SECONDS/60" {
  set_config MAX_GAP_SECONDS 1800 GAP_ALERT_MINUTES 30
  expect_config_error "GAP_ALERT_MINUTES: must be greater than MAX_GAP_SECONDS/60"
  set_config GAP_ALERT_MINUTES 31
  config_load
  set_config MAX_GAP_SECONDS 2700 GAP_ALERT_MINUTES 45
  expect_config_error "GAP_ALERT_MINUTES"
}

@test "config: integer bounds" {
  local kv
  for kv in "SHOTS_PER_HOUR abc" "SHOTS_PER_HOUR 0" "SHOTS_PER_HOUR -1" "SHOTS_PER_HOUR 61" \
            "JPEG_QUALITY 0" "JPEG_QUALITY 101" "MAX_HEIGHT 0" "MAX_HEIGHT 100" \
            "LOCAL_RETENTION_DAYS -1" "LOCAL_RETENTION_DAYS 0" "REMOTE_RETENTION_DAYS x" \
            "MIN_GAP_SECONDS 0" "IDLE_THRESHOLD_SECONDS -5"; do
    # shellcheck disable=SC2086  # intentional word split into KEY VALUE
    set_config $kv
    expect_config_error "${kv%% *}: must be an integer"
    cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  done
  set_config MIN_GAP_SECONDS 1801
  expect_config_error "MAX_GAP_SECONDS: must not be less than MIN_GAP_SECONDS"
  set_config MIN_GAP_SECONDS 1 MAX_GAP_SECONDS 1 GAP_ALERT_MINUTES 1
  config_load
  assert_equal "$MAX_GAP_SECONDS" 1
}

@test "config: times" {
  local kv
  for kv in "CAPTURE_START 9:00" "CAPTURE_START 25:00" "CAPTURE_END 09:60" "REPORT_TIME 5pm"; do
    # shellcheck disable=SC2086
    set_config $kv
    expect_config_error "${kv%% *}: must be HH:MM"
    cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  done
  set_config CAPTURE_START 17:50 CAPTURE_END 17:50
  expect_config_error "CAPTURE_END: must be later than CAPTURE_START"
  set_config CAPTURE_START 18:00
  expect_config_error "CAPTURE_END: must be later than CAPTURE_START"
}

@test "config: WORK_DAYS" {
  set_config WORK_DAYS "Mon Tue Xyz"
  expect_config_error "WORK_DAYS: must be space-separated day names"
  set_config WORK_DAYS "mon"
  expect_config_error "WORK_DAYS"
  set_config WORK_DAYS "Mon Mon"
  expect_config_error "WORK_DAYS: day listed twice"
  set_config WORK_DAYS ""
  config_load
  assert_equal "$WORK_DAYS" ""
}

@test "config: other value rules" {
  set_config UPLOAD_BWLIMIT "fast"
  expect_config_error "UPLOAD_BWLIMIT"
  set_config UPLOAD_BWLIMIT "off"
  config_load
  set_config UPLOAD_BWLIMIT "2.5M"
  config_load
  set_config EMPLOYEE_SLUG "Rahim"
  expect_config_error "EMPLOYEE_SLUG"
  set_config EMPLOYEE_SLUG "rahim--uddin"
  expect_config_error "EMPLOYEE_SLUG"
  set_config EMPLOYEE_SLUG "-rahim"
  expect_config_error "EMPLOYEE_SLUG"
  set_config EMPLOYEE_SLUG "rahim-uddin"
  set_config RCLONE_REMOTE "bad remote"
  expect_config_error "RCLONE_REMOTE"
  set_config RCLONE_REMOTE "ok_remote.1"
  set_config DRIVE_ROOT "/Screenlog"
  expect_config_error "DRIVE_ROOT"
  set_config DRIVE_ROOT "Screenlog/sub"
  config_load
  assert_equal "$DRIVE_ROOT" "Screenlog/sub"
}

@test "config: EMPLOYEE_NAME is counted in characters and may not hold quotes" {
  local name
  name=$(printf 'র%.0s' {1..80})
  set_config EMPLOYEE_NAME "$name"
  config_load
  assert_equal "${#EMPLOYEE_NAME}" 80
  name=$(printf 'র%.0s' {1..81})
  set_config EMPLOYEE_NAME "$name"
  expect_config_error "EMPLOYEE_NAME: must be 1 to 80 characters"
  set_config EMPLOYEE_NAME ""
  expect_config_error "EMPLOYEE_NAME: must be 1 to 80 characters"
  append_config_line "EMPLOYEE_NAME='Say \"hi\"'"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  unset_config EMPLOYEE_NAME
  append_config_line "EMPLOYEE_NAME='Say \"hi\"'"
  expect_config_error "EMPLOYEE_NAME: must not contain quotes"
  unset_config EMPLOYEE_NAME
  append_config_line "EMPLOYEE_NAME='O'"
  config_load
  set_config EMPLOYEE_NAME "Conan O'Brien"
  config_load
  assert_equal "$EMPLOYEE_NAME" "Conan O'Brien"
}

@test "config: accepted syntax" {
  cat > "$SCREENLOG_CONFIG" <<'CONF'
# a comment

   # indented comment
EMPLOYEE_NAME="Rahim Uddin"
  EMPLOYEE_SLUG="rahim-uddin"
DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz_-0123'
SHOTS_PER_HOUR=9   # trailing comment
DRIVE_ROOT="Screen log"
WORK_DAYS=""
CONF
  printf 'JPEG_QUALITY="70"\r\n' >> "$SCREENLOG_CONFIG"
  config_load
  assert_equal "$SHOTS_PER_HOUR" 9
  assert_equal "$DRIVE_ROOT" "Screen log"
  assert_equal "$JPEG_QUALITY" 70
  assert_equal "$WORK_DAYS" ""
}

@test "config: rejected syntax" {
  append_config_line 'export JPEG_QUALITY=80'
  expect_config_error "line 20: cannot parse"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  append_config_line 'JPEG_QUALITY = 80'
  expect_config_error "line 20: cannot parse"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  append_config_line 'DRIVE_ROOT="a" extra'
  expect_config_error "line 20: DRIVE_ROOT: cannot parse value"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  append_config_line 'JPEG_QUALITY=80'
  expect_config_error "line 20: duplicate key JPEG_QUALITY"
}

@test "config: command substitutions and chained commands never execute" {
  local canary="$BATS_TEST_TMPDIR/pwned" line
  for line in "EMPLOYEE_NAME=\"\$(touch $canary)\"" \
              "EMPLOYEE_NAME=\$(touch $canary)" \
              "EMPLOYEE_NAME=\`touch $canary\`" \
              "EMPLOYEE_NAME=\"x\"; touch $canary" \
              "EMPLOYEE_NAME=\"x\" && touch $canary"; do
    cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
    unset_config EMPLOYEE_NAME
    append_config_line "$line"
    run config_check "$SCREENLOG_CONFIG"
    assert_file_not_exists "$canary"
  done
  # the double-quoted form is a valid literal string
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$SCREENLOG_CONFIG"
  unset_config EMPLOYEE_NAME
  # shellcheck disable=SC2016  # the literal $( is the point of the test
  append_config_line 'EMPLOYEE_NAME="$(touch /tmp/x)"'
  config_load
  # shellcheck disable=SC2016
  assert_equal "$EMPLOYEE_NAME" '$(touch /tmp/x)'
  assert_file_not_exists "$canary"
}

@test "config: config_print_public masks the webhook" {
  config_load
  run config_print_public
  assert_success
  assert_line "DISCORD_WEBHOOK_URL=<set>"
  assert_line "EMPLOYEE_NAME=Rahim Uddin"
  refute_secrets
}

@test "config: config_read_key reads one key from another file without touching globals" {
  config_load
  printf 'EMPLOYEE_NAME="Other Person"\nEMPLOYEE_SLUG=other\n' > "$BATS_TEST_TMPDIR/installed.conf"
  run config_read_key "$BATS_TEST_TMPDIR/installed.conf" EMPLOYEE_NAME
  assert_output "Other Person"
  run config_read_key "$BATS_TEST_TMPDIR/installed.conf" EMPLOYEE_SLUG
  assert_output "other"
  run config_read_key "$BATS_TEST_TMPDIR/installed.conf" REPORT_TIME
  assert_failure
  assert_equal "$EMPLOYEE_NAME" "Rahim Uddin"
}

@test "config: parsing a second file does not report false duplicates" {
  config_defaults
  config_parse_file "$SCREENLOG_CONFIG"
  config_parse_file "$SCREENLOG_CONFIG"
  assert_equal "${#CONFIG_ERRORS[@]}" 0
}

@test "config: a missing file fails and names the path" {
  run config_check "$BATS_TEST_TMPDIR/nope.conf"
  assert_failure
  assert_output --partial "cannot read $BATS_TEST_TMPDIR/nope.conf"
}

@test "config: config_write round-trips every key with mode 600 and refuses bad characters" {
  config_load
  EMPLOYEE_NAME="Conan O'Brien"
  config_write "$BATS_TEST_TMPDIR/out.conf"
  assert_file_permission 600 "$BATS_TEST_TMPDIR/out.conf"
  config_defaults
  config_parse_file "$BATS_TEST_TMPDIR/out.conf"
  config_validate
  assert_equal "${#CONFIG_ERRORS[@]}" 0
  assert_equal "$EMPLOYEE_NAME" "Conan O'Brien"
  assert_equal "$JPEG_QUALITY" 85
  EMPLOYEE_NAME='bad "name"'
  run config_write "$BATS_TEST_TMPDIR/out2.conf"
  assert_failure
  assert_file_not_exists "$BATS_TEST_TMPDIR/out2.conf"
}
