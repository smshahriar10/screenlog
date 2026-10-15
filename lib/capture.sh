# shellcheck shell=bash
# lib/capture.sh - one x11grab frame to a JPEG, and the samples.csv writer (spec 5.3 steps 5-6).
# shellcheck disable=SC2034  # CAPTURE_ERROR is read by sample.sh
if [[ -n ${_SCREENLOG_CAPTURE_SH:-} ]]; then return 0; fi
_SCREENLOG_CAPTURE_SH=1

CAPTURE_ERROR=""

# capture_qscale JPEG_QUALITY -> ffmpeg mjpeg -q:v (1 best .. 31 worst). ffmpeg's encoder has no
# libjpeg quality scale, so this mapping is approximate; 85 -> 3 keeps code text legible.
capture_qscale() {
  local q=$1
  if   (( q >= 95 )); then echo 1
  elif (( q >= 90 )); then echo 2
  elif (( q >= 85 )); then echo 3
  elif (( q >= 80 )); then echo 4
  elif (( q >= 75 )); then echo 5
  elif (( q >= 70 )); then echo 6
  elif (( q >= 60 )); then echo 8
  elif (( q >= 50 )); then echo 10
  elif (( q >= 40 )); then echo 13
  elif (( q >= 30 )); then echo 16
  elif (( q >= 20 )); then echo 20
  else echo 25
  fi
}

# capture_jpeg_ok FILE: non-empty and starts with the JPEG magic bytes.
capture_jpeg_ok() {
  [[ -s $1 ]] && [[ $(od -An -tx1 -N3 "$1" | tr -d ' \n') == ffd8ff ]]
}

# capture_take OUT.jpg: grab the root window of SESSION_DISPLAY (all monitors, cursor included),
# downscale only when taller than MAX_HEIGHT, write a JPEG through a dot-prefixed temp file and an
# atomic rename. Return 1 with CAPTURE_ERROR set. No -video_size (x11grab defaults to the full
# root) and no -framerate (a frame rate makes x11grab wait one interval before the first frame).
capture_take() {
  local out=$1 dir tmp rc qv h errf
  CAPTURE_ERROR=""
  dir=${out%/*}
  tmp=$(mktemp -p "$dir" .capture.XXXXXX) || { CAPTURE_ERROR="mktemp failed in $dir"; return 1; }
  qv=$(capture_qscale "$JPEG_QUALITY")
  h=$MAX_HEIGHT
  errf="${SCREENLOG_TMP:-/tmp}/ffmpeg.err"
  session_xenv "$SESSION_DISPLAY" "$SESSION_XAUTHORITY"
  if run_child env "${XENV[@]}" timeout -k 3 "${SCREENLOG_CAPTURE_TIMEOUT:-15}" \
      ffmpeg -nostdin -hide_banner -loglevel error -threads 1 -filter_threads 1 \
      -f x11grab -draw_mouse 1 -i "$SESSION_DISPLAY" -frames:v 1 \
      -vf "scale=w='trunc(iw*min(1,$h/ih)/2)*2':h='trunc(min(ih,$h)/2)*2':flags=area" \
      -c:v mjpeg -pix_fmt yuvj444p -q:v "$qv" -f image2 -update 1 -y "$tmp" 2> "$errf"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 124 || rc == 137 )); then
    CAPTURE_ERROR="ffmpeg timeout"
  elif (( rc != 0 )); then
    CAPTURE_ERROR="ffmpeg exit $rc: $(log_redact_str "$(head -n1 "$errf" 2>/dev/null)")"
    CAPTURE_ERROR=${CAPTURE_ERROR:0:120}
  elif ! capture_jpeg_ok "$tmp"; then
    CAPTURE_ERROR="ffmpeg wrote no JPEG"
  fi
  if [[ -n $CAPTURE_ERROR ]]; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$out"
}

csv_path() { printf '%s/%s/samples.csv\n' "$SHOTS_DIR" "$1"; }

# csv_sanitize TEXT: the detail column must never contain commas or line breaks.
csv_sanitize() {
  local s=$1
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  s=${s//,/;}
  printf '%s' "$s"
}

# csv_append FILE TIMESTAMP STATUS IDLE SHOTFILE DETAIL: create the header on first use.
csv_append() {
  local f=$1
  mkdir -p -- "${f%/*}" || return 1
  if [[ ! -s $f ]]; then
    printf 'timestamp,status,idle_seconds,file,detail\n' > "$f" || return 1
  fi
  printf '%s,%s,%s,%s,%s\n' "$2" "$3" "$4" "$5" "$(csv_sanitize "$6")" >> "$f"
}
