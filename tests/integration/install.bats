#!/usr/bin/env bats
# install.sh / uninstall.sh for real against a fake system root (container only).
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup_file() {
  [ "${SCREENLOG_IN_DOCKER:-}" = 1 ] || return 0
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  make -C "$REPO_ROOT" bundle DIST="$BATS_FILE_TMPDIR/dist" > /dev/null
  tar -xzf "$BATS_FILE_TMPDIR/dist/screenlog-$(cat "$REPO_ROOT/VERSION").tar.gz" -C "$BATS_FILE_TMPDIR"
}

setup() {
  [ "${SCREENLOG_IN_DOCKER:-}" = 1 ] || skip "runs only in the throwaway container"
  screenlog_test_setup
  unset SCREENLOG_CONFIG SCREENLOG_RCLONE_CONF SCREENLOG_DATA_DIR   # everything derives from SYSROOT
  export SCREENLOG_ARCH=amd64 SCREENLOG_INSTALL_SETTLE=0 SCREENLOG_REBOOT_COUNTDOWN=0
  mkdir -p "$SCREENLOG_SYSROOT/etc/gdm3" "$SCREENLOG_SYSROOT/etc/update-manager" "$SCREENLOG_SYSROOT/usr/local/bin" "$SCREENLOG_SYSROOT/opt"
  cp "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf"
  cp "$REPO_ROOT/tests/fixtures/release-upgrades" "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades"
  cp /etc/os-release "$SCREENLOG_SYSROOT/etc/os-release"
  use_stubs apt-get dpkg dpkg-query systemctl curl rclone hostname loginctl runuser gdbus xprintidle ffmpeg
  BUNDLE="$BATS_TEST_TMPDIR/bundle"
  cp -R "$BATS_FILE_TMPDIR/screenlog-$(cat "$REPO_ROOT/VERSION")" "$BUNDLE"
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$REPO_ROOT/tests/fixtures/rclone.conf" "$BUNDLE/config/"
  sed -i '/^EMPLOYEE_/d' "$BUNDLE/config/screenlog.conf"
  ETC="$SCREENLOG_SYSROOT/etc/screenlog"
  DATA="$SCREENLOG_SYSROOT/var/lib/screenlog"
}

@test "install: a fresh install sets up files, config, system edits and units, printing no secret" {
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  refute_secrets
  assert_output --partial "mode: first-install -> 1.0.0"
  assert_output --partial "screenlog 1.0.0 - first install"
  assert_output --partial "employee   Rahim Uddin (slug rahim-uddin)"
  assert_output --partial "Next step: reboot, log in, and a ✅ message will appear in Discord within about a minute."
  assert_file_exists "$SCREENLOG_SYSROOT/opt/screenlog/VERSION"
  assert_file_exists "$SCREENLOG_SYSROOT/opt/screenlog/uninstall.sh"
  assert_file_not_exists "$SCREENLOG_SYSROOT/opt/screenlog/config/screenlog.conf"
  assert_file_not_exists "$SCREENLOG_SYSROOT/opt/screenlog/config/rclone.conf"
  assert_symlink_to "$SCREENLOG_SYSROOT/opt/screenlog/bin/screenlog" "$SCREENLOG_SYSROOT/usr/local/bin/screenlog"
  run "$SCREENLOG_SYSROOT/usr/local/bin/screenlog" version
  assert_output "1.0.0"
  assert_file_permission 700 "$ETC"
  assert_file_permission 600 "$ETC/screenlog.conf"
  assert_file_permission 600 "$ETC/rclone.conf"
  assert_file_permission 700 "$DATA"
  assert_dir_exists "$DATA/shots"
  assert_dir_exists "$DATA/state/uploaded"
  assert_dir_exists "$DATA/tmp"
  run grep -c '^EMPLOYEE_NAME="Rahim Uddin"$' "$ETC/screenlog.conf"; assert_output 1
  run grep -c '^EMPLOYEE_SLUG="rahim-uddin"$' "$ETC/screenlog.conf"; assert_output 1
  run grep -c '^REPORT_TIME="17:30"$' "$ETC/screenlog.conf"; assert_output 1
  run awk '/^\[daemon\]/ { s = 1; next } /^\[/ { s = 0 } s && /^WaylandEnable=false$/ { f++ } END { print f + 0 }' "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf"
  assert_output 1
  run diff "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf.screenlog-bak"; assert_success
  run grep -c '^Prompt=never$' "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades"; assert_output 1
  run diff "$REPO_ROOT/tests/fixtures/release-upgrades" "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades.screenlog-bak"; assert_success
  run grep -c 'OnCalendar=\*-\*-\* 17:30:00$' "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"; assert_output 1
  run grep -c '@REPORT_TIME@' "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"; assert_output 0
  run cat "$STUB_LOG_DIR/systemctl.log"
  assert_line --regexp 'systemctl daemon-reload $'
  assert_line --regexp 'systemctl enable --now screenlog.service screenlog-report.timer $'
  run cat "$STUB_LOG_DIR/apt-get.log"
  assert_line --regexp 'apt-get update -q $'
  assert_line --regexp 'apt-get install -y ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core rclone jq libglib2.0-bin $'
  run grep -c -- '-X GET' "$STUB_LOG_DIR/curl.log"; assert_output 1
  run grep -c ' lsd ' "$STUB_LOG_DIR/rclone.log"; (( output >= 1 ))
  run grep -c ' mkdir screenlog-gdrive:Screenlog/rahim-uddin' "$STUB_LOG_DIR/rclone.log"; assert_output 1
  run cat "$DATA/state/install-history"
  assert_output --partial "mode=first-install name=Rahim Uddin slug=rahim-uddin"
}

