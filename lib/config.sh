# shellcheck shell=bash
# lib/config.sh - paths, config file parser and validator (spec section 4).
# The config file is never sourced: a small line parser accepts only KEY="value", KEY='value' or
# KEY=value for known keys, so a crafted file cannot run anything. Validation messages name the
# key and the rule, never the value, so secrets stay out of logs and output.
# shellcheck disable=SC2034  # config keys and paths are consumed by the other modules
if [[ -n ${_SCREENLOG_CONFIG_SH:-} ]]; then return 0; fi
_SCREENLOG_CONFIG_SH=1

CONFIG_KEYS=(
  EMPLOYEE_NAME EMPLOYEE_SLUG
  DISCORD_WEBHOOK_URL RCLONE_REMOTE DRIVE_ROOT
  SHOTS_PER_HOUR MIN_GAP_SECONDS MAX_GAP_SECONDS CAPTURE_START CAPTURE_END IDLE_THRESHOLD_SECONDS
  JPEG_QUALITY MAX_HEIGHT
  REPORT_TIME WORK_DAYS GAP_ALERT_MINUTES
  LOCAL_RETENTION_DAYS REMOTE_RETENTION_DAYS UPLOAD_BWLIMIT
)
CONFIG_REQUIRED=(EMPLOYEE_NAME EMPLOYEE_SLUG DISCORD_WEBHOOK_URL)
CONFIG_SECRET=(DISCORD_WEBHOOK_URL)
CONFIG_ERRORS=()
declare -gA CONFIG_SEEN=()   # -g: stays global even when sourced inside a function (bats)

CONFIG_LINE_RE='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
CONFIG_DQ_RE='^"([^"\\]*)"[[:space:]]*(#.*)?$'
CONFIG_SQ_RE="^'([^']*)'[[:space:]]*(#.*)?\$"
CONFIG_BARE_RE='^([^"'"'"'[:space:]#]*)[[:space:]]*(#.*)?$'
CONFIG_HHMM_RE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
CONFIG_WEBHOOK_RE='^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/(v[0-9]+/)?webhooks/([0-9]{15,22})/([A-Za-z0-9_.-]{20,})/?$'
CONFIG_SLUG_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
CONFIG_BWLIMIT_RE='^(off|[0-9]+(\.[0-9]+)?[kKMGT]?i?)$'
CONFIG_DAYS="Sun Mon Tue Wed Thu Fri Sat"

