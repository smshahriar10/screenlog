#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() {
  screenlog_test_setup
  config_load
  use_stubs loginctl runuser gdbus xprintidle hostname
  BG_PIDS=()
}

teardown() {
  local p
  for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  return 0
}

# spawn_with_env VAR=VALUE... : a sleeping process carrying exactly that environment (real /proc)
spawn_with_env() {
  env -i "$@" sleep 60 </dev/null >/dev/null 2>&1 3>&- &
  BG_PIDS+=("$!")
  printf '%s\n' "$!"
}

@test "session: the active local x11 session on seat0 is found, greeter and remote sessions are skipped" {
  session_find
  assert_equal "$SESSION_STATUS" ok
  assert_equal "$SESSION_ID" 3
  assert_equal "$SESSION_UID" 1000
  assert_equal "$SESSION_USER" rahim
  assert_equal "$SESSION_TYPE" x11
  assert_equal "$SESSION_SCOPE" session-3.scope
}

@test "session: statuses for no session, only a greeter, only a remote session, an inactive session" {
  local sc
  for sc in none greeter remote inactive; do
    STUB_LOGINCTL_SCENARIO=$sc run session_find
    assert_failure
    STUB_LOGINCTL_SCENARIO=$sc session_find || true
    assert_equal "$SESSION_STATUS" no_session
  done
}

@test "session: a Wayland session is unsupported" {
  STUB_LOGINCTL_SCENARIO=wayland session_find || true
  assert_equal "$SESSION_STATUS" unsupported_session
  assert_equal "$SESSION_ID" 3
}

@test "session: LockedHint yes/no decides the lock state" {
  session_find
  run session_is_locked
  assert_failure 1
  STUB_LOGINCTL_SCENARIO=locked run session_is_locked
  assert_success
  assert_equal "$(stub_calls gdbus)" 0
}

@test "session: without LockedHint the screensaver is asked over the user bus as the user, never sudo" {
  export STUB_LOGINCTL_SCENARIO=nolockedhint
  session_find
  STUB_SCREENSAVER_ACTIVE=true run session_is_locked
  assert_success
  STUB_SCREENSAVER_ACTIVE=false run session_is_locked
  assert_failure 1
  run stub_call runuser 1
  assert_output --partial "runuser -u rahim -- env DBUS_SESSION_BUS_ADDRESS=unix:path=$SCREENLOG_SYSROOT/run/user/1000/bus gdbus"
  refute_output --partial sudo
  run stub_call gdbus 1
  assert_output --partial "--dest org.gnome.Shell.ScreenShield"
  assert_output --partial "--method org.gnome.ScreenSaver.GetActive"
}

@test "session: the ScreenSaver proxy is the fallback when ScreenShield has no owner, unknown otherwise" {
  export STUB_LOGINCTL_SCENARIO=nolockedhint
  session_find
  STUB_GDBUS_FAIL_DEST="org.gnome.Shell.ScreenShield" STUB_SCREENSAVER_ACTIVE=true run session_is_locked
  assert_success
  assert_equal "$(stub_calls gdbus)" 2
  run stub_call gdbus 2
  assert_output --partial "--dest org.gnome.ScreenSaver "
  STUB_GDBUS_FAIL_DEST="org.gnome.Shell.ScreenShield org.gnome.ScreenSaver" run session_is_locked
  assert_failure 2
}

@test "session: DISPLAY and XAUTHORITY come from a session process's environment, confirmed by xprintidle" {
  local p1 p2
  p1=$(spawn_with_env HOME=/root)
  : > "$BATS_TEST_TMPDIR/xa"
  p2=$(spawn_with_env DISPLAY=:77 XAUTHORITY="$BATS_TEST_TMPDIR/xa")
  export SCREENLOG_SESSION_PIDS="$p1 $p2"
  session_find
  session_resolve_display
  assert_equal "$SESSION_DISPLAY" ":77"
  assert_equal "$SESSION_XAUTHORITY" "$BATS_TEST_TMPDIR/xa"
  assert_equal "$SESSION_IDLE_MS" 1500
  run cat "$SCREENLOG_DATA_DIR/state/session-cache"
  assert_output $'3\n:77\n'"$BATS_TEST_TMPDIR/xa"
}

