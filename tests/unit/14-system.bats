#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  SCREENLOG_TMP="$BATS_TEST_TMPDIR/screenlog-tmp"
  mkdir -p "$SCREENLOG_TMP"
  F="$BATS_TEST_TMPDIR/custom.conf"
}

@test "ini: the stock GDM file gets WaylandEnable=false uncommented in [daemon], backed up once" {
  cp "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$F"
  ini_set_key "$F" daemon WaylandEnable false
  assert_equal "$INI_CHANGED" 1
  run ini_get_key "$F" daemon WaylandEnable
  assert_output "false"
  assert_equal "$(grep -c '^WaylandEnable=false$' "$F")" 1
  assert_equal "$(grep -c 'WaylandEnable' "$F")" 1
  run awk '/^\[daemon\]/ { s = 1; next } /^\[/ { s = 0 } s && /^WaylandEnable=false$/ { f = 1 } END { exit !f }' "$F"
  assert_success
  run diff "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$F.screenlog-bak"
  assert_success
  # idempotent: no rewrite, backup untouched
  local m1 m2
  m1=$(stat -c %Y "$F")
  sleep 1
  ini_set_key "$F" daemon WaylandEnable false
  assert_equal "$INI_CHANGED" 0
  m2=$(stat -c %Y "$F")
  assert_equal "$m1" "$m2"
  run diff "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$F.screenlog-bak"
  assert_success
}

@test "ini: an active WaylandEnable=true is replaced, duplicates dropped, other sections untouched" {
  printf '[daemon]\nWaylandEnable=true\nAutomaticLoginEnable=false\nWaylandEnable=true\n\n[security]\nWaylandEnable=true\n' > "$F"
  ini_set_key "$F" daemon WaylandEnable false
  run cat "$F"
  assert_output $'[daemon]\nWaylandEnable=false\nAutomaticLoginEnable=false\n\n[security]\nWaylandEnable=true'
}

@test "ini: a missing key is added to the section, a missing section is appended, an empty file works" {
  printf '[daemon]\nAutomaticLoginEnable=false\n[security]\n' > "$F"
  ini_set_key "$F" daemon WaylandEnable false
  run cat "$F"
  assert_output $'[daemon]\nAutomaticLoginEnable=false\nWaylandEnable=false\n[security]'
  printf '[security]\nx=1\n' > "$F"
  ini_set_key "$F" daemon WaylandEnable false
  run cat "$F"
  assert_output $'[security]\nx=1\n\n[daemon]\nWaylandEnable=false'
  : > "$F"
  ini_set_key "$F" daemon WaylandEnable false
  run cat "$F"
  assert_output $'[daemon]\nWaylandEnable=false'
  rm -f "$F" "$F.screenlog-bak"
  ini_set_key "$F" daemon WaylandEnable false
  run cat "$F"
  assert_output $'[daemon]\nWaylandEnable=false'
}

@test "ini: release-upgrades Prompt=lts becomes Prompt=never; the key is read back case-sensitively" {
  cp "$REPO_ROOT/tests/fixtures/release-upgrades" "$F"
  ini_set_key "$F" DEFAULT Prompt never
  run ini_get_key "$F" DEFAULT Prompt
  assert_output "never"
  assert_equal "$(grep -c '^Prompt=' "$F")" 1
  run ini_get_key "$F" DEFAULT prompt
  assert_failure
  run ini_get_key "$BATS_TEST_TMPDIR/nope" DEFAULT Prompt
  assert_failure
}

