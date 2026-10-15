#!/usr/bin/env bats
# Real frames from Xvfb -> report --dry-run -> contact sheet (spec 5.6 and 11).
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"
# shellcheck source=tests/helpers/xvfb.bash
source "$BATS_TEST_DIRNAME/../helpers/xvfb.bash"

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  start_xvfb 1920x1200x24
  export SCREENLOG_TEST_BASE_DIR="$BATS_FILE_TMPDIR/filesetup"
  screenlog_test_setup
  load_xvfb_env
  use_stubs hostname rclone
  xprintidle_or_stub
  mkdir -p "$BATS_FILE_TMPDIR/frames"
  local seed t
  for seed in 1 2 3; do
    paint_root "$seed"
    t="2026-10-15T10:0$seed:00+06:00"
    SCREENLOG_NOW=$t screenlogd --once > /dev/null
    cp "$SCREENLOG_DATA_DIR/shots/2026-10-15/10-0$seed-00.jpg" "$BATS_FILE_TMPDIR/frames/$seed.jpg"
  done
  identify -list policy | grep -E 'width|height|memory|area' | sed 's/^/# policy: /' >&3 || true
  test -r /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
}

teardown_file() { stop_xvfb; }

setup() {
  screenlog_test_setup
  use_stubs hostname curl rclone
  make_day 2026-10-15 day-normal.csv
  # replace the tiny placeholder JPEGs with real frames, cycling through the three captures
  local i=0 f
  while IFS= read -r f; do
    i=$((i + 1))
    cp "$BATS_FILE_TMPDIR/frames/$(( i % 3 + 1 )).jpg" "$SCREENLOG_DATA_DIR/shots/2026-10-15/$f"
  done < <(awk -F, 'NR > 1 && $2 == "shot" { print $4 }' "$SCREENLOG_DATA_DIR/shots/2026-10-15/samples.csv")
  set_now "2026-10-15T17:45:00+06:00"
}

crop_stats() {   # crop_stats SHEET X Y W H -> "r g b sd" of that rectangle
  convert "$1" -crop "${4}x${5}+${2}+${3}" +repage -format '%[fx:mean.r] %[fx:mean.g] %[fx:mean.b] %[fx:standard_deviation]' info:
}

@test "sheet: the dry run builds a JPEG contact sheet of at most 8 MB with a header and captions" {
  run screenlog report --dry-run --date 2026-10-15
  assert_success
  local dir sheet size w h
  dir=$(sed -n 's/^dry-run dir: //p' <<< "$output")
  sheet="$dir/contact-sheet.jpg"
  assert_file_exists "$sheet"
  size=$(stat -c %s "$sheet")
  (( size <= 8388608 ))
  run identify -format '%m %w %h' "$sheet"
  read -r _ w h <<< "$output"
  (( w > 0 && w <= 4000 && h > 0 && h <= 16000 ))
  echo "# contact sheet: ${size} bytes, ${w}x${h}" >&3
  assert_equal "$(stub_calls curl)" 0
  assert_equal "$(stub_calls rclone)" 0
  # manifest: header + 58 tiles in time order, 9 idle
  assert_equal "$(grep -c '' "$dir/tiles.tsv")" 59
  run sed -n '1p' "$dir/tiles.tsv"
  assert_output --partial $'\tRahim Uddin · Thu 15 Oct 2026 · 58 shots · 84% active\theader\t'
  run sed -n '2p' "$dir/tiles.tsv"
  assert_output --partial $'09-12-33.jpg\t09:12 · active\tactive\t'
  assert_equal "$(grep -c $'\tidle\t' "$dir/tiles.tsv")" 9
  run grep -c $'· idle [0-9]*m\tidle' "$dir/tiles.tsv"
  assert_output 9
  # colours of the first active and the first idle caption bar, and text in both
  local x y tw th r g b sd
  IFS=$'\t' read -r _ _ _ _ x y tw th < <(grep -m1 $'\tactive\t' "$dir/tiles.tsv")
  read -r r g b sd <<< "$(crop_stats "$sheet" "$x" "$y" "$tw" "$th")"
  awk -v r="$r" -v g="$g" -v b="$b" -v sd="$sd" 'BEGIN { exit !(g > r && g > b && sd > 0.02) }'
  IFS=$'\t' read -r _ _ _ _ x y tw th < <(grep -m1 $'\tidle\t' "$dir/tiles.tsv")
  read -r r g b sd <<< "$(crop_stats "$sheet" "$x" "$y" "$tw" "$th")"
  awk -v r="$r" -v g="$g" -v b="$b" -v sd="$sd" 'BEGIN { exit !(r > b && g > b && r > 0.6 && sd > 0.02) }'
  IFS=$'\t' read -r _ _ _ _ x y tw th < <(sed -n '1p' "$dir/tiles.tsv")
  read -r r g b sd <<< "$(crop_stats "$sheet" "$x" "$y" "$tw" "$th")"
  awk -v sd="$sd" 'BEGIN { exit !(sd > 0.02) }'
  # the thumbnail above the first caption bar is a real frame, not black
  IFS=$'\t' read -r _ _ _ _ x y tw th < <(sed -n '2p' "$dir/tiles.tsv")
  read -r r g b sd <<< "$(crop_stats "$sheet" "$x" $(( y - tw * 9 / 16 )) "$tw" $(( tw * 9 / 16 )))"
  awk -v sd="$sd" 'BEGIN { exit !(sd > 0.05) }'
}

