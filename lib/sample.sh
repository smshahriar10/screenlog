# shellcheck shell=bash
# lib/sample.sh - one sample: session -> lock -> display -> idle -> capture -> CSV row.
# shellcheck disable=SC2034  # SAMPLE_* are read by the daemon and the CLI
if [[ -n ${_SCREENLOG_SAMPLE_SH:-} ]]; then return 0; fi
_SCREENLOG_SAMPLE_SH=1

SAMPLE_TS=""; SAMPLE_DAY=""; SAMPLE_STATUS=""; SAMPLE_IDLE=""; SAMPLE_FILE=""; SAMPLE_DETAIL=""

# sample_take: always returns 0. SAMPLE_STATUS is shot|locked|no_session|unsupported_session|error.
sample_take() {
  local now rc dir base out n=0
  SAMPLE_TS=""; SAMPLE_DAY=""; SAMPLE_STATUS=""; SAMPLE_IDLE=""; SAMPLE_FILE=""; SAMPLE_DETAIL=""
  SESSION_IDLE_MS=""
  now=$(time_now_epoch)
  SAMPLE_TS=$(time_iso "$now")
  SAMPLE_DAY=$(time_day "$now")
  if [[ -z ${SCREENLOG_DISPLAY:-} ]]; then
    if ! session_find; then
      SAMPLE_STATUS=$SESSION_STATUS
      return 0
    fi
    rc=0
    session_is_locked || rc=$?
    if (( rc == 0 )); then
      SAMPLE_STATUS=locked
      return 0
    fi
    if (( rc == 2 )) && [[ $SESSION_LOCK_WARNED != "$SESSION_ID" ]]; then
      log_warn "session $SESSION_ID: lock state unknown (no LockedHint, no screensaver answer); capturing anyway"
      SESSION_LOCK_WARNED=$SESSION_ID
    fi
  else
    session_reset
    SESSION_STATUS=ok
  fi
  if ! session_resolve_display; then
    SAMPLE_STATUS=error
    SAMPLE_DETAIL="no working DISPLAY for session ${SESSION_ID:-?}"
    return 0
  fi
  if ! SAMPLE_IDLE=$(session_idle_seconds); then
    SAMPLE_STATUS=error
    SAMPLE_DETAIL="xprintidle failed on $SESSION_DISPLAY"
    return 0
  fi
  dir="$SHOTS_DIR/$SAMPLE_DAY"
  if ! mkdir -p -- "$dir"; then
    SAMPLE_STATUS=error
    SAMPLE_DETAIL="cannot create $dir"
    return 0
  fi
  base=$(time_hms "$now")
  out="$dir/$base.jpg"
  while [[ -e $out ]]; do
    n=$((n + 1))
    out="$dir/$base-$n.jpg"
  done
  if capture_take "$out"; then
    SAMPLE_STATUS=shot
    SAMPLE_FILE=${out##*/}
  else
    SAMPLE_STATUS=error
    SAMPLE_DETAIL=$CAPTURE_ERROR
  fi
  return 0
}

# sample_record: append the row for the last sample to that day's samples.csv.
sample_record() {
  csv_append "$(csv_path "$SAMPLE_DAY")" "$SAMPLE_TS" "$SAMPLE_STATUS" "$SAMPLE_IDLE" "$SAMPLE_FILE" "$SAMPLE_DETAIL"
}

# sample_log_line: the one journald line per sample (no secrets: statuses, names, numbers).
sample_log_line() {
  printf 'sample day=%s status=%s idle=%s file=%s%s\n' "$SAMPLE_DAY" "$SAMPLE_STATUS" "${SAMPLE_IDLE:-}" "${SAMPLE_FILE:-}" \
    "${SAMPLE_DETAIL:+ detail=\"$SAMPLE_DETAIL\"}"
}
