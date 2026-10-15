# shellcheck shell=bash
# lib/session.sh - find the logged-in X11 session, its lock state, DISPLAY/XAUTHORITY and idle time
# (spec section 5.3 steps 1-4). Runs as root. Results land in SESSION_* globals.
# shellcheck disable=SC2034  # SESSION_* are consumed by sample.sh and the CLI
if [[ -n ${_SCREENLOG_SESSION_SH:-} ]]; then return 0; fi
_SCREENLOG_SESSION_SH=1

SESSION_ID=""; SESSION_UID=""; SESSION_USER=""; SESSION_TYPE=""; SESSION_SCOPE=""; SESSION_STATUS=""
SESSION_DISPLAY=""; SESSION_XAUTHORITY=""; SESSION_IDLE_MS=""
SESSION_LOCK_WARNED=""
XENV=()

session_reset() {
  SESSION_ID=""; SESSION_UID=""; SESSION_USER=""; SESSION_TYPE=""; SESSION_SCOPE=""; SESSION_STATUS=""
  SESSION_DISPLAY=""; SESSION_XAUTHORITY=""; SESSION_IDLE_MS=""
}

# session_find: the active, local, Class=user session on seat0. Return 0 when it is X11;
# otherwise 1 with SESSION_STATUS=no_session|unsupported_session.
session_find() {
  session_reset
  local -a ids=()
  local id props k v seat remote class state type user name scope found=0
  mapfile -t ids < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
  for id in "${ids[@]}"; do
    [[ -n $id ]] || continue
    props=$(loginctl show-session "$id" -p Seat -p Remote -p Class -p State -p Type -p User -p Name -p Scope 2>/dev/null) || continue
    seat=""; remote=""; class=""; state=""; type=""; user=""; name=""; scope=""
    while IFS='=' read -r k v; do
      case $k in
        Seat) seat=$v ;;
        Remote) remote=$v ;;
        Class) class=$v ;;
        State) state=$v ;;
        Type) type=$v ;;
        User) user=$v ;;
        Name) name=$v ;;
        Scope) scope=$v ;;
      esac
    done <<< "$props"
    if [[ $seat == seat0 && $remote == no && $class == user && $state == active ]]; then
      SESSION_ID=$id; SESSION_UID=$user; SESSION_USER=$name; SESSION_TYPE=$type; SESSION_SCOPE=$scope
      found=1
      break
    fi
  done
  if (( ! found )); then
    SESSION_STATUS=no_session
    return 1
  fi
  if [[ $SESSION_TYPE != x11 ]]; then
    SESSION_STATUS=unsupported_session
    return 1
  fi
  SESSION_STATUS=ok
  return 0
}

# session_screensaver_active DEST: ask the user's session bus; prints "(true,)" or "(false,)".
# Runs as the user with runuser (never sudo, never runuser -l). ScreenShield is gnome-shell's own
# name for the org.gnome.ScreenSaver interface; org.gnome.ScreenSaver is a bus-activated proxy.
session_screensaver_active() {
  timeout 5 runuser -u "$SESSION_USER" -- \
    env "DBUS_SESSION_BUS_ADDRESS=unix:path=$PATH_RUN_USER/$SESSION_UID/bus" \
    gdbus call --session --dest "$1" --object-path /org/gnome/ScreenSaver \
    --method org.gnome.ScreenSaver.GetActive 2>/dev/null
}

# session_is_locked: 0 locked, 1 unlocked, 2 unknown.
session_is_locked() {
  local hint out
  hint=$(loginctl show-session "$SESSION_ID" -p LockedHint --value 2>/dev/null) || hint=""
  case $hint in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  out=$(session_screensaver_active org.gnome.Shell.ScreenShield) \
    || out=$(session_screensaver_active org.gnome.ScreenSaver) \
    || return 2
  case $out in
    *true*) return 0 ;;
    *false*) return 1 ;;
  esac
  return 2
}

# session_xenv DISPLAY [XAUTHORITY]: the environment for X clients. An empty XAUTHORITY is never
# exported (libXau would treat "" as a file name instead of falling back).
session_xenv() {
  XENV=("DISPLAY=$1")
  if [[ -n ${2:-} ]]; then
    XENV+=("XAUTHORITY=$2")
  fi
}

# session_xenv_ok DISPLAY XAUTHORITY: true when xprintidle works with this pair; keeps its answer
# in SESSION_IDLE_MS so the sample needs no second call.
session_xenv_ok() {
  local ms
  session_xenv "$1" "$2"
  ms=$(env "${XENV[@]}" timeout 5 xprintidle 2>/dev/null) || return 1
  [[ $ms =~ ^[0-9]+$ ]] || return 1
  SESSION_IDLE_MS=$ms
}