@test "install: re-running upgrades in place, keeps name, slug and state, resets shared keys loudly" {
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  mkdir -p "$DATA/state"
  printf '2026-10-14\n' > "$DATA/state/reported-days"
  printf 'SHOTS_PER_HOUR=8\n' >> "$BUNDLE/config/screenlog.conf"
  sed -i 's/^SHOTS_PER_HOUR=7$//' "$BUNDLE/config/screenlog.conf"
  run "$BUNDLE/install.sh"
  assert_success
  assert_output --partial "mode: upgrade (installed: 1.0.0) -> 1.0.0"
  assert_output --partial "screenlog 1.0.0 - reinstalled"
  assert_output --partial "Shared keys reset from the bundle"
  assert_output --partial "SHOTS_PER_HOUR: 7 -> 8"
  assert_output --partial "rclone.conf kept (its refreshed token still works)"
  run grep -c '^EMPLOYEE_NAME="Rahim Uddin"$' "$ETC/screenlog.conf"; assert_output 1
  run grep -c '^SHOTS_PER_HOUR="8"$' "$ETC/screenlog.conf"; assert_output 1
  run cat "$DATA/state/reported-days"; assert_output "2026-10-14"
  run find "$SCREENLOG_SYSROOT/etc" -name '*.screenlog-bak'
  assert_equal "${#lines[@]}" 2
  run diff "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf.screenlog-bak"; assert_success
  refute_secrets
  run "$BUNDLE/install.sh" --name "Other Name"
  assert_success
  assert_output --partial "slug changes from rahim-uddin to other-name"
  run grep -c '^EMPLOYEE_NAME="Other Name"$' "$ETC/screenlog.conf"; assert_output 1
  run grep -c '^EMPLOYEE_SLUG="other-name"$' "$ETC/screenlog.conf"; assert_output 1
}

@test "install: refusals and --force" {
  cp "$REPO_ROOT/tests/fixtures/os-release-22.04" "$SCREENLOG_SYSROOT/etc/os-release"
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 6
  assert_output --partial "only Ubuntu 24.04 LTS is supported (found: Ubuntu 22.04.4 LTS)"
  assert_equal "$(stub_calls apt-get)" 0
  run "$BUNDLE/install.sh" --name "Rahim Uddin" --force
  assert_success
  assert_output --partial "unsupported OS (Ubuntu 22.04.4 LTS); continuing because of --force"
  cp /etc/os-release "$SCREENLOG_SYSROOT/etc/os-release"
  SCREENLOG_ARCH=arm64 run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 6
  assert_output --partial "only amd64 PCs are supported (found: arm64)"
  SCREENLOG_ARCH=arm64 run "$BUNDLE/install.sh" --name "Rahim Uddin" --force
  assert_success
  run setpriv --reuid=65534 --regid=65534 --clear-groups "$REPO_ROOT/install.sh" --name x
  assert_failure 4
  assert_output --partial "must run as root"
  rm -rf "$ETC"
  run "$BUNDLE/install.sh"
  assert_failure 2
  assert_output --partial '--name "<display name>" is required on the first install'
  run "$BUNDLE/install.sh" --name "রহিম উদ্দিন"
  assert_failure 2
  assert_output --partial "pass --slug"
  run "$BUNDLE/install.sh" --name "রহিম উদ্দিন" --slug rahim
  assert_success
  run grep -c '^EMPLOYEE_SLUG="rahim"$' "$ETC/screenlog.conf"; assert_output 1
  run "$BUNDLE/install.sh" --name x --slug "Bad Slug"
  assert_failure 2
  run "$BUNDLE/install.sh" --name x --bogus
  assert_failure 2
}