@test "session: gnome-shell's environment wins over other session processes" {
  local p2 p3
  cp /bin/sleep "$BATS_TEST_TMPDIR/gnome-shell"
  p2=$(spawn_with_env DISPLAY=:77)
  env -i DISPLAY=:78 "$BATS_TEST_TMPDIR/gnome-shell" 60 </dev/null >/dev/null 2>&1 3>&- &
  p3=$!
  BG_PIDS+=("$p3")
  export SCREENLOG_SESSION_PIDS="$p2 $p3"
  session_find
  SESSION_UID=$(id -u)   # pgrep -u <our uid> -x gnome-shell finds the renamed sleep
  session_resolve_display
  assert_equal "$SESSION_DISPLAY" ":78"
}

@test "session: a candidate that fails the xprintidle probe is skipped" {
  local p1 p2
  p1=$(spawn_with_env DISPLAY=:78)
  p2=$(spawn_with_env DISPLAY=:77)
  export SCREENLOG_SESSION_PIDS="$p1 $p2"
  export STUB_XPRINTIDLE_FAIL_DISPLAY=:78
  session_find
  session_resolve_display
  assert_equal "$SESSION_DISPLAY" ":77"
}

@test "session: the GDM cookie with each X socket is the last resort" {
  local p1
  p1=$(spawn_with_env HOME=/root)
  export SCREENLOG_SESSION_PIDS="$p1"
  mkdir -p "$SCREENLOG_SYSROOT/run/user/1000/gdm"
  : > "$SCREENLOG_SYSROOT/run/user/1000/gdm/Xauthority"
  : > "$SCREENLOG_SYSROOT/tmp/.X11-unix/X1"
  export STUB_XPRINTIDLE_REQUIRE_XAUTH=1
  session_find
  session_resolve_display
  assert_equal "$SESSION_DISPLAY" ":1"
  assert_equal "$SESSION_XAUTHORITY" "$SCREENLOG_SYSROOT/run/user/1000/gdm/Xauthority"
}

@test "session: nothing works -> failure and no cache" {
  local p1
  p1=$(spawn_with_env HOME=/root)
  export SCREENLOG_SESSION_PIDS="$p1"
  session_find
  run session_resolve_display
  assert_failure
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/session-cache"
}

@test "session: the cache is reused, dropped on a new session id or a failing probe" {
  local p2 before
  p2=$(spawn_with_env DISPLAY=:77)
  export SCREENLOG_SESSION_PIDS="$p2"
  session_find
  session_resolve_display
  before=$(stub_calls xprintidle)
  session_find
  session_resolve_display
  assert_equal "$(stub_calls xprintidle)" $((before + 1))   # one probe: the cached pair
  assert_equal "$SESSION_DISPLAY" ":77"
  printf '9\n:77\n\n' > "$SCREENLOG_DATA_DIR/state/session-cache"   # another session id
  session_find
  session_resolve_display
  run cat "$SCREENLOG_DATA_DIR/state/session-cache"
  assert_line --index 0 "3"
  export STUB_XPRINTIDLE_EXIT=1
  session_find
  run session_resolve_display
  assert_failure
  assert_file_not_exists "$SCREENLOG_DATA_DIR/state/session-cache"
}

@test "session: an empty XAUTHORITY is never exported to X clients" {
  local p2
  p2=$(spawn_with_env DISPLAY=:77)
  export SCREENLOG_SESSION_PIDS="$p2"
  session_find
  session_resolve_display
  assert_equal "$SESSION_XAUTHORITY" ""
  run grep -c 'XAUTHORITY=<unset>' "$STUB_LOG_DIR/xprintidle.env"
  assert_output 1
  run session_idle_seconds
  assert_output 1
}

@test "session: SCREENLOG_DISPLAY bypasses session lookup and idle is reported in seconds" {
  export SCREENLOG_DISPLAY=:5 STUB_IDLE_MS=4321
  session_resolve_display
  assert_equal "$SESSION_DISPLAY" ":5"
  run session_idle_seconds
  assert_output 4
  assert_equal "$(stub_calls loginctl)" 0
}
