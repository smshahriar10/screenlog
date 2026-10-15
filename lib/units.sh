# shellcheck shell=bash
# lib/units.sh - render and install the systemd units (spec section 6); shared by install.sh
# and `screenlog apply-config`.
# shellcheck disable=SC2034  # UNITS_CHANGED is read by install.sh
if [[ -n ${_SCREENLOG_UNITS_SH:-} ]]; then return 0; fi
_SCREENLOG_UNITS_SH=1

UNITS_CHANGED=0
UNIT_NAMES=(screenlog.service screenlog-report.service screenlog-report.timer)

# units_render SRC_DIR DEST_DIR REPORT_TIME: the two services verbatim, the timer with
# @REPORT_TIME@ replaced; each file installed atomically with mode 644 only when it changed.
units_render() {
  local src=$1 dest=$2 rt=$3 u tmp
  UNITS_CHANGED=0
  tmp=$(mktemp "${SCREENLOG_TMP:-/tmp}/unit.XXXXXX") || return 1
  for u in "${UNIT_NAMES[@]}"; do
    if [[ $u == screenlog-report.timer ]]; then
      sed "s/@REPORT_TIME@/$rt/g" "$src/$u.in" > "$tmp" || return 1
      if grep -q '@' "$tmp"; then
        log_error "units: unrendered placeholder in $u"
        return 1
      fi
    else
      cp -- "$src/$u" "$tmp" || return 1
    fi
    if [[ -f $dest/$u ]] && cmp -s "$tmp" "$dest/$u"; then
      log_info "unit $u: unchanged"
    else
      install -m 644 "$tmp" "$dest/$u" || return 1
      log_info "unit $u: updated"
      UNITS_CHANGED=1
    fi
  done
  rm -f -- "$tmp"
}

units_enable_now() {
  systemctl daemon-reload && systemctl enable --now screenlog.service screenlog-report.timer
}

units_restart() {
  systemctl restart screenlog-report.timer screenlog.service
}

# units_next_report: when the timer fires next, e.g. "Thu 2026-10-15 17:30:00 +06".
units_next_report() {
  local line
  line=$(systemctl list-timers --no-legend --all screenlog-report.timer 2>/dev/null | head -n1)
  if [[ -z $line || $line == -* || $line == n/a* ]]; then
    printf 'not scheduled\n'
  else
    awk '{print $1, $2, $3, $4}' <<< "$line"
  fi
}
