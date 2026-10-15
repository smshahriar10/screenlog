# shellcheck shell=bash
# lib/drive.sh - the one place rclone is run (spec section 5.5). Every call is serialised with
# flock on state/rclone.lock (Drive allows duplicate file names, so the daemon and the report must
# never upload concurrently) and bounded by timeout. Output goes to files, never to $( ).
# shellcheck disable=SC2034  # DRIVE_* are read by upload.sh, report.sh and the CLI
# shellcheck disable=SC2153  # DRIVE_ROOT is a config key, not a misspelling of DRIVE_OUT
if [[ -n ${_SCREENLOG_DRIVE_SH:-} ]]; then return 0; fi
_SCREENLOG_DRIVE_SH=1

DRIVE_LAST_ERR=""
DRIVE_OUT=""
DRIVE_OFFLINE=0
DRIVE_FOLDER_ID=""
DRIVE_FOLDER_URL=""

drive_remote_root()     { printf '%s:%s\n' "$RCLONE_REMOTE" "$DRIVE_ROOT"; }
drive_remote_employee() { printf '%s:%s/%s\n' "$RCLONE_REMOTE" "$DRIVE_ROOT" "$EMPLOYEE_SLUG"; }
drive_remote_day()      { printf '%s:%s/%s/%s\n' "$RCLONE_REMOTE" "$DRIVE_ROOT" "$EMPLOYEE_SLUG" "$1"; }

# drive_rclone ARGS...: run rclone with the shared flags; later flags in ARGS override them.
# Returns rclone's exit code; 75 when the lock stayed busy for SCREENLOG_LOCK_WAIT seconds
# (daemon: 5, report and CLI: 900); 124 on timeout. Stdout is in the file $DRIVE_OUT.
drive_rclone() {
  local errf rc lock
  DRIVE_LAST_ERR=""
  DRIVE_OUT="${SCREENLOG_TMP:-/tmp}/rclone.out"
  errf="${SCREENLOG_TMP:-/tmp}/rclone.err"
  if (( DRIVE_OFFLINE )); then
    DRIVE_LAST_ERR="Drive unreachable (probe failed this run)"
    return 1
  fi
  lock="$STATE_DIR/rclone.lock"
  mkdir -p -- "$STATE_DIR" || { DRIVE_LAST_ERR="cannot create $STATE_DIR"; return 1; }
  exec 9>> "$lock" || { DRIVE_LAST_ERR="cannot open $lock"; return 1; }
  if ! run_child flock -w "${SCREENLOG_LOCK_WAIT:-900}" 9; then
    exec 9>&-
    DRIVE_LAST_ERR="rclone lock busy"
    return 75
  fi
  if run_child timeout -k 10 "${SCREENLOG_RCLONE_TIMEOUT:-1200}" \
      rclone --config "$SCREENLOG_RCLONE_CONF" --contimeout 30s --timeout 120s \
      --retries 2 --low-level-retries 3 --stats 0 "$@" > "$DRIVE_OUT" 2> "$errf"; then
    rc=0
  else
    rc=$?
  fi
  exec 9>&-
  DRIVE_LAST_ERR=$(tail -n1 "$errf" 2>/dev/null | log_redact)
  DRIVE_LAST_ERR=${DRIVE_LAST_ERR:0:200}
  if (( rc == 124 || rc == 137 )); then
    DRIVE_LAST_ERR="rclone timeout"
  fi
  return "$rc"
}

# drive_check: is Drive reachable and DRIVE_ROOT present? (one attempt)
drive_check() {
  drive_rclone lsd "$(drive_remote_root)" --retries 1
}

drive_mkdir_employee() {
  drive_rclone mkdir "$(drive_remote_employee)"
}

# drive_probe: once per report run; afterwards every call fails fast while Drive is unreachable.
drive_probe() {
  DRIVE_OFFLINE=0
  if ! drive_check; then
    DRIVE_OFFLINE=1
    log_warn "drive: unreachable ($DRIVE_LAST_ERR)"
    return 1
  fi
}

# drive_folder_id DAY: the Drive ID of the day's folder -> DRIVE_FOLDER_ID / DRIVE_FOLDER_URL.
# Never `rclone link`: the owner opens the folder with their own account (spec 5.4 step 4).
drive_folder_id() {
  DRIVE_FOLDER_ID=""
  DRIVE_FOLDER_URL=""
  drive_rclone lsjson --dirs-only --no-mimetype --no-modtime "$(drive_remote_employee)" || return 1
  DRIVE_FOLDER_ID=$(jq -r --arg d "$1" '.[] | select(.IsDir and .Name == $d) | .ID' "$DRIVE_OUT" 2>/dev/null | head -n1)
  if [[ -z $DRIVE_FOLDER_ID || $DRIVE_FOLDER_ID == null ]]; then
    DRIVE_FOLDER_ID=""
    DRIVE_LAST_ERR="folder $1 not found in Drive listing"
    return 1
  fi
  DRIVE_FOLDER_URL="https://drive.google.com/drive/folders/$DRIVE_FOLDER_ID"
}
