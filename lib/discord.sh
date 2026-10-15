# shellcheck shell=bash
# lib/discord.sh - webhook posts (spec 5.7). The webhook URL reaches curl only through a private
# config file (never argv, which every local user can read in /proc). Images are downscaled copies.
# shellcheck disable=SC2034  # DISCORD_LAST_* are read by the report, the daemon and the CLI
if [[ -n ${_SCREENLOG_DISCORD_SH:-} ]]; then return 0; fi
_SCREENLOG_DISCORD_SH=1

DISCORD_LAST_HTTP=""
DISCORD_LAST_ERROR=""
DISCORD_LAST_KIND=""        # ok | http | network | deadline | dead
DISCORD_DEAD=0              # set after a 404: Discord asks that a dead webhook is never retried
DISCORD_DEADLINE=""         # epoch; waits that would pass it are refused
DISCORD_WEBHOOK_NAME=""

# discord_payload CONTENT OUTFILE: {"content": ..., "allowed_mentions": {"parse": []}}
discord_payload() {
  jq -n --arg c "$1" '{content: $c, allowed_mentions: {parse: []}}' > "$2"
}

# discord_curl BODYFILE [curl args...]: one request to the v10 webhook URL. DISCORD_LAST_HTTP
# holds the status code (000 on a connection failure); returns curl's exit code.
discord_curl() {
  local body=$1 cfg rc=0
  shift
  cfg="$SCREENLOG_TMP/curl.cfg"
  printf 'url = "%s"\n' "$DISCORD_API_URL" > "$cfg" || return 1
  chmod 600 "$cfg"
  if run_child curl -sS -K "$cfg" -o "$body" -D "$SCREENLOG_TMP/curl.hdr" -w '%{http_code}' \
      --connect-timeout 15 --max-time "${SCREENLOG_CURL_MAX_TIME:-120}" \
      -A "screenlog/${SCREENLOG_VERSION:-0}" "$@" > "$SCREENLOG_TMP/curl.code" 2> "$SCREENLOG_TMP/curl.err"; then
    rc=0
  else
    rc=$?
  fi
  DISCORD_LAST_HTTP=$(tr -dc '0-9' < "$SCREENLOG_TMP/curl.code")
  return "$rc"
}

# discord_error_message BODYFILE: Discord's "message" field, redacted and short (never the body).
discord_error_message() {
  local m
  m=$(jq -r '.message // empty' "$1" 2>/dev/null | head -n1)
  log_redact_str "${m:0:100}"
}

