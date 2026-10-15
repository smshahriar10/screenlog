#!/usr/bin/env bats
# screenlog test / status / doctor against a real Xvfb display.
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
  use_stubs hostname curl rclone systemctl journalctl timedatectl
  xprintidle_or_stub
}

@test "cli-x: screenlog test captures the real display, uploads and posts a 960 px image" {
  run screenlog test
  assert_success
  assert_output --regexp 'capture: [0-9]+ ms, 10-00-00\.jpg \([0-9]+ bytes\), idle [0-9]+s'
  assert_output --partial "upload: ok"
  assert_output --partial "discord: HTTP 200"
  assert_equal "$(curl_posts)" 1
  run curl_content 1
  assert_output "🧪 Test from Rahim Uddin"
  run identify -format '%w %h' "$STUB_LOG_DIR/curl.attach.1"
  assert_output "960 600"
  run identify -format '%w %h' "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-00-00.jpg"
  assert_output "1728 1080"
  assert_file_exists "$STUB_REMOTE_DIR/Screenlog/rahim-uddin/2026-10-15/10-00-00.jpg"
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/setup-announced"
}

@test "cli-x: status and doctor report the display override" {
  run screenlog status
  assert_success
  assert_line "session:          override (SCREENLOG_DISPLAY=$SCREENLOG_DISPLAY)"
  refute_secrets
  SCREENLOG_ARCH=amd64 run screenlog doctor
  assert_line "PASS session: override (SCREENLOG_DISPLAY=$SCREENLOG_DISPLAY)"
  refute_secrets
}
