# shellcheck shell=bash
# lib/upload.sh - whole-day uploads (spec 5.5) and the small state files other modules share.
# shellcheck disable=SC2034  # UPLOAD_ERROR is read by the daemon and the report
if [[ -n ${_SCREENLOG_UPLOAD_SH:-} ]]; then return 0; fi
_SCREENLOG_UPLOAD_SH=1

UPLOAD_ERROR=""
UPLOAD_DAY_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

upload_marker() { printf '%s/uploaded/%s\n' "$STATE_DIR" "$1"; }

# upload_day DAY [quick]: rclone copy of the whole day folder (idempotent; dot-files are temp
# files and are excluded). On success the marker's mtime is the copy's START time (sub-second,
# like file mtimes), so a shot that landed while rclone was listing is newer than the marker and
# goes up next time.
upload_day() {
  local day=$1 quick=${2:-} start rc
  local -a extra=()
  UPLOAD_ERROR=""
  if [[ ! -d $SHOTS_DIR/$day ]]; then
    UPLOAD_ERROR="no local folder for $day"
    return 1
  fi
  if [[ $quick == quick ]]; then
    extra=(--retries 1)
  fi
  start=$EPOCHREALTIME
  if drive_rclone copy "$SHOTS_DIR/$day" "$(drive_remote_day "$day")" \
      --bwlimit "$UPLOAD_BWLIMIT" --exclude '.*' --transfers 2 --checkers 4 "${extra[@]}"; then
    mkdir -p -- "$STATE_DIR/uploaded" && touch -d "@$start" "$(upload_marker "$day")"
    return 0
  else
    rc=$?
  fi
  UPLOAD_ERROR="rclone exit $rc: $DRIVE_LAST_ERR"
  return "$rc"
}

# upload_is_complete DAY: a successful copy happened and no file is newer than it.
upload_is_complete() {
  local marker
  marker=$(upload_marker "$1")
  [[ -f $marker ]] || return 1
  [[ -z $(find "$SHOTS_DIR/$1" -type f ! -name '.*' -newer "$marker" -print -quit 2>/dev/null) ]]
}

# upload_days_local: every YYYY-MM-DD folder under shots/, oldest first.
upload_days_local() {
  local d
  for d in "$SHOTS_DIR"/*/; do
    d=${d%/}
    d=${d##*/}
    [[ $d =~ $UPLOAD_DAY_RE && -d $SHOTS_DIR/$d ]] && printf '%s\n' "$d"
  done
  return 0
}

# upload_pending [skip_today]: local days that are not completely uploaded.
upload_pending() {
  local d today
  today=$(time_day)
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ ${1:-} == skip_today && $d == "$today" ]]; then continue; fi
    upload_is_complete "$d" || printf '%s\n' "$d"
  done < <(upload_days_local)
  return 0
}

# upload_all [quick] [skip_today]: upload every pending day; return 1 if any failed.
upload_all() {
  local d failed=0
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if upload_day "$d" "${1:-}"; then
      log_info "upload: $d ok"
    else
      failed=1
      log_warn "upload: $d failed ($UPLOAD_ERROR)"
      if (( DRIVE_OFFLINE )); then break; fi
    fi
  done < <(upload_pending "${2:-}")
  (( failed == 0 ))
}

# reported-days: one YYYY-MM-DD per line, appended only after a successful Discord post.
state_day_reported() {
  [[ -r $STATE_DIR/reported-days ]] && grep -qxF -- "$1" "$STATE_DIR/reported-days"
}

state_mark_reported() {
  mkdir -p -- "$STATE_DIR" && printf '%s\n' "$1" >> "$STATE_DIR/reported-days"
}