@test "install: preflight catches a bad bundle config, no internet, a dead webhook, Drive problems" {
  printf 'GAP_ALERT_MINUTES=30\n' >> "$BUNDLE/config/screenlog.conf"
  sed -i 's/^GAP_ALERT_MINUTES=45$//' "$BUNDLE/config/screenlog.conf"
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 3
  assert_output --partial "GAP_ALERT_MINUTES: must be greater than MAX_GAP_SECONDS/60"
  assert_equal "$(stub_calls apt-get)" 0
  cp "$REPO_ROOT/tests/fixtures/screenlog.conf" "$BUNDLE/config/screenlog.conf"
  stub_reset curl
  STUB_CURL_PLAN=7 run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 6
  assert_output --partial "no internet access to discord.com"
  stub_reset curl
  STUB_CURL_PLAN="200 200 404" run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 7
  assert_output --partial "Discord webhook rejected (HTTP 404)"
  refute_secrets
  STUB_RCLONE_FAIL=lsd run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 7
  assert_output --partial "Drive check failed"
  assert_output --partial "screenlog.service was started again after this failed install"
  run tail -n1 "$STUB_LOG_DIR/systemctl.log"
  assert_output --regexp 'systemctl start screenlog.service $'
  run cat "$STUB_LOG_DIR/systemctl.log"
  assert_line --regexp 'systemctl stop screenlog.service $'
  rm -rf "$STUB_REMOTE_DIR/Screenlog"
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 7
  assert_output --partial "Drive folder 'Screenlog' does not exist; create it on the Mac: rclone mkdir screenlog-gdrive:Screenlog"
  mkdir -p "$STUB_REMOTE_DIR/Screenlog"
  STUB_RCLONE_VERSION=v1.53.3 STUB_DPKG_INSTALLED=all run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 6
  assert_output --partial "rclone 1.53.3 is too old"
  rm -rf "$ETC"   # back to a first install: there the bundle must carry rclone.conf
  rm -f "$BUNDLE/config/rclone.conf"
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_failure 3
  assert_output --partial "config/rclone.conf is missing from the bundle"
}

@test "install: --dry-run changes nothing and still runs the read-only checks" {
  find "$SCREENLOG_SYSROOT" -printf '%p %s\n' | sort > "$BATS_TEST_TMPDIR/before"
  run "$BUNDLE/install.sh" --name "Rahim Uddin" --dry-run
  assert_success
  assert_output --partial "[dry-run] every step is printed; nothing is changed"
  assert_output --partial "would run: apt-get install -y"
  assert_output --partial "would write $ETC/screenlog.conf (mode 600)"
  assert_output --partial "would change $SCREENLOG_SYSROOT/etc/gdm3/custom.conf:"
  assert_output --partial "+WaylandEnable=false"
  assert_output --partial "would run: systemctl enable --now screenlog.service screenlog-report.timer"
  assert_output --partial "[dry-run] nothing was changed."
  refute_secrets
  find "$SCREENLOG_SYSROOT" -printf '%p %s\n' | sort > "$BATS_TEST_TMPDIR/after"
  run diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  assert_success
  run grep -c ' mkdir ' "$STUB_LOG_DIR/rclone.log"; assert_output 0
  run grep -c -- '-X GET' "$STUB_LOG_DIR/curl.log"; assert_output 1
  stub_reset curl
  STUB_CURL_PLAN="200 200 404" run "$BUNDLE/install.sh" --name "Rahim Uddin" --dry-run
  assert_failure 7
}

@test "install: --dry-run on a fresh PC without rclone, jq or curl defers the remote checks and exits 0" {
  local fakebin="$BATS_TEST_TMPDIR/fakebin" f
  mkdir -p "$fakebin"
  for f in /usr/bin/* /bin/*; do [ -x "$f" ] && ln -sf "$f" "$fakebin/${f##*/}"; done
  rm -f "$fakebin/rclone" "$fakebin/jq" "$fakebin/curl" "$SCREENLOG_TEST_BASE/bin/rclone" "$SCREENLOG_TEST_BASE/bin/curl"
  PATH="$SCREENLOG_TEST_BASE/bin:$fakebin" run "$BUNDLE/install.sh" --name "Rahim Uddin" --dry-run
  assert_success
  assert_output --partial "curl not found; internet check skipped"
  assert_output --partial "would run: apt-get install -y"
  assert_output --partial "rclone not installed yet; its version is checked on the real run"
  assert_output --partial "would check Drive (screenlog-gdrive:Screenlog"
  assert_output --partial "[dry-run] nothing was changed."
  assert_output --regexp 'xorg +WaylandEnable=false in [^ ]+ \(set now; backup'
  run grep -c '^  would change ' <<< "$output"
  assert_output 2
}

