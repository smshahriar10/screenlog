#!/usr/bin/env bats
# make bundle: the folder and tarball the owner copies to each PC.
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() { screenlog_test_setup; }

@test "bundle: the tarball holds exactly what install.sh needs and no secrets" {
  run make -C "$REPO_ROOT" bundle DIST="$BATS_TEST_TMPDIR/dist"
  assert_success
  local tgz
  tgz="$BATS_TEST_TMPDIR/dist/screenlog-1.0.0.tar.gz"
  assert_file_exists "$tgz"
  run tar -tzf "$tgz"
  local f
  for f in install.sh uninstall.sh VERSION README.md CHANGELOG.md bin/screenlogd bin/screenlog lib/config.sh \
           systemd/screenlog.service systemd/screenlog-report.service systemd/screenlog-report.timer.in \
           config/screenlog.conf.example vendor/; do
    assert_line "screenlog-1.0.0/$f"
  done
  refute_output --partial "tests/"
  refute_output --partial ".git"
  refute_output --partial "config/screenlog.conf"$'\n'
  refute_output --regexp 'config/(screenlog|rclone)\.conf$'
  refute_output --partial "Makefile"
  refute_output --partial "._"
  refute_output --partial ".DS_Store"
  run tar -tvzf "$tgz"
  run awk '$2 != "root/root" && $2 != "0/0" { print }' <<< "$output"
  assert_output ""
  run tar -tvzf "$tgz"
  assert_line --regexp '^-rwxr-xr-x (root/root|0/0) .* screenlog-1.0.0/install.sh$'
  assert_line --regexp '^-rwxr-xr-x (root/root|0/0) .* screenlog-1.0.0/bin/screenlogd$'
  assert_line --regexp '^-rw-r--r-- (root/root|0/0) .* screenlog-1.0.0/lib/config.sh$'
}
