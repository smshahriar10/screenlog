#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup() { screenlog_test_setup; config_load; }

# check_draws FILE LO HI EXPECTED: every draw is an integer in [LO,HI]; mean within 5% of EXPECTED.
check_draws() {
  awk -v lo="$2" -v hi="$3" -v e="$4" '
    $1 !~ /^[0-9]+$/ || $1 < lo || $1 > hi { bad = 1; print "bad draw: " $0 }
    { s += $1; n++ }
    END {
      m = s / n
      printf "n=%d mean=%.1f expected=%.1f\n", n, m, e
      exit (bad || m < 0.95 * e || m > 1.05 * e)
    }' "$1"
}

@test "gap: 10000 draws stay within bounds and the mean is within 5% of the clamped expectation" {
  local expected
  expected=$(gap_expected_mean 7 60 1800)
  gap_draw 10000 > "$BATS_TEST_TMPDIR/draws"
  assert_equal "$(wc -l < "$BATS_TEST_TMPDIR/draws")" 10000
  run check_draws "$BATS_TEST_TMPDIR/draws" 60 1800 "$expected"
  assert_success
}

@test "gap: the closed-form expectation for the defaults is about 502 s" {
  run gap_expected_mean 7 60 1800
  assert_output --regexp '^50[0-4]\.'
}

@test "gap: heavy clamping (400..600) still matches the clamped expectation" {
  local expected
  expected=$(gap_expected_mean 7 400 600)
  gap_draw 10000 7 400 600 > "$BATS_TEST_TMPDIR/draws"
  run check_draws "$BATS_TEST_TMPDIR/draws" 400 600 "$expected"
  assert_success
}

@test "gap: MIN = MAX gives that value every time" {
  run gap_draw 50 7 300 300
  assert_success
  assert_equal "$(sort -u <<< "$output")" "300"
}

@test "gap: successive calls are not identical (seeded from /dev/urandom)" {
  local a b
  a=$(gap_draw 200 7 1 100000)
  b=$(gap_draw 200 7 1 100000)
  [ "$a" != "$b" ]
}

@test "gap: SCREENLOG_SEED makes draws reproducible" {
  local a b
  a=$(SCREENLOG_SEED=42 gap_draw 20)
  b=$(SCREENLOG_SEED=42 gap_draw 20)
  assert_equal "$a" "$b"
}

@test "gap: gap_next prints one integer inside the bounds" {
  run gap_next
  assert_success
  assert_output --regexp '^[0-9]+$'
  (( output >= 60 && output <= 1800 ))
}

@test "gap: gap_next falls back to MIN_GAP_SECONDS when awk fails" {
  SHOTS_PER_HOUR=0
  run gap_next
  assert_success
  assert_output "60"
}

@test "gap: the generator never uses \$RANDOM and seeds from /dev/urandom" {
  # shellcheck disable=SC2016
  run grep -n '\$RANDOM' "$REPO_ROOT/lib/gap.sh"
  assert_failure
  run grep -c '/dev/urandom' "$REPO_ROOT/lib/gap.sh"
  assert_success
}