# discord_retry_after BODYFILE HDRFILE: seconds to wait after a 429 (header first, then the
# float retry_after in the body), rounded up, at least 1, at most 300.
discord_retry_after() {
  local ra
  ra=$(grep -i '^retry-after:' "$2" 2>/dev/null | tail -n1 | tr -d '\r' | awk '{print $2}')
  if [[ ! $ra =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ra=$(jq -r '.retry_after // empty' "$1" 2>/dev/null)
  fi
  if [[ ! $ra =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ra=5
  fi
  awk -v r="$ra" 'BEGIN { n = int(r); if (n < r) n++; if (n < 1) n = 1; if (n > 300) n = 300; print n }'
}

# discord_wait SECONDS: sleep unless that would pass DISCORD_DEADLINE or a stop was requested.
discord_wait() {
  if [[ -n $DISCORD_DEADLINE ]] && (( EPOCHSECONDS + $1 > DISCORD_DEADLINE )); then
    return 1
  fi
  sleep_interruptible "$1"
}

# discord_post CONTENT [IMAGE]: multipart POST with retries. 2xx -> 0. 429 -> wait retry_after
# (at most 5 times). Other 4xx -> permanent failure (404 marks the webhook dead for this process).
# Network errors and 5xx -> backoff SCREENLOG_DISCORD_BACKOFF ("60 240 600": 4 attempts, ~15 min).
discord_post() {
  local content=$1 image=${2:-} payload body attempt=0 rc code wait_s rate_waits=0 max_attempts
  local -a backoff form
  DISCORD_LAST_HTTP=""; DISCORD_LAST_ERROR=""; DISCORD_LAST_KIND=""
  if (( DISCORD_DEAD )); then
    DISCORD_LAST_KIND=dead
    DISCORD_LAST_ERROR="webhook rejected earlier in this run (HTTP 404)"
    return 1
  fi
  read -r -a backoff <<< "${SCREENLOG_DISCORD_BACKOFF:-60 240 600}"
  max_attempts=$(( ${#backoff[@]} + 1 ))
  payload="$SCREENLOG_TMP/payload.json"
  body="$SCREENLOG_TMP/curl.body"
  if ! discord_payload "$content" "$payload"; then
    DISCORD_LAST_KIND=http
    DISCORD_LAST_ERROR="cannot build the message payload"
    return 1
  fi
  form=(-F "payload_json=<$payload;type=application/json")
  if [[ -n $image ]]; then
    form+=(-F "files[0]=@$image;type=image/jpeg;filename=${image##*/}")
  fi
  while :; do
    attempt=$((attempt + 1))
    rc=0
    discord_curl "$body" "${form[@]}" || rc=$?
    code=$DISCORD_LAST_HTTP
    if (( rc == 0 )) && [[ $code == 2?? ]]; then
      DISCORD_LAST_KIND=ok
      return 0
    fi
    if (( rc == 0 )) && [[ $code == 429 ]]; then
      rate_waits=$((rate_waits + 1))
      if (( rate_waits > 5 )); then
        DISCORD_LAST_KIND=http
        DISCORD_LAST_ERROR="HTTP 429: rate limited for too long"
        return 1
      fi
      wait_s=$(discord_retry_after "$body" "$SCREENLOG_TMP/curl.hdr")
      log_warn "discord: rate limited (HTTP 429), waiting ${wait_s}s (retry_after)"
      if ! discord_wait "$wait_s"; then
        DISCORD_LAST_KIND=deadline
        DISCORD_LAST_ERROR="HTTP 429: no time left to wait"
        return 1
      fi
      continue
    fi
    if (( rc == 0 )) && [[ $code == 4?? ]]; then
      DISCORD_LAST_KIND=http
      DISCORD_LAST_ERROR="HTTP $code: $(discord_error_message "$body")"
      if [[ $code == 404 ]]; then DISCORD_DEAD=1; DISCORD_LAST_KIND=dead; fi
      return 1
    fi
    if (( rc != 0 )); then
      DISCORD_LAST_ERROR="curl exit $rc: $(log_redact_str "$(head -n1 "$SCREENLOG_TMP/curl.err" 2>/dev/null)")"
    else
      DISCORD_LAST_ERROR="HTTP $code: $(discord_error_message "$body")"
    fi
    DISCORD_LAST_ERROR=${DISCORD_LAST_ERROR:0:160}
    if (( attempt >= max_attempts )); then
      DISCORD_LAST_KIND=network
      return 1
    fi
    wait_s=${backoff[attempt - 1]}
    log_warn "discord: attempt $attempt failed ($DISCORD_LAST_ERROR), retrying in ${wait_s}s"
    if ! discord_wait "$wait_s"; then
      DISCORD_LAST_KIND=deadline
      return 1
    fi
  done
}

# discord_validate: GET the webhook; valid = HTTP 200 with a JSON id. The body holds the token,
# so only the webhook's name is kept (DISCORD_WEBHOOK_NAME) and nothing else is ever printed.
discord_validate() {
  local body="$SCREENLOG_TMP/curl.body" rc=0
  DISCORD_LAST_ERROR=""
  DISCORD_WEBHOOK_NAME=""
  discord_curl "$body" -X GET || rc=$?
  if (( rc != 0 )); then
    DISCORD_LAST_ERROR="curl exit $rc: $(log_redact_str "$(head -n1 "$SCREENLOG_TMP/curl.err" 2>/dev/null)")"
    return 1
  fi
  if [[ $DISCORD_LAST_HTTP != 200 ]]; then
    DISCORD_LAST_ERROR="HTTP $DISCORD_LAST_HTTP"
    return 1
  fi
  if ! jq -e '.id' "$body" > /dev/null 2>&1; then
    DISCORD_LAST_ERROR="HTTP 200 but no webhook object in the response"
    return 1
  fi
  DISCORD_WEBHOOK_NAME=$(jq -r '.name // ""' "$body" 2>/dev/null)
}

# discord_prepare_image SRC DST: a copy at most 960 px wide for single-image posts (spec 5.7).
# No jpeg:size read hint here: it makes libjpeg upscale sources smaller than the hint.
discord_prepare_image() {
  convert "$1" -resize '960x>' -strip -quality 80 "jpeg:$2"
}