@test "system: version compare, rclone version parsing, os-release reader, arch hook" {
  run version_ge 1.60.1 1.60.0; assert_success
  run version_ge 1.60.0 1.60.0; assert_success
  run version_ge 1.53.3 1.60.0; assert_failure
  run version_ge 1.75.2 1.60.0; assert_success
  use_stubs rclone
  run rclone_version; assert_output "1.60.1"
  STUB_RCLONE_VERSION=v1.75.2-DEV run rclone_version; assert_output "1.75.2"
  cp "$REPO_ROOT/tests/fixtures/os-release-22.04" "$SCREENLOG_SYSROOT/etc/os-release"
  run os_field VERSION_ID; assert_output "22.04"
  run os_field ID; assert_output "ubuntu"
  run os_field PRETTY_NAME; assert_output "Ubuntu 22.04.4 LTS"
  SCREENLOG_ARCH=arm64 run system_arch; assert_output "arm64"
  run iec_or_na 1048576; assert_output "1.0M"
  run iec_or_na "[not set]"; assert_output "n/a"
}

@test "units: render installs the services verbatim and the timer with REPORT_TIME, idempotently" {
  local dest="$BATS_TEST_TMPDIR/units"
  mkdir -p "$dest"
  run units_render "$REPO_ROOT/systemd" "$dest" "17:30"
  assert_success
  assert_line "INFO: unit screenlog.service: updated"
  assert_line "INFO: unit screenlog-report.timer: updated"
  run diff "$REPO_ROOT/systemd/screenlog.service" "$dest/screenlog.service"; assert_success
  run diff "$REPO_ROOT/systemd/screenlog-report.service" "$dest/screenlog-report.service"; assert_success
  run grep -c 'OnCalendar=\*-\*-\* 17:30:00$' "$dest/screenlog-report.timer"; assert_output 1
  run grep -c 'OnCalendar=hourly' "$dest/screenlog-report.timer"; assert_output 1
  run grep -c '@' "$dest/screenlog-report.timer"; assert_output 0
  assert_file_permission 644 "$dest/screenlog-report.timer"
  run units_render "$REPO_ROOT/systemd" "$dest" "17:30"
  assert_line "INFO: unit screenlog-report.timer: unchanged"
  assert_equal "$UNITS_CHANGED" 0
  units_render "$REPO_ROOT/systemd" "$dest" "18:00"
  assert_equal "$UNITS_CHANGED" 1
  run grep -c 'OnCalendar=\*-\*-\* 18:00:00$' "$dest/screenlog-report.timer"; assert_output 1
}

@test "units: the spec's hardening lines are present and the forbidden ones absent" {
  local u
  for u in screenlog.service screenlog-report.service; do
    run grep -c 'NoNewPrivileges=yes' "$REPO_ROOT/systemd/$u"; assert_output 1
    run grep -c 'ProtectSystem=full' "$REPO_ROOT/systemd/$u"; assert_output 1
    run grep -c 'ReadWritePaths=/etc/screenlog /var/lib/screenlog' "$REPO_ROOT/systemd/$u"; assert_output 1
    run grep -c 'Nice=19' "$REPO_ROOT/systemd/$u"; assert_output 1
    run grep -cE 'PrivateTmp|ProtectHome' "$REPO_ROOT/systemd/$u"; assert_output 0
  done
  run grep -c 'CPUQuota=10%' "$REPO_ROOT/systemd/screenlog.service"; assert_output 1
  run grep -c 'MemoryMax=256M' "$REPO_ROOT/systemd/screenlog.service"; assert_output 1
  run grep -c 'Restart=always' "$REPO_ROOT/systemd/screenlog.service"; assert_output 1
  run grep -c 'CPUQuota=50%' "$REPO_ROOT/systemd/screenlog-report.service"; assert_output 1
  run grep -c 'TimeoutStartSec=30min' "$REPO_ROOT/systemd/screenlog-report.service"; assert_output 1
  run grep -c 'MAGICK_MEMORY_LIMIT=192MiB' "$REPO_ROOT/systemd/screenlog-report.service"; assert_output 1
  run grep -c 'RandomizedDelaySec=120' "$REPO_ROOT/systemd/screenlog-report.timer.in"; assert_output 1
  run grep -c 'Persistent=true' "$REPO_ROOT/systemd/screenlog-report.timer.in"; assert_output 1
}