# paths_init: every path the app touches, derived from the SCREENLOG_* overrides. All system-path
# literals live here so tests can point everything at a fake root with SCREENLOG_SYSROOT.
paths_init() {
  SCREENLOG_SYSROOT=${SCREENLOG_SYSROOT:-}
  SCREENLOG_CONFIG=${SCREENLOG_CONFIG:-$SCREENLOG_SYSROOT/etc/screenlog/screenlog.conf}
  SCREENLOG_RCLONE_CONF=${SCREENLOG_RCLONE_CONF:-${SCREENLOG_CONFIG%/*}/rclone.conf}
  SCREENLOG_DATA_DIR=${SCREENLOG_DATA_DIR:-$SCREENLOG_SYSROOT/var/lib/screenlog}
  SHOTS_DIR=$SCREENLOG_DATA_DIR/shots
  STATE_DIR=$SCREENLOG_DATA_DIR/state
  WORK_TMP_DIR=$SCREENLOG_DATA_DIR/tmp
  PATH_ETC_DIR=${SCREENLOG_CONFIG%/*}
  PATH_GDM_CONF=$SCREENLOG_SYSROOT/etc/gdm3/custom.conf
  PATH_RELEASE_UPGRADES=$SCREENLOG_SYSROOT/etc/update-manager/release-upgrades
  PATH_UNIT_DIR=$SCREENLOG_SYSROOT/etc/systemd/system
  PATH_OS_RELEASE=$SCREENLOG_SYSROOT/etc/os-release
  PATH_RUN_USER=$SCREENLOG_SYSROOT/run/user
  PATH_X11_SOCKETS=$SCREENLOG_SYSROOT/tmp/.X11-unix
  PATH_APP_DIR=$SCREENLOG_SYSROOT/opt/screenlog
  PATH_CLI_LINK=$SCREENLOG_SYSROOT/usr/local/bin/screenlog
  PATH_FONT=${SCREENLOG_FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}
  PATH_FONT_BOLD=${SCREENLOG_FONT_BOLD:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}
  export SCREENLOG_CONFIG SCREENLOG_RCLONE_CONF SCREENLOG_DATA_DIR SCREENLOG_SYSROOT
}

config_defaults() {
  EMPLOYEE_NAME=""
  EMPLOYEE_SLUG=""
  DISCORD_WEBHOOK_URL=""
  RCLONE_REMOTE="screenlog-gdrive"
  DRIVE_ROOT="Screenlog"
  SHOTS_PER_HOUR=7
  MIN_GAP_SECONDS=60
  MAX_GAP_SECONDS=1800
  CAPTURE_START="09:00"
  CAPTURE_END="17:50"
  IDLE_THRESHOLD_SECONDS=300
  JPEG_QUALITY=85
  MAX_HEIGHT=1080
  REPORT_TIME="17:30"
  WORK_DAYS="Sun Mon Tue Wed Thu"
  GAP_ALERT_MINUTES=45
  LOCAL_RETENTION_DAYS=7
  REMOTE_RETENTION_DAYS=60
  UPLOAD_BWLIMIT="1M"
  DISCORD_WEBHOOK_ID=""
  DISCORD_WEBHOOK_TOKEN=""
  DISCORD_API_URL=""
  CONFIG_ERRORS=()
  CONFIG_SEEN=()
}

config_is_key() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do
    if [[ $k == "$1" ]]; then return 0; fi
  done
  return 1
}

config_is_secret() {
  local k
  for k in "${CONFIG_SECRET[@]}"; do
    if [[ $k == "$1" ]]; then return 0; fi
  done
  return 1
}

# config_set KEY VALUE: assign a known key as if it had been read from the file.
config_set() {
  config_is_key "$1" || return 1
  printf -v "$1" '%s' "$2"
  CONFIG_SEEN[$1]=1
}

# config_parse_value RAW -> prints the unquoted value; return 1 when RAW is not a valid value.
config_parse_value() {
  if [[ $1 =~ $CONFIG_DQ_RE ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $1 =~ $CONFIG_SQ_RE ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $1 =~ $CONFIG_BARE_RE ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# config_parse_file PATH: assign known keys from PATH; errors go to CONFIG_ERRORS. Return 0 iff
# this file added no errors. Resets CONFIG_SEEN so a second file can be parsed in the same process.
config_parse_file() {
  local path=$1 line n=0 key rest val before
  CONFIG_SEEN=()
  before=${#CONFIG_ERRORS[@]}
  if [[ ! -r $path ]]; then
    CONFIG_ERRORS+=("cannot read $path")
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ ! $line =~ $CONFIG_LINE_RE ]]; then
      CONFIG_ERRORS+=("line $n: cannot parse (expected KEY=\"value\")")
      continue
    fi
    key=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    if ! config_is_key "$key"; then
      CONFIG_ERRORS+=("line $n: unknown key $key")
      continue
    fi
    if ! val=$(config_parse_value "$rest"); then
      CONFIG_ERRORS+=("line $n: $key: cannot parse value (expected KEY=\"value\")")
      continue
    fi
    if [[ -n ${CONFIG_SEEN[$key]:-} ]]; then
      CONFIG_ERRORS+=("line $n: duplicate key $key")
      continue
    fi
    config_set "$key" "$val"
  done < "$path"
  (( ${#CONFIG_ERRORS[@]} == before ))
}

# config_read_key PATH KEY: print KEY's value from PATH without assigning anything (install.sh
# reads the installed name and slug while the bundle config is loaded). Return 1 when absent.
config_read_key() {
  local path=$1 want=$2 line key rest
  if [[ ! -r $path ]]; then return 1; fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ ! $line =~ $CONFIG_LINE_RE ]]; then continue; fi
    key=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    if [[ $key != "$want" ]]; then continue; fi
    config_parse_value "$rest"
    return
  done < "$path"
  return 1
}

# config_is_int VALUE MIN MAX
config_is_int() {
  [[ $1 =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

config_check_int() {
  local key=$1 min=$2 max=$3
  if ! config_is_int "${!key}" "$min" "$max"; then
    CONFIG_ERRORS+=("$key: must be an integer from $min to $max")
    return 1
  fi
}

config_check_hhmm() {
  local key=$1
  if [[ ! ${!key} =~ $CONFIG_HHMM_RE ]]; then
    CONFIG_ERRORS+=("$key: must be HH:MM (24-hour)")
    return 1
  fi
}

# config_validate: every per-key and cross-key rule; appends to CONFIG_ERRORS; derives the
# Discord id/token/API URL. Return 0 iff CONFIG_ERRORS is empty afterwards.
config_validate() {
  local k ints_ok=1 times_ok=1 day seen_days=" " n
  for k in "${CONFIG_REQUIRED[@]}"; do
    if [[ -z ${CONFIG_SEEN[$k]:-} ]]; then
      CONFIG_ERRORS+=("missing required key $k")
    fi
  done
  if [[ -n ${CONFIG_SEEN[EMPLOYEE_NAME]:-} ]]; then
    n=${#EMPLOYEE_NAME}
    if (( n < 1 || n > 80 )); then
      CONFIG_ERRORS+=("EMPLOYEE_NAME: must be 1 to 80 characters")
    elif [[ $EMPLOYEE_NAME == *[\"\\]* || $EMPLOYEE_NAME == *[[:cntrl:]]* ]]; then
      CONFIG_ERRORS+=("EMPLOYEE_NAME: must not contain quotes, backslashes or control characters")
    fi
  fi
  if [[ -n ${CONFIG_SEEN[EMPLOYEE_SLUG]:-} ]]; then
    if [[ ! $EMPLOYEE_SLUG =~ $CONFIG_SLUG_RE ]] || (( ${#EMPLOYEE_SLUG} > 64 )); then
      CONFIG_ERRORS+=("EMPLOYEE_SLUG: must be lowercase letters, digits and single hyphens, at most 64 characters")
    fi
  fi
  if [[ -n ${CONFIG_SEEN[DISCORD_WEBHOOK_URL]:-} ]]; then
    if [[ $DISCORD_WEBHOOK_URL =~ $CONFIG_WEBHOOK_RE ]]; then
      DISCORD_WEBHOOK_ID=${BASH_REMATCH[3]}
      DISCORD_WEBHOOK_TOKEN=${BASH_REMATCH[4]}
      DISCORD_API_URL="https://discord.com/api/v10/webhooks/$DISCORD_WEBHOOK_ID/$DISCORD_WEBHOOK_TOKEN"
    else
      CONFIG_ERRORS+=("DISCORD_WEBHOOK_URL: must look like https://discord.com/api/webhooks/<id>/<token>")
    fi
  fi
  if [[ ! $RCLONE_REMOTE =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    CONFIG_ERRORS+=("RCLONE_REMOTE: must be a plain rclone remote name")
  fi
  if [[ ! $DRIVE_ROOT =~ ^[^/:[:cntrl:]]+(/[^/:[:cntrl:]]+)*$ ]]; then
    CONFIG_ERRORS+=("DRIVE_ROOT: must be a folder path without leading or trailing slashes")
  fi
  config_check_int SHOTS_PER_HOUR 1 60 || ints_ok=0
  config_check_int MIN_GAP_SECONDS 1 86400 || ints_ok=0
  config_check_int MAX_GAP_SECONDS 1 86400 || ints_ok=0
  config_check_int IDLE_THRESHOLD_SECONDS 0 86400 || ints_ok=0
  config_check_int JPEG_QUALITY 1 100 || ints_ok=0
  config_check_int MAX_HEIGHT 240 8640 || ints_ok=0
  config_check_int GAP_ALERT_MINUTES 1 1440 || ints_ok=0
  config_check_int LOCAL_RETENTION_DAYS 1 3650 || ints_ok=0
  config_check_int REMOTE_RETENTION_DAYS 0 36500 || ints_ok=0
  config_check_hhmm CAPTURE_START || times_ok=0
  config_check_hhmm CAPTURE_END || times_ok=0
  config_check_hhmm REPORT_TIME || times_ok=0
  if (( ints_ok )); then
    if (( 10#$MAX_GAP_SECONDS < 10#$MIN_GAP_SECONDS )); then
      CONFIG_ERRORS+=("MAX_GAP_SECONDS: must not be less than MIN_GAP_SECONDS")
    fi
    if (( 10#$GAP_ALERT_MINUTES * 60 <= 10#$MAX_GAP_SECONDS )); then
      CONFIG_ERRORS+=("GAP_ALERT_MINUTES: must be greater than MAX_GAP_SECONDS/60")
    fi
  fi
  if (( times_ok )); then
    if (( $(time_hhmm_to_min "$CAPTURE_START") >= $(time_hhmm_to_min "$CAPTURE_END") )); then
      CONFIG_ERRORS+=("CAPTURE_END: must be later than CAPTURE_START")
    fi
  fi
  for day in $WORK_DAYS; do
    if [[ " $CONFIG_DAYS " != *" $day "* ]]; then
      CONFIG_ERRORS+=("WORK_DAYS: must be space-separated day names from: $CONFIG_DAYS")
      break
    fi
    if [[ $seen_days == *" $day "* ]]; then
      CONFIG_ERRORS+=("WORK_DAYS: day listed twice")
      break
    fi
    seen_days+="$day "
  done
  if [[ ! $UPLOAD_BWLIMIT =~ $CONFIG_BWLIMIT_RE ]]; then
    CONFIG_ERRORS+=("UPLOAD_BWLIMIT: must be a bandwidth like 1M, 500k or off")
  fi
  (( ${#CONFIG_ERRORS[@]} == 0 ))
}

# config_check [PATH]: defaults + parse + validate; print every error as "config: ..." to stderr.
config_check() {
  local path=${1:-$SCREENLOG_CONFIG} e
  config_defaults
  if config_parse_file "$path" || [[ -r $path ]]; then
    config_validate
  fi
  if (( ${#CONFIG_ERRORS[@]} == 0 )); then return 0; fi
  for e in "${CONFIG_ERRORS[@]}"; do
    printf 'config: %s\n' "$e" >&2
  done
  return 1
}

# config_load: paths, then a valid config from $SCREENLOG_CONFIG or exit EXIT_CONFIG.
config_load() {
  paths_init
  config_check "$SCREENLOG_CONFIG" || die "$EXIT_CONFIG" "invalid config ($SCREENLOG_CONFIG)"
  REMOTE_EMPLOYEE="$RCLONE_REMOTE:$DRIVE_ROOT/$EMPLOYEE_SLUG"
}

# config_print_public: KEY=value for every key; secrets shown as <set>/<unset>.
config_print_public() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do
    if config_is_secret "$k"; then
      if [[ -n ${!k} ]]; then printf '%s=<set>\n' "$k"; else printf '%s=<unset>\n' "$k"; fi
    else
      printf '%s=%s\n' "$k" "${!k}"
    fi
  done
}

# config_write PATH: write every key from the current globals as KEY="value" (atomic, mode 600).
config_write() {
  local path=$1 k v tmp dir
  for k in "${CONFIG_KEYS[@]}"; do
    v=${!k}
    if [[ $v == *[\"\\]* || $v == *[[:cntrl:]]* ]]; then
      log_error "config_write: $k contains a character that cannot be written"
      return 1
    fi
  done
  dir=${path%/*}
  tmp=$(mktemp "$dir/.screenlog.conf.XXXXXX") || return 1
  {
    printf '# screenlog configuration - written by install.sh. Edit, then run: sudo screenlog apply-config\n'
    printf '# Keys are KEY="value"; see config/screenlog.conf.example in the bundle for the meaning of each.\n'
    for k in "${CONFIG_KEYS[@]}"; do
      printf '%s="%s"\n' "$k" "${!k}"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f -- "$tmp" "$path"
}
