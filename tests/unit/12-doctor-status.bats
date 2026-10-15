#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  use_stubs hostname curl rclone systemctl journalctl timedatectl loginctl runuser gdbus xprintidle ffmpeg
  mkdir -p "$SCREENLOG_SYSROOT/etc/gdm3" "$SCREENLOG_SYSROOT/etc/update-manager"
  printf '[daemon]\nWaylandEnable=false\n' > "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf"
  printf '[DEFAULT]\nPrompt=never\n' > "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades"
  cp /etc/os-release "$SCREENLOG_SYSROOT/etc/os-release"
  chmod 700 "$SCREENLOG_TEST_BASE/etc"
  export SCREENLOG_ARCH=amd64
  set_now "2026-10-15T09:10:00+06:00"   # capture hours started 10 min ago: no sample yet is fine
}

@test "doctor: every line is PASS/WARN/FAIL, all green on a healthy PC" {
  run screenlog doctor
  assert_success
  local l
  for l in "${lines[@]}"; do
    [[ $l =~ ^(PASS|WARN|FAIL)\ .+:\ .+$ || $l == doctor:* ]]
  done
  assert_line --partial "PASS os: Ubuntu 24.04"
  assert_line "PASS arch: amd64"
  assert_line --partial "PASS wayland: WaylandEnable=false"
  assert_line "PASS session: x11 (rahim, session 3)"
  assert_line --partial "PASS upgrades: Prompt=never"
  assert_line "PASS packages: all present"
  assert_line "PASS rclone: version 1.60.1"
  assert_line "PASS config: $SCREENLOG_CONFIG valid"
  assert_line --partial "PASS config mode"
  assert_line --partial "PASS rclone client_id"
  assert_line "PASS drive: screenlog-gdrive:Screenlog/rahim-uddin reachable"
  assert_line 'PASS webhook: valid (HTTP 200, "screenlog")'
  assert_line "PASS screenlog.service: enabled and active"
  assert_line "PASS screenlog-report.timer: enabled and active"
  assert_line --partial "PASS disk:"
  assert_line "PASS time zone: Asia/Dhaka"
  assert_line "PASS last sample: no sample yet today"
  assert_line "doctor: 0 warning(s), 0 failure(s)"
  run stub_argv curl 1
  assert_output --partial "-X GET"
  refute_secrets
}

@test "doctor: failures and warnings are reported one per check, exit 1 only on FAIL" {
  STUB_CURL_PLAN=404 run screenlog doctor
  assert_failure 1
  assert_line "FAIL webhook: HTTP 404"
  STUB_RCLONE_FAIL=lsd run screenlog doctor
  assert_failure 1
  assert_line --partial "FAIL drive: screenlog-gdrive:Screenlog/rahim-uddin: Failed to lsd"
  STUB_RCLONE_VERSION=v1.53.3 run screenlog doctor
  assert_failure 1
  assert_line "FAIL rclone: version 1.53.3; 1.60 or newer is required"
  STUB_LOGINCTL_SCENARIO=wayland run screenlog doctor
  assert_failure 1
  assert_line --partial "FAIL session: wayland session"
  STUB_LOGINCTL_SCENARIO=none run screenlog doctor
  assert_success
  assert_line "WARN session: nobody is logged in on seat0"
  STUB_TZ=UTC run screenlog doctor
  assert_success
  assert_line --partial "WARN time zone: UTC (expected Asia/Dhaka"
  STUB_NTP=no run screenlog doctor
  assert_line --partial "WARN clock sync"
  SCREENLOG_ARCH=arm64 run screenlog doctor
  assert_success
  assert_line "WARN arch: arm64 (the supported PCs are amd64)"
  STUB_SYSTEMCTL_ACTIVE=inactive run screenlog doctor
  assert_failure 1
  assert_line --partial "FAIL screenlog.service: enabled / inactive"
  STUB_SYSTEMCTL_FAILED=screenlog-report.service run screenlog doctor
  assert_line "WARN last report run: failed (sudo screenlog logs)"
  printf '[daemon]\n#WaylandEnable=false\n' > "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf"
  printf '[DEFAULT]\nPrompt=lts\n' > "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades"
  cp "$REPO_ROOT/tests/fixtures/os-release-22.04" "$SCREENLOG_SYSROOT/etc/os-release"
  run screenlog doctor
  assert_failure 1
  assert_line --partial "FAIL os: Ubuntu 22.04"
  assert_line --partial "FAIL wayland"
  assert_line --partial "FAIL upgrades"
  assert_line "doctor: 0 warning(s), 3 failure(s)"
}

