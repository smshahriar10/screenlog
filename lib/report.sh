# shellcheck shell=bash
# lib/report.sh - the daily report (spec 5.4): pending and due days, stats, message, posting.
# shellcheck disable=SC2034  # REPORT_* are read by the CLI
if [[ -n ${_SCREENLOG_REPORT_SH:-} ]]; then return 0; fi
_SCREENLOG_REPORT_SH=1

REPORT_POSTED=0
REPORT_DRY_DIR=""
REPORT_WINDOW_DAYS=14
declare -gA REPORT_STATS=()

# report_pending_days: local days inside the last 14 days (today-13 .. today) not yet reported.
report_pending_days() {
  local today start d
  today=$(time_day)
  start=$(time_day_offset "$today" "-$((REPORT_WINDOW_DAYS - 1))")
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    [[ $d < $start ]] && continue
    state_day_reported "$d" || printf '%s\n' "$d"
  done < <(upload_days_local)
  return 0
}

# report_due_days: pending days that are over (before today) or today once REPORT_TIME passed.
report_due_days() {
  local today d
  today=$(time_day)
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ $d < $today ]] || { [[ $d == "$today" ]] && time_is_at_or_after "$REPORT_TIME"; }; then
      printf '%s\n' "$d"
    fi
  done < <(report_pending_days)
  return 0
}

# report_csv_has_samples CSV: at least one data row.
report_csv_has_samples() {
  [[ -s $1 ]] && (( $(grep -c '' "$1") > 1 ))
}

# report_missing_day_due: today is a work day, REPORT_TIME passed, no samples at all, not reported.
report_missing_day_due() {
  local today
  today=$(time_day)
  time_is_work_day "$(time_dow)" || return 1
  time_is_at_or_after "$REPORT_TIME" || return 1
  report_csv_has_samples "$(csv_path "$today")" && return 1
  state_day_reported "$today" && return 1
  return 0
}

# report_stats CSV: key=value lines - samples, shots, active, active_pct (half up), locked,
# no_session, unsupported_session, error, first, last (HH:MM of the first/last shot), gaps
# (every pause between consecutive samples longer than GAP_ALERT_MINUTES, as HH:MM–HH:MM).
report_stats() {
  awk -F, -v thr="$IDLE_THRESHOLD_SECONDS" -v gapmin="$GAP_ALERT_MINUTES" -v dash="–" '
    NR == 1 { next }
    NF < 5 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ { next }
    {
      samples++
      st = $2
      count[st]++
      hh = substr($1, 12, 2); mm = substr($1, 15, 2); ss = substr($1, 18, 2)
      secs = hh * 3600 + mm * 60 + ss
      hm = hh ":" mm
      if (st == "shot") {
        shots++
        if ($3 + 0 < thr) active++
        if (first == "") first = hm
        last = hm
      }
      if (prev != "" && secs - prev > gapmin * 60) gaps = gaps (gaps == "" ? "" : " ") prevhm dash hm
      prev = secs; prevhm = hm
    }
    END {
      pct = (shots > 0) ? int(active * 100 / shots + 0.5) : 0
      printf "samples=%d\nshots=%d\nactive=%d\nactive_pct=%d\nlocked=%d\nno_session=%d\nunsupported_session=%d\nerror=%d\nfirst=%s\nlast=%s\ngaps=%s\n",
        samples, shots, active, pct, count["locked"], count["no_session"], count["unsupported_session"], count["error"], first, last, gaps
    }' "$1"
}

# report_load_stats CSV: report_stats into the REPORT_STATS map.
report_load_stats() {
  local k v
  REPORT_STATS=()
  while IFS='=' read -r k v; do
    REPORT_STATS[$k]=$v
  done < <(report_stats "$1")
}

