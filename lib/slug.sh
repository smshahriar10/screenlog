# shellcheck shell=bash
# lib/slug.sh - EMPLOYEE_SLUG from EMPLOYEE_NAME (spec section 4 / 9).
# Locale-independent on purpose: the slug names a permanent Drive folder, so it must not depend on
# which locales a PC has generated (iconv //TRANSLIT does). A fixed table transliterates common
# Latin letters; anything else non-ASCII is dropped. Names without ASCII letters yield no slug.
if [[ -n ${_SCREENLOG_SLUG_SH:-} ]]; then return 0; fi
_SCREENLOG_SLUG_SH=1

SLUG_TRANSLIT=(
  à:a á:a â:a ã:a ä:a å:a æ:ae ç:c è:e é:e ê:e ë:e ì:i í:i î:i ï:i ð:d ñ:n
  ò:o ó:o ô:o õ:o ö:o ø:o ù:u ú:u û:u ü:u ý:y þ:th ÿ:y ß:ss
  ā:a ă:a ą:a ć:c č:c ď:d đ:d ē:e ė:e ę:e ě:e ğ:g ī:i ı:i ł:l ń:n ň:n ő:o œ:oe
  ř:r ś:s ş:s š:s ť:t ū:u ů:u ű:u ź:z ż:z ž:z
)

# slug_from_name NAME: print the slug, or print nothing and return 1 when NAME has no ASCII letter.
slug_from_name() {
  local s=${1,,} pair
  for pair in "${SLUG_TRANSLIT[@]}"; do
    s=${s//"${pair%%:*}"/${pair#*:}}
  done
  s=$(printf '%s' "$s" | LC_ALL=C tr -cd '\40-\176')
  s=$(printf '%s' "$s" | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  s=${s:0:64}
  s=${s%%-}
  if [[ ! $s =~ [a-z] ]]; then
    return 1
  fi
  printf '%s\n' "$s"
}