@test "doctor: the shared rclone client_id is a warning, a missing remote section a failure" {
  printf '[screenlog-gdrive]\ntype = drive\nscope = drive\ntoken = {"access_token":"x"}\n' > "$SCREENLOG_RCLONE_CONF"
  run screenlog doctor
  assert_line --partial "WARN rclone client_id: [screenlog-gdrive] uses rclone's shared client_id"
  printf '[other]\ntype = drive\n' > "$SCREENLOG_RCLONE_CONF"
  run screenlog doctor
  assert_failure 1
  assert_line "FAIL rclone remote: no [screenlog-gdrive] section in $SCREENLOG_RCLONE_CONF"
}

@test "doctor: an invalid config is a failure, remote checks are skipped and the table stays complete" {
  set_config SHOTS_PER_HOUR abc
  run screenlog doctor
  assert_failure 1
  assert_line "config: SHOTS_PER_HOUR: must be an integer from 1 to 60"
  assert_line "FAIL config: $SCREENLOG_CONFIG has 1 error(s), see above"
  assert_line "WARN drive: skipped (config invalid)"
  assert_line "WARN webhook: skipped (config invalid)"
  assert_line --partial "PASS screenlog.service"
  assert_line --partial "PASS time zone"
  assert_equal "$(stub_calls curl)" 0
  run grep -c ' lsd ' "$STUB_LOG_DIR/rclone.log"
  assert_output 0
}

@test "doctor: last sample age inside capture hours" {
  make_day 2026-10-15 day-single.csv   # last sample 09:12:33; MAX_GAP_SECONDS is 30 min
  set_now "2026-10-15T09:45:00+06:00"
  run screenlog doctor
  assert_line "WARN last sample: 32 min ago, more than MAX_GAP_SECONDS"
  set_now "2026-10-15T09:40:00+06:00"
  run screenlog doctor
  assert_line "PASS last sample: 27 min ago"
  set_now "2026-10-15T10:00:00+06:00"
  run screenlog doctor
  assert_line --partial "FAIL last sample: 47 min ago, more than MAX_GAP_SECONDS+5min"
  set_now "2026-10-15T18:30:00+06:00"
  run screenlog doctor
  assert_line --partial "PASS last sample: 557 min ago (outside capture hours now)"
  rm -rf "$SCREENLOG_DATA_DIR/shots"
  set_now "2026-10-15T10:00:00+06:00"
  run screenlog doctor
  assert_line --partial "WARN last sample: no sample yet today although capture hours started"
}

@test "status: the overview lines, no secrets" {
  make_day 2026-10-15 day-gap-edges.csv
  make_day 2026-10-14 day-single.csv
  run screenlog status
  assert_success
  assert_line "version:          1.0.0 (dev-pc-03)"
  assert_line "employee:         Rahim Uddin (rahim-uddin)"
  assert_line "service:          active (enabled)"
  assert_line "report timer:     active (enabled), next: Thu 2026-10-15 17:30:00 +06"
  assert_line "session:          x11 (rahim, session 3)"
  assert_line "capture window:   09:00-17:50, ~7 shots/h, report 17:30 on Sun Mon Tue Wed Thu"
  assert_line "today:            6 samples: 4 shots (4 active, 100%), locked 1, no session 0, unsupported 0, errors 1"
  assert_line "last sample:      2026-10-15T12:00:30+06:00 error (ffmpeg exit 1)"
  assert_line "pending uploads:  2 day(s): 2026-10-14 2026-10-15"
  assert_line "pending reports:  1 day(s): 2026-10-14"
  assert_line --partial "disk:             shots "
  assert_line "config:           $SCREENLOG_CONFIG valid"
  assert_line "  DISCORD_WEBHOOK_URL=<set>"
  refute_secrets
}

@test "status: session variants and an invalid config still print the service state" {
  SCREENLOG_DISPLAY=:1 run screenlog status
  assert_line "session:          override (SCREENLOG_DISPLAY=:1)"
  STUB_LOGINCTL_SCENARIO=wayland run screenlog status
  assert_line --partial "session:          wayland (unsupported"
  STUB_LOGINCTL_SCENARIO=none run screenlog status
  assert_line "session:          none"
  set_config SHOTS_PER_HOUR abc
  run screenlog status
  assert_success
  assert_line "service:          active (enabled)"
  assert_line --partial "config:           $SCREENLOG_CONFIG INVALID"
  refute_secrets
}