# report_message DAY LINKLINE: the Discord text for a day, from REPORT_STATS.
report_message() {
  local day=$1 link=$2 line2 g
  line2="${REPORT_STATS[shots]} shots · ${REPORT_STATS[active]} active (${REPORT_STATS[active_pct]}%)"
  (( REPORT_STATS[locked] > 0 )) && line2+=" · locked ${REPORT_STATS[locked]}×"
  (( REPORT_STATS[no_session] > 0 )) && line2+=" · no session ${REPORT_STATS[no_session]}×"
  (( REPORT_STATS[unsupported_session] > 0 )) && line2+=" · unsupported session ${REPORT_STATS[unsupported_session]}×"
  (( REPORT_STATS[error] > 0 )) && line2+=" · error ${REPORT_STATS[error]}×"
  if (( REPORT_STATS[shots] > 0 )); then
    line2+=" · first ${REPORT_STATS[first]} · last ${REPORT_STATS[last]}"
  fi
  printf '📸 %s — %s\n%s\n' "$EMPLOYEE_NAME" "$(time_day_human "$day")" "$line2"
  if [[ -n ${REPORT_STATS[gaps]} ]]; then
    g=${REPORT_STATS[gaps]// /, }
    printf '⚠️ No samples %s\n' "$g"
  fi
  printf '%s\n%s · v%s\n' "$link" "$(hostname)" "$SCREENLOG_VERSION"
}

# report_dry_dir: one temp dir per dry run, printed once, never deleted.
report_dry_dir() {
  if [[ -z $REPORT_DRY_DIR ]]; then
    REPORT_DRY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/screenlog-dryrun.XXXXXX") || die "$EXIT_RUNTIME" "mktemp failed"
    printf 'dry-run dir: %s\n' "$REPORT_DRY_DIR"
  fi
}

# report_day DAY [dry]: upload, stats, contact sheet, Drive link, post, mark. Return 1 when the
# post failed (the day stays pending for the next run). Dry runs write message.json,
# contact-sheet.jpg and tiles.tsv to the dry-run dir and make no network calls.
report_day() {
  local day=$1 dry=${2:-} csv up_rc=0 sheet="" sheet_rc=1 manifest link content today
  csv=$(csv_path "$day")
  today=$(time_day)
  if ! report_csv_has_samples "$csv"; then
    log_info "report: $day has no samples, skipping"
    if [[ $day < $today && $dry != dry ]]; then state_mark_reported "$day"; fi
    return 0
  fi
  if [[ $dry != dry ]]; then
    upload_day "$day" || up_rc=$?
  fi
  report_load_stats "$csv"
  if (( REPORT_STATS[shots] > 0 )); then
    if [[ $dry == dry ]]; then
      report_dry_dir
      sheet="$REPORT_DRY_DIR/contact-sheet.jpg"
      manifest="$REPORT_DRY_DIR/tiles.tsv"
    else
      sheet="$SHOTS_DIR/$day/contact-sheet.jpg"
      manifest="$SCREENLOG_TMP/tiles-$day.tsv"
    fi
    sheet_rc=0
    sheet_build "$day" "$csv" "$sheet" "$manifest" || sheet_rc=$?
    if (( sheet_rc == 0 )); then
      if [[ $dry != dry ]] && (( up_rc == 0 )); then
        upload_day "$day" || up_rc=$?
      fi
    else
      sheet=""
    fi
  fi
  if [[ $dry == dry ]]; then
    link="Full size: (dry run — not uploaded)"
  elif (( up_rc != 0 )); then
    link="⚠️ Drive upload failed: $UPLOAD_ERROR — will retry"
  elif drive_folder_id "$day"; then
    link="Full size: $DRIVE_FOLDER_URL"
  else
    link="⚠️ Drive link unavailable: $DRIVE_LAST_ERR"
  fi
  content=$(report_message "$day" "$link")
  if (( REPORT_STATS[shots] > 0 && sheet_rc == 2 )); then
    content+=$'\n⚠️ Contact sheet too large to attach'
  fi
  if [[ $dry == dry ]]; then
    report_dry_dir
    discord_payload "$content" "$REPORT_DRY_DIR/message.json"
    printf 'message: %s\n' "$REPORT_DRY_DIR/message.json"
    [[ -n $sheet ]] && printf 'contact-sheet: %s\n' "$sheet"
    return 0
  fi
  if discord_post "$content" "$sheet"; then
    state_mark_reported "$day"
    REPORT_POSTED=$((REPORT_POSTED + 1))
    log_info "report: posted $day (HTTP $DISCORD_LAST_HTTP)"
    return 0
  fi
  log_error "report: $day not posted: $DISCORD_LAST_ERROR"
  return 1
}

# report_missing_day_check [dry]: the "no screenshots today" message.
report_missing_day_check() {
  local content today
  report_missing_day_due || return 0
  today=$(time_day)
  content="⚠️ No screenshots from $EMPLOYEE_NAME today ($(hostname))"
  if [[ ${1:-} == dry ]]; then
    report_dry_dir
    discord_payload "$content" "$REPORT_DRY_DIR/missing-day.json"
    printf 'missing-day: %s\n' "$REPORT_DRY_DIR/missing-day.json"
    return 0
  fi
  if discord_post "$content"; then
    state_mark_reported "$today"
    REPORT_POSTED=$((REPORT_POSTED + 1))
    log_info "report: posted the missing-day notice for $today"
    return 0
  fi
  log_error "report: missing-day notice not posted: $DISCORD_LAST_ERROR"
  return 1
}

# report_lock: one report run at a time (the hourly timer and a manual run could overlap).
report_lock() {
  mkdir -p -- "$STATE_DIR" || die "$EXIT_RUNTIME" "cannot create $STATE_DIR"
  exec 8>> "$STATE_DIR/report.lock" || die "$EXIT_RUNTIME" "cannot open report.lock"
  flock -n 8 || die "$EXIT_LOCK" "another report run is in progress"
}

# report_pending [dry]: what the timer runs. Idempotent: a day is posted once. Exits fast when
# nothing is due; the hourly run then only retries pending uploads of earlier days.
report_pending() {
  local dry=${1:-} failed=0 day skip="" missing=0
  local -a due=()
  DISCORD_DEADLINE=$(( EPOCHSECONDS + ${SCREENLOG_REPORT_DEADLINE:-1500} ))
  REPORT_POSTED=0
  mapfile -t due < <(report_due_days)
  report_missing_day_due && missing=1
  time_in_window "$CAPTURE_START" "$CAPTURE_END" && skip=skip_today
  if (( ${#due[@]} == 0 && missing == 0 )); then
    if [[ $dry == dry ]] || [[ -z $(upload_pending "$skip") ]]; then
      log_info "report: nothing to do"
      return 0
    fi
    if drive_probe; then
      upload_all quick "$skip" || true
    fi
    return 0
  fi
  if [[ $dry != dry ]]; then
    drive_probe || true
  fi
  if (( missing )); then
    if [[ $dry != dry ]] && (( EPOCHSECONDS >= DISCORD_DEADLINE )); then
      log_warn "report: deadline reached; the missing-day notice waits for the next run"
      return 1
    fi
    report_missing_day_check "$dry" || failed=1
  fi
  for day in "${due[@]}"; do
    if [[ $dry != dry ]] && (( EPOCHSECONDS >= DISCORD_DEADLINE )); then
      log_warn "report: deadline reached; $day and later days wait for the next run"
      failed=1
      break
    fi
    case $DISCORD_LAST_KIND in
      network|deadline|dead)
        log_warn "report: Discord unreachable; $day waits for the next run"
        failed=1
        break ;;
    esac
    report_day "$day" "$dry" || failed=1
  done
  if [[ $dry != dry ]]; then
    if (( EPOCHSECONDS < DISCORD_DEADLINE )); then
      upload_all quick "$skip" || true
    fi
    if (( REPORT_POSTED > 0 )); then retention_run with-remote; else retention_run; fi
  fi
  (( failed == 0 ))
}
