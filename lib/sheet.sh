# shellcheck shell=bash
# lib/sheet.sh - the daily contact sheet (spec 5.6) with ImageMagick 6.
# One full-size decode at a time, DCT-scaled with jpeg:size; tile paths go on the command line
# (Debian's policy forbids @file lists); fonts are given as files, not fontconfig names.
# shellcheck disable=SC2034  # SHEET_* are read by the report
if [[ -n ${_SCREENLOG_SHEET_SH:-} ]]; then return 0; fi
_SCREENLOG_SHEET_SH=1

SHEET_ACTIVE_BG='#2e7d32'
SHEET_ACTIVE_FG='white'
SHEET_IDLE_BG='#f9a825'
SHEET_IDLE_FG='black'
SHEET_CANVAS='#181818'
SHEET_BAR=22
SHEET_HEADER=48
SHEET_GAP=4
SHEET_COLS=6
SHEET_SIZE=0

# sheet_caption IDLE_SECONDS HH:MM -> "HH:MM · active" or "HH:MM · idle 14m"
sheet_caption() {
  if (( ${1:-0} < IDLE_THRESHOLD_SECONDS )); then
    printf '%s · active\n' "$2"
  else
    printf '%s · idle %dm\n' "$2" $(( $1 / 60 ))
  fi
}

# sheet_render DAY CSV OUT TW MANIFEST: one rendering at tile width TW. Prints nothing; returns 1
# when the CSV has no shot rows. The manifest (TSV) lists the header and every tile with the
# rectangle of its caption bar, so tests can verify captions and colours independently.
sheet_render() {
  local day=$1 csv=$2 out=$3 tw=$4 manifest=$5
  local daydir="$SHOTS_DIR/$day" tiles th i=0 n ts idle file hhmm cap bg fg cols rows w h x y r c
  local title shots active pct
  th=$(( tw * 9 / 16 ))
  tiles="$SCREENLOG_TMP/tiles-$day"
  rm -rf -- "$tiles"
  mkdir -p -- "$tiles"
  shots=0; active=0
  while IFS=, read -r ts _ idle file _; do
    [[ -n $file ]] || continue
    shots=$((shots + 1))
    hhmm=${ts:11:5}
    if (( ${idle:-0} < IDLE_THRESHOLD_SECONDS )); then
      active=$((active + 1)); bg=$SHEET_ACTIVE_BG; fg=$SHEET_ACTIVE_FG
    else
      bg=$SHEET_IDLE_BG; fg=$SHEET_IDLE_FG
    fi
    cap=$(sheet_caption "${idle:-0}" "$hhmm")
    i=$((i + 1))
    if ! convert -define "jpeg:size=$((tw * 2))x$((th * 2))" "$daydir/$file" \
        -thumbnail "${tw}x${th}" -background black -gravity center -extent "${tw}x${th}" \
        \( -size "${tw}x${SHEET_BAR}" -background "$bg" -fill "$fg" -font "$PATH_FONT" -pointsize 13 \
           -gravity west label:"  $cap" \) -append -quality 85 "jpeg:$tiles/$(printf '%04d' "$i").jpg" 2>/dev/null; then
      convert -size "${tw}x${th}" xc:'#444444' \
        \( -size "${tw}x${SHEET_BAR}" -background "$bg" -fill "$fg" -font "$PATH_FONT" -pointsize 13 \
           -gravity west label:"  $cap" \) -append -quality 85 "jpeg:$tiles/$(printf '%04d' "$i").jpg"
    fi
    printf '%s\t%s\t%s\n' "$file" "$cap" "$bg" >> "$tiles/index.tsv"
  done < <(awk -F, 'NR > 1 && $2 == "shot" && $4 != ""' "$csv")
  n=$i
  (( n > 0 )) || return 1
  cols=$SHEET_COLS
  (( n < cols )) && cols=$n
  rows=$(( (n + cols - 1) / cols ))
  w=$(( cols * (tw + 2 * SHEET_GAP) ))
  pct=$(( (active * 100 + shots / 2) / shots ))
  title="  $EMPLOYEE_NAME · $(time_day_human "$day") · $shots shots · ${pct}% active"
  montage "$tiles"/0*.jpg -tile "${cols}x" -geometry "+${SHEET_GAP}+${SHEET_GAP}" -background "$SHEET_CANVAS" "$tiles/body.png" || return 2
  convert -size "${w}x${SHEET_HEADER}" -background "$SHEET_CANVAS" -fill white -font "$PATH_FONT_BOLD" \
    -pointsize 20 -gravity west label:"$title" "$tiles/header.png" || return 2
  convert "$tiles/header.png" "$tiles/body.png" -append -quality 85 "jpeg:$out" || return 2
  if [[ -n $manifest ]]; then
    h=$(( rows * (th + SHEET_BAR + 2 * SHEET_GAP) + SHEET_HEADER ))
    {
      printf '0\t-\t%s\theader\t0\t0\t%s\t%s\n' "${title#  }" "$w" "$SHEET_HEADER"
      i=0
      while IFS=$'\t' read -r file cap bg; do
        r=$(( i / cols )); c=$(( i % cols ))
        x=$(( SHEET_GAP + c * (tw + 2 * SHEET_GAP) ))
        y=$(( SHEET_HEADER + SHEET_GAP + r * (th + SHEET_BAR + 2 * SHEET_GAP) + th ))
        i=$((i + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$file" "$cap" "$([[ $bg == "$SHEET_ACTIVE_BG" ]] && echo active || echo idle)" "$x" "$y" "$tw" "$SHEET_BAR"
      done < "$tiles/index.tsv"
    } > "$manifest"
    : "$h"
  fi
  return 0
}

# sheet_build DAY CSV OUT [MANIFEST]: render, then shrink the tiles by 20% per round until the
# JPEG fits SCREENLOG_MAX_SHEET_BYTES (8 MB). Returns 1 without shots, 2 when it cannot fit even
# with 120 px tiles (the report then posts without an attachment).
sheet_build() {
  local day=$1 csv=$2 out=$3 manifest=${4:-} tw=${SCREENLOG_TILE_WIDTH:-320} max=${SCREENLOG_MAX_SHEET_BYTES:-8388608} rc tmp
  SHEET_SIZE=0
  # a dot-prefixed temp file in the target folder: rclone copy excludes '.*', and mv stays atomic
  tmp=$(mktemp -p "${out%/*}" .contact-sheet.XXXXXX) || return 2
  while (( tw >= 120 )); do
    rc=0
    sheet_render "$day" "$csv" "$tmp" "$tw" "$manifest" || rc=$?
    if (( rc != 0 )); then
      rm -f -- "$tmp"
      return "$rc"
    fi
    SHEET_SIZE=$(stat -c %s "$tmp")
    if (( SHEET_SIZE <= max )); then
      mv -f -- "$tmp" "$out"
      return 0
    fi
    log_info "sheet: $SHEET_SIZE bytes exceed $max, shrinking tiles from ${tw}px"
    tw=$(( tw * 4 / 5 ))
  done
  rm -f -- "$tmp"
  return 2
}