@test "sheet: the size cap shrinks the tiles, and an impossible cap posts the text without a sheet" {
  local dir size1 size2 w1 w2
  run screenlog report --dry-run --date 2026-10-15
  assert_success
  dir=$(sed -n 's/^dry-run dir: //p' <<< "$output")
  size1=$(stat -c %s "$dir/contact-sheet.jpg")
  w1=$(identify -format '%w' "$dir/contact-sheet.jpg")
  SCREENLOG_MAX_SHEET_BYTES=$(( size1 / 2 )) run screenlog report --dry-run --date 2026-10-15
  assert_success
  assert_output --partial "shrinking tiles"
  dir=$(sed -n 's/^dry-run dir: //p' <<< "$output")
  size2=$(stat -c %s "$dir/contact-sheet.jpg")
  w2=$(identify -format '%w' "$dir/contact-sheet.jpg")
  (( size2 <= size1 / 2 && w2 < w1 ))
  SCREENLOG_MAX_SHEET_BYTES=1000 run screenlog report --dry-run --date 2026-10-15
  assert_success
  dir=$(sed -n 's/^dry-run dir: //p' <<< "$output")
  assert_file_not_exists "$dir/contact-sheet.jpg"
  run jq -r '.content' "$dir/message.json"
  assert_line "⚠️ Contact sheet too large to attach"
}

@test "sheet: the posted attachment is the sheet and stays under 8 MB" {
  run screenlog report --pending
  assert_success
  run curl_attach
  assert_output --regexp '^1 .*/contact-sheet\.jpg [0-9]+$'
  local bytes
  bytes=$(awk '{print $3}' "$STUB_LOG_DIR/curl.attach")
  (( bytes <= 8388608 ))
  run identify -format '%m' "$STUB_LOG_DIR/curl.attach.1"
  assert_output JPEG
}

@test "sheet: a report run stays within the in-VM memory and time bounds" {
  run env MAGICK_THREAD_LIMIT=1 /usr/bin/time -f '%e %M' -o "$BATS_TEST_TMPDIR/t" screenlog report --dry-run --date 2026-10-15
  assert_success
  read -r wall rss < "$BATS_TEST_TMPDIR/t"
  echo "# report --dry-run: wall=${wall}s maxrss=${rss}kB" >&3
  awk -v w="$wall" -v m="$rss" 'BEGIN { exit !(w < 60 && m < 300000) }'
}
