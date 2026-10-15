# shellcheck shell=bash
# lib/retention.sh - local and Drive retention (spec 5.8).
if [[ -n ${_SCREENLOG_RETENTION_SH:-} ]]; then return 0; fi
_SCREENLOG_RETENTION_SH=1

# retention_local: delete day folders older than LOCAL_RETENTION_DAYS, but only once the day was
# completely uploaded and either reported or out of the 14-day report window (so a report can
# still be built from local files). A day without a marker gets one quick upload attempt first.
retention_local() {
  local today cutoff window_start d
  today=$(time_day)
  cutoff=$(time_day_offset "$today" "-$LOCAL_RETENTION_DAYS")
  window_start=$(time_day_offset "$today" -13)
  while IFS= read -r d; do
    [[ -n $d && $d < $cutoff ]] || continue
    if ! upload_is_complete "$d"; then
      upload_day "$d" quick || continue
    fi
    upload_is_complete "$d" || continue
    if state_day_reported "$d" || [[ $d < $window_start ]]; then
      rm -rf -- "${SHOTS_DIR:?}/$d" "$(upload_marker "$d")"
      log_info "retention: removed local $d"
    fi
  done < <(upload_days_local)
  return 0
}

# retention_remote: files older than REMOTE_RETENTION_DAYS go to the Drive trash; empty day
# folders are removed, the employee folder stays.
retention_remote() {
  if (( REMOTE_RETENTION_DAYS <= 0 )); then return 0; fi
  if ! drive_rclone delete "$(drive_remote_employee)" --min-age "${REMOTE_RETENTION_DAYS}d" --retries 2; then
    log_warn "retention: rclone delete failed ($DRIVE_LAST_ERR)"
    return 1
  fi
  if ! drive_rclone rmdirs "$(drive_remote_employee)" --leave-root --retries 2; then
    log_warn "retention: rclone rmdirs failed ($DRIVE_LAST_ERR)"
    return 1
  fi
  log_info "retention: Drive files older than ${REMOTE_RETENTION_DAYS} days trashed"
}

# retention_run [with-remote]: local always; Drive only when asked (about once a day).
retention_run() {
  retention_local
  if [[ ${1:-} == with-remote ]]; then
    retention_remote || true
  fi
  return 0
}
