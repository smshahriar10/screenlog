#!/usr/bin/env bats
# shellcheck source=tests/helpers/common.bash
source "$BATS_TEST_DIRNAME/../helpers/common.bash"

check_slug() {
  run slug_from_name "$1"
  assert_success
  assert_output "$2"
}

@test "slug: plain names" {
  check_slug "Rahim Uddin" "rahim-uddin"
  check_slug "  Rahim   Uddin  " "rahim-uddin"
  check_slug "ABC123" "abc123"
  check_slug "a" "a"
  check_slug "Jean-Luc_Picard" "jean-luc-picard"
  check_slug "O'Brien, Jr." "o-brien-jr"
}

@test "slug: accented and special Latin letters are transliterated" {
  check_slug "Émile Zola" "emile-zola"
  check_slug "José Ñandú" "jose-nandu"
  check_slug "Łukasz Müller" "lukasz-muller"
  check_slug "Straße Æsir" "strasse-aesir"
}

@test "slug: long names are capped at 64 characters without a trailing hyphen" {
  local name
  name=$(printf 'Abcdefghi %.0s' {1..12})
  run slug_from_name "$name"
  assert_success
  (( ${#output} <= 64 ))
  [[ $output != *- ]]
}

@test "slug: names without ASCII letters give no slug and return 1" {
  local name
  for name in "রহিম উদ্দিন" "123 456" "" "---" "日本語"; do
    run slug_from_name "$name"
    assert_failure
    assert_output ""
  done
}

@test "slug: slugifying a slug is a fixed point" {
  local s
  s=$(slug_from_name "José Ñandú")
  check_slug "$s" "$s"
}
