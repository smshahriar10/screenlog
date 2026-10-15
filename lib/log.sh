# shellcheck shell=bash
# lib/log.sh - logging, redaction, exit codes, temp dir and interruptible children.
# Sourced first by every entry point. Functions only; no top-level side effects.
if [[ -n ${_SCREENLOG_LOG_SH:-} ]]; then return 0; fi
_SCREENLOG_LOG_SH=1

# Exit codes shared by every script (documented in `screenlog help` and TROUBLESHOOTING.md).
# shellcheck disable=SC2034  # consumed by other modules and scripts
{
  EXIT_OK=0
  EXIT_RUNTIME=1
  EXIT_USAGE=2
  EXIT_CONFIG=3
  EXIT_ROOT=4
  EXIT_LOCK=5
  EXIT_DEPENDENCY=6
  EXIT_REMOTE=7
  EXIT_SYSTEM=8
  EXIT_INTERRUPTED=130
}

# Webhook URLs are replaced by <webhook> wherever child-process output is logged.
LOG_WEBHOOK_RE='https://[A-Za-z0-9.-]*discord(app)?\.com/api/(v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9_-]+'

RUN_STOP=0
CHILD_PID=""
SCREENLOG_TMP=""

# log_prefix: timestamp only when not under journald (which stamps lines itself).
log_prefix() {
  if [[ -z ${JOURNAL_STREAM:-} ]]; then
    printf '%(%Y-%m-%d %H:%M:%S)T ' -1
  fi
}

log_info()  { printf '%sINFO: %s\n' "$(log_prefix)" "$*"; }
log_warn()  { printf '%sWARN: %s\n' "$(log_prefix)" "$*" >&2; }
log_error() { printf '%sERROR: %s\n' "$(log_prefix)" "$*" >&2; }
log_debug() {
  if [[ -n ${SCREENLOG_DEBUG:-} ]]; then
    printf '%sDEBUG: %s\n' "$(log_prefix)" "$*" >&2
  fi
}

# log_redact_str STRING: print STRING with webhook URLs, the webhook token and control bytes removed.
log_redact_str() {
  local s
  s=$(printf '%s' "$1" | sed -E "s#${LOG_WEBHOOK_RE}#<webhook>#g")
  if [[ -n ${DISCORD_WEBHOOK_TOKEN:-} ]]; then
    s=${s//"$DISCORD_WEBHOOK_TOKEN"/<token>}
  fi
  printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
  printf '\n'
}

# log_redact: stdin filter version of log_redact_str.
log_redact() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    log_redact_str "$line"
  done
}

# die [CODE] MESSAGE...: log an error and exit. CODE defaults to EXIT_RUNTIME.
die() {
  local code=$EXIT_RUNTIME
  if [[ $1 =~ ^[0-9]+$ ]]; then
    code=$1
    shift
  fi
  log_error "$*"
  exit "$code"
}

# require_root NAME: every CLI command except version/help must run as root.
require_root() {
  if (( EUID != 0 )); then
    die "$EXIT_ROOT" "screenlog ${1:-} must run as root (sudo screenlog ${1:-})"
  fi
}

# tmp_init: private temp dir for this process, removed on exit.
tmp_init() {
  if [[ -n $SCREENLOG_TMP ]]; then return 0; fi
  SCREENLOG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/screenlog.XXXXXX") || die "$EXIT_RUNTIME" "mktemp failed"
  chmod 700 "$SCREENLOG_TMP"
  trap tmp_cleanup EXIT
}

tmp_cleanup() {
  if [[ -n $SCREENLOG_TMP ]]; then
    rm -rf -- "$SCREENLOG_TMP"
    SCREENLOG_TMP=""
  fi
}

# run_child CMD ARGS...: run a long-running child in the background and wait for it, so a TERM
# trap (which sets RUN_STOP=1 and kills CHILD_PID) interrupts it at once. Never call a function
# that uses run_child inside $( ): the subshell would hide CHILD_PID from the trap. Children never
# read stdin (an asynchronous command gets /dev/null).
run_child() {
  local rc
  "$@" &
  CHILD_PID=$!
  if (( RUN_STOP )); then
    kill -TERM "$CHILD_PID" 2>/dev/null
  fi
  if wait "$CHILD_PID"; then rc=0; else rc=$?; fi
  CHILD_PID=""
  return "$rc"
}

# sleep_interruptible SECONDS: returns 1 when the sleep was cut short by a stop request.
sleep_interruptible() {
  run_child sleep "$1" || true
  (( RUN_STOP == 0 ))
}

# stop_children: the shared TERM/INT trap body for the daemon and the CLI.
stop_children() {
  RUN_STOP=1
  if [[ -n $CHILD_PID ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null
  fi
}
