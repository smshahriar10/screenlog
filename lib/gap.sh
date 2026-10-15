# shellcheck shell=bash
# lib/gap.sh - random gaps between samples (spec section 5.2).
# Each gap is drawn from an exponential distribution with mean 3600/SHOTS_PER_HOUR seconds and
# clamped to [MIN_GAP_SECONDS, MAX_GAP_SECONDS]. The awk generator is seeded from /dev/urandom
# (SCREENLOG_SEED overrides it for reproducible tests); the shell's built-in random variable is never used.
if [[ -n ${_SCREENLOG_GAP_SH:-} ]]; then return 0; fi
_SCREENLOG_GAP_SH=1

# gap_draw [N] [SHOTS_PER_HOUR] [MIN] [MAX]: print N integer gaps, one per line. Returns 1 and
# prints nothing when an argument is not a usable positive integer.
# The generator is a Park-Miller "minimal standard" LCG written in awk, so draws are identical for
# a given seed on every awk implementation (mawk's srand() is not repeatable across runs).
gap_draw() {
  local n=${1:-1} sph=${2:-$SHOTS_PER_HOUR} lo=${3:-$MIN_GAP_SECONDS} hi=${4:-$MAX_GAP_SECONDS} seed
  if [[ ! $n =~ ^[0-9]+$ || ! $sph =~ ^[0-9]+$ || ! $lo =~ ^[0-9]+$ || ! $hi =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( sph < 1 || lo < 1 || hi < lo )); then
    return 1
  fi
  seed=${SCREENLOG_SEED:-$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}
  if [[ ! $seed =~ ^[0-9]+$ ]]; then
    return 1
  fi
  awk -v n="$n" -v sph="$sph" -v lo="$lo" -v hi="$hi" -v seed="$seed" 'BEGIN {
    m = 2147483647
    x = (seed % (m - 1)) + 1
    mean = 3600 / sph
    for (i = 0; i < n; i++) {
      x = (16807 * x) % m
      u = x / m
      g = int(-mean * log(u) + 0.5)
      if (g < lo) g = lo
      if (g > hi) g = hi
      print g
    }
  }'
}

# gap_next: one gap for the daemon loop; falls back to MIN_GAP_SECONDS if awk ever fails.
gap_next() {
  local g
  g=$(gap_draw 1 2>/dev/null) || g=""
  if [[ ! $g =~ ^[0-9]+$ ]]; then
    g=$MIN_GAP_SECONDS
  fi
  printf '%s\n' "$g"
}

# gap_expected_mean SHOTS_PER_HOUR MIN MAX: closed-form mean of the clamped distribution
# (used by the tests): E = lo + mu * (exp(-lo/mu) - exp(-hi/mu)).
gap_expected_mean() {
  awk -v sph="$1" -v lo="$2" -v hi="$3" 'BEGIN {
    mu = 3600 / sph
    printf "%.3f\n", lo + mu * (exp(-lo / mu) - exp(-hi / mu))
  }'
}
