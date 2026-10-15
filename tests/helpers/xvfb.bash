# shellcheck shell=bash
# tests/helpers/xvfb.bash - a private Xvfb per test file for the integration suite.
# start_xvfb [GEOMETRY]: the server picks a free display number itself (-displayfd) and uses a
# real cookie file, so SCREENLOG_XAUTHORITY is genuinely exercised. Writes the environment to
# $BATS_FILE_TMPDIR/xvfb.env for load_xvfb_env.
start_xvfb() {
  local geom=${1:-1920x1200x24} dir=${BATS_FILE_TMPDIR:?} auth cookie n
  auth="$dir/Xauthority"
  : > "$auth"
  cookie=$(mcookie)
  # the server loads every record of -auth at start; one cookie per possible display number
  for n in $(seq 0 99); do printf 'add :%d . %s\n' "$n" "$cookie"; done | xauth -q -f "$auth" source -
  # </dev/null >log 2>&1 3>&-: bats waits for fd 3 to close; a child holding it hangs the run
  Xvfb -displayfd 4 -screen 0 "$geom" -auth "$auth" -nolisten tcp \
    4> "$dir/display" </dev/null > "$dir/xvfb.log" 2>&1 3>&- &
  echo $! > "$dir/xvfb.pid"
  for _ in $(seq 1 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
  [ -s "$dir/display" ] || { cat "$dir/xvfb.log" >&2; return 1; }
  n=$(tr -dc 0-9 < "$dir/display")
  for _ in $(seq 1 50); do DISPLAY=":$n" XAUTHORITY="$auth" xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
  DISPLAY=":$n" XAUTHORITY="$auth" xdpyinfo >/dev/null 2>&1 || { cat "$dir/xvfb.log" >&2; return 1; }
  printf 'export SCREENLOG_DISPLAY=:%s\nexport SCREENLOG_XAUTHORITY=%q\n' "$n" "$auth" > "$dir/xvfb.env"
  paint_root 42
}

stop_painter() {
  local f=${BATS_FILE_TMPDIR:?}/painter.pid
  if [ -f "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; fi
  return 0
}

stop_xvfb() {
  stop_painter
  kill "$(cat "${BATS_FILE_TMPDIR:?}/xvfb.pid" 2>/dev/null)" 2>/dev/null || true
}

load_xvfb_env() {
  # shellcheck disable=SC1091
  source "${BATS_FILE_TMPDIR:?}/xvfb.env"
}

# paint_root [SEED]: cover the screen with a high-entropy plasma image. A flat colour would encode
# to a few KB at any JPEG quality and defeat the size and quality tests. A root background does
# not survive its client under Xvfb (xsetroot never reaches x11grab, `display -window root` fades
# with its connection), so a full-screen ImageMagick `display` window stays alive per test file.
paint_root() {
  local dir=${BATS_FILE_TMPDIR:?} seed=${1:-42} img i
  img="$dir/root-$seed.png"
  [ -f "$img" ] || convert -seed "$seed" -size 1920x1200 plasma:fractal "$img"
  load_xvfb_env
  stop_painter
  DISPLAY=$SCREENLOG_DISPLAY XAUTHORITY=$SCREENLOG_XAUTHORITY display -geometry +0+0 -title screenlog-bg "$img" \
    </dev/null >/dev/null 2>&1 3>&- &
  echo $! > "$dir/painter.pid"
  for i in $(seq 1 50); do
    DISPLAY=$SCREENLOG_DISPLAY XAUTHORITY=$SCREENLOG_XAUTHORITY xwininfo -root -tree 2>/dev/null | grep -q screenlog-bg && break
    sleep 0.1
  done
  : "$i"
  sleep 0.3
}

# xprintidle_or_stub: spec 11 allows stubbing xprintidle only if it does not work under Xvfb.
xprintidle_or_stub() {
  if ! DISPLAY=$SCREENLOG_DISPLAY XAUTHORITY=$SCREENLOG_XAUTHORITY timeout 5 xprintidle >/dev/null 2>&1; then
    use_stubs xprintidle
    export STUB_IDLE_MS=1500
    echo "# xprintidle unusable under Xvfb -> stubbed" >&3
  fi
}
