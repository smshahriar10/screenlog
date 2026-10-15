# shellcheck shell=bash
# lib/time.sh - the only module that reads the clock or calls `date`.
# SCREENLOG_NOW (anything GNU `date -d` accepts) freezes "now" for every caller: file names, CSV
# timestamps, the capture window and the report scheduling all go through time_now_epoch.
# Hot-path helpers use bash builtins ($EPOCHSECONDS, printf %T); `date -d` is used only for
# parsing SCREENLOG_NOW, day arithmetic and human-readable dates.
if [[ -n ${_SCREENLOG_TIME_SH:-} ]]; then return 0; fi
_SCREENLOG_TIME_SH=1

TIME_FAKE_EPOCH=""
TIME_FAKE_SRC=""
# Day and month names are produced from numbers, so they are English whatever the locale is.
TIME_DOW_NAMES=(Mon Tue Wed Thu Fri Sat Sun)
TIME_MONTH_NAMES=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

# time_init: validate SCREENLOG_NOW once in the main shell (a die inside $( ) would only kill
# the subshell). Called by config_load.
time_init() {
  if [[ -n ${SCREENLOG_NOW:-} ]]; then
    TIME_FAKE_EPOCH=$(date -d "$SCREENLOG_NOW" +%s 2>/dev/null) \
      || die "$EXIT_USAGE" "SCREENLOG_NOW is not a date: $SCREENLOG_NOW"
    TIME_FAKE_SRC=$SCREENLOG_NOW
  fi
}

# time_now_epoch: seconds since the epoch, real or faked.
time_now_epoch() {
  if [[ -n ${SCREENLOG_NOW:-} ]]; then
    if [[ -z $TIME_FAKE_EPOCH || $TIME_FAKE_SRC != "$SCREENLOG_NOW" ]]; then
      TIME_FAKE_EPOCH=$(date -d "$SCREENLOG_NOW" +%s 2>/dev/null) \
        || die "$EXIT_USAGE" "SCREENLOG_NOW is not a date: $SCREENLOG_NOW"
      TIME_FAKE_SRC=$SCREENLOG_NOW
    fi
    printf '%s\n' "$TIME_FAKE_EPOCH"
  else
    printf '%s\n' "$EPOCHSECONDS"
  fi
}

# time_epoch_arg [EPOCH]: the epoch to format - the argument, or now; never empty.
time_epoch_arg() {
  local e=${1:-}
  [[ -n $e ]] || e=$(time_now_epoch)
  [[ $e =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$e"
}

# Formatting helpers take an optional epoch argument (callers in the daemon fetch it once per sample).
time_day()  { local e; e=$(time_epoch_arg "${1:-}") || return 1; printf '%(%F)T\n' "$e"; }
time_hms()  { local e; e=$(time_epoch_arg "${1:-}") || return 1; printf '%(%H-%M-%S)T\n' "$e"; }
time_hhmm() { local e; e=$(time_epoch_arg "${1:-}") || return 1; printf '%(%H:%M)T\n' "$e"; }
time_dow() {
  local e u
  e=$(time_epoch_arg "${1:-}") || return 1
  printf -v u '%(%u)T' "$e"
  printf '%s\n' "${TIME_DOW_NAMES[u - 1]}"
}
time_clock() { local e; e=$(time_epoch_arg "${1:-}") || return 1; printf '%(%H:%M:%S)T\n' "$e"; }

# time_iso [EPOCH]: local ISO 8601 with a colon in the offset, e.g. 2026-10-15T09:12:33+06:00.
time_iso() {
  local e z
  e=$(time_epoch_arg "${1:-}") || return 1
  printf -v z '%(%z)T' "$e"
  printf '%(%Y-%m-%dT%H:%M:%S)T%s:%s\n' "$e" "${z:0:3}" "${z:3}"
}

# time_hhmm_to_min HH:MM -> minutes since midnight.
time_hhmm_to_min() {
  printf '%s\n' $(( 10#${1%%:*} * 60 + 10#${1##*:} ))
}

# time_min_of_day [EPOCH] -> minutes since local midnight.
time_min_of_day() {
  local e h m
  e=$(time_epoch_arg "${1:-}") || return 1
  printf -v h '%(%H)T' "$e"
  printf -v m '%(%M)T' "$e"
  printf '%s\n' $(( 10#$h * 60 + 10#$m ))
}

# time_in_window START END [EPOCH]: true inside [START, END) at minute granularity.
time_in_window() {
  local now s e
  now=$(time_min_of_day "${3:-}")
  s=$(time_hhmm_to_min "$1")
  e=$(time_hhmm_to_min "$2")
  (( s <= now && now < e ))
}

# time_is_at_or_after HH:MM [EPOCH]: true when the current minute is at or after HH:MM.
time_is_at_or_after() {
  local now t
  now=$(time_min_of_day "${2:-}")
  t=$(time_hhmm_to_min "$1")
  (( now >= t ))
}

# time_day_offset YYYY-MM-DD N: the day N days later (N may be negative).
time_day_offset() {
  if [[ $2 == -* ]]; then
    date -d "$1 ${2#-} days ago" +%F
  else
    date -d "$1 $2 days" +%F
  fi
}

# time_day_human YYYY-MM-DD -> "Thu 15 Oct 2026" (English names whatever the locale).
time_day_human() {
  local u d m y
  read -r u d m y < <(date -d "$1" '+%u %-d %m %Y')
  printf '%s %s %s %s\n' "${TIME_DOW_NAMES[u - 1]}" "$d" "${TIME_MONTH_NAMES[10#$m - 1]}" "$y"
}

# time_day_dow YYYY-MM-DD -> Sun..Sat.
time_day_dow() {
  local u
  u=$(date -d "$1" +%u)
  printf '%s\n' "${TIME_DOW_NAMES[u - 1]}"
}

# time_parse EPOCH-OR-DATE -> epoch seconds (for CSV timestamps and SCREENLOG_NOW-style strings).
time_parse() {
  date -d "$1" +%s
}

# time_is_work_day DOW: true when DOW (Sun..Sat) is listed in WORK_DAYS.
time_is_work_day() {
  [[ " $WORK_DAYS " == *" $1 "* ]]
}