@test "install: a vendor rclone .deb is verified and installed instead of the apt package" {
  mkdir -p "$BUNDLE/vendor"
  printf 'not really a deb' > "$BUNDLE/vendor/rclone-v1.75.2-linux-amd64.deb"
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  assert_output --partial "vendor/SHA256SUMS missing: rclone-v1.75.2-linux-amd64.deb is installed unverified"
  run cat "$STUB_LOG_DIR/apt-get.log"
  assert_line --regexp 'apt-get install -y ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core jq libglib2.0-bin $'
  assert_line --regexp "apt-get install -y $BUNDLE/vendor/rclone-v1.75.2-linux-amd64.deb"
  (cd "$BUNDLE/vendor" && sha256sum rclone-v1.75.2-linux-amd64.deb > SHA256SUMS)
  run "$BUNDLE/install.sh"
  assert_success
  assert_output --partial "vendor rclone: rclone-v1.75.2-linux-amd64.deb (checksum verified)"
  printf 'deadbeef  rclone-v1.75.2-linux-amd64.deb\n' > "$BUNDLE/vendor/SHA256SUMS"
  run "$BUNDLE/install.sh"
  assert_failure 6
  assert_output --partial "checksum mismatch"
}

@test "install: --reannounce clears the flag and --reboot reboots after the countdown" {
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  mkdir -p "$DATA/state"
  : > "$DATA/state/setup-announced"
  run "$BUNDLE/install.sh" --reannounce
  assert_success
  assert_file_not_exists "$DATA/state/setup-announced"
  run "$BUNDLE/install.sh" --reboot
  assert_success
  run tail -n1 "$STUB_LOG_DIR/systemctl.log"
  assert_output --regexp 'systemctl reboot $'
}

@test "uninstall: reverses the install, keeps data unless --purge, never touches Drive" {
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  stub_reset rclone
  run "$SCREENLOG_SYSROOT/opt/screenlog/uninstall.sh"
  assert_success
  assert_output --partial "removed $SCREENLOG_SYSROOT/etc/systemd/system/screenlog.service"
  assert_output --partial "removed $SCREENLOG_SYSROOT/usr/local/bin/screenlog"
  assert_output --partial "removed $SCREENLOG_SYSROOT/opt/screenlog"
  assert_output --partial "restored $SCREENLOG_SYSROOT/etc/gdm3/custom.conf"
  assert_output --partial "kept $ETC and $DATA (add --purge to remove them)"
  assert_output --partial "Nothing in Google Drive was touched"
  assert_file_not_exists "$SCREENLOG_SYSROOT/etc/systemd/system/screenlog-report.timer"
  assert_file_not_exists "$SCREENLOG_SYSROOT/usr/local/bin/screenlog"
  assert_dir_not_exists "$SCREENLOG_SYSROOT/opt/screenlog"
  run diff "$REPO_ROOT/tests/fixtures/gdm-custom.conf" "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf"; assert_success
  run diff "$REPO_ROOT/tests/fixtures/release-upgrades" "$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades"; assert_success
  assert_file_not_exists "$SCREENLOG_SYSROOT/etc/gdm3/custom.conf.screenlog-bak"
  assert_dir_exists "$ETC"
  assert_dir_exists "$DATA"
  assert_equal "$(stub_calls rclone)" 0
  run cat "$STUB_LOG_DIR/systemctl.log"
  assert_line --regexp 'systemctl disable --now screenlog-report.timer screenlog.service $'
  assert_line --regexp 'systemctl daemon-reload $'
  run "$BUNDLE/install.sh" --name "Rahim Uddin"
  assert_success
  run "$SCREENLOG_SYSROOT/opt/screenlog/uninstall.sh" --dry-run
  assert_success
  assert_output --partial "would: rm -rf -- $SCREENLOG_SYSROOT/opt/screenlog"
  assert_dir_exists "$SCREENLOG_SYSROOT/opt/screenlog"
  run "$SCREENLOG_SYSROOT/opt/screenlog/uninstall.sh" --purge
  assert_success
  assert_dir_not_exists "$ETC"
  assert_dir_not_exists "$DATA"
  run setpriv --reuid=65534 --regid=65534 --clear-groups "$REPO_ROOT/uninstall.sh"
  assert_failure 4
}