# session_idle_seconds: idle time of the resolved display, in whole seconds.
session_idle_seconds() {
  if [[ -z $SESSION_IDLE_MS ]]; then
    session_xenv "$SESSION_DISPLAY" "$SESSION_XAUTHORITY"
    SESSION_IDLE_MS=$(env "${XENV[@]}" timeout 5 xprintidle 2>/dev/null) || { SESSION_IDLE_MS=""; return 1; }
    if [[ ! $SESSION_IDLE_MS =~ ^[0-9]+$ ]]; then
      SESSION_IDLE_MS=""
      return 1
    fi
  fi
  printf '%s\n' $(( SESSION_IDLE_MS / 1000 ))
}

session_env_from_pid() {
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -E '^(DISPLAY|XAUTHORITY)=' || true
}

# session_pids: processes of the session (SCREENLOG_SESSION_PIDS overrides the cgroup scan).
session_pids() {
  local f
  if [[ -n ${SCREENLOG_SESSION_PIDS:-} ]]; then
    tr ' ' '\n' <<< "$SCREENLOG_SESSION_PIDS"
    return 0
  fi
  f="/sys/fs/cgroup/user.slice/user-$SESSION_UID.slice/$SESSION_SCOPE/cgroup.procs"
  if [[ -n $SESSION_SCOPE && -r $f ]]; then
    cat "$f"
  else
    pgrep -u "$SESSION_UID" 2>/dev/null || true
  fi
}

session_home() {
  getent passwd "$SESSION_UID" 2>/dev/null | cut -d: -f6 || true
}

session_cache_write() {
  local cache="$STATE_DIR/session-cache"
  mkdir -p -- "$STATE_DIR" || return 0
  printf '%s\n%s\n%s\n' "$SESSION_ID" "$1" "$2" > "$cache.tmp" && mv -f -- "$cache.tmp" "$cache"
}

# session_resolve_display: set SESSION_DISPLAY / SESSION_XAUTHORITY. Order (spec 5.3.3): the
# cached pair for this session id; gnome-shell's environ (pgrep by uid: on 24.04 it is a user
# unit, not in the session scope); any session process with DISPLAY; the GDM cookie with each
# X socket. Every candidate is confirmed with xprintidle. SCREENLOG_DISPLAY skips all of it.
session_resolve_display() {
  local cache="$STATE_DIR/session-cache" sid d x pid line cand home sock
  local -a pids=()
  SESSION_DISPLAY=""; SESSION_XAUTHORITY=""
  if [[ -n ${SCREENLOG_DISPLAY:-} ]]; then
    SESSION_DISPLAY=$SCREENLOG_DISPLAY
    SESSION_XAUTHORITY=${SCREENLOG_XAUTHORITY:-}
    return 0
  fi
  if [[ -r $cache ]]; then
    sid=""; d=""; x=""
    { read -r sid; read -r d; read -r x; } < "$cache"
    if [[ $sid == "$SESSION_ID" && -n $d ]] && session_xenv_ok "$d" "$x"; then
      SESSION_DISPLAY=$d; SESSION_XAUTHORITY=$x
      return 0
    fi
    rm -f -- "$cache"
  fi
  mapfile -t pids < <(pgrep -u "$SESSION_UID" -x gnome-shell 2>/dev/null)
  mapfile -t -O "${#pids[@]}" pids < <(session_pids)
  home=$(session_home)
  for pid in "${pids[@]}"; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    d=""; x=""
    while IFS= read -r line; do
      case $line in
        DISPLAY=*) d=${line#DISPLAY=} ;;
        XAUTHORITY=*) x=${line#XAUTHORITY=} ;;
      esac
    done < <(session_env_from_pid "$pid")
    [[ -n $d ]] || continue
    # candidates: the process's own XAUTHORITY (or none, when it had none), the GDM cookie, ~/.Xauthority
    for cand in "$x" "$PATH_RUN_USER/$SESSION_UID/gdm/Xauthority" "${home:+$home/.Xauthority}"; do
      if [[ -n $cand && ! -r $cand ]]; then continue; fi
      if [[ -z $cand && -n $x ]]; then continue; fi
      if session_xenv_ok "$d" "$cand"; then
        SESSION_DISPLAY=$d; SESSION_XAUTHORITY=$cand
        session_cache_write "$d" "$cand"
        return 0
      fi
    done
  done
  x="$PATH_RUN_USER/$SESSION_UID/gdm/Xauthority"
  if [[ -r $x ]]; then
    for sock in "$PATH_X11_SOCKETS"/X*; do
      [[ -e $sock ]] || continue
      d=":${sock##*/X}"
      if session_xenv_ok "$d" "$x"; then
        SESSION_DISPLAY=$d; SESSION_XAUTHORITY=$x
        session_cache_write "$d" "$x"
        return 0
      fi
    done
  fi
  return 1
}
