# shellcheck shell=bash
# lib/system.sh - small system helpers shared by install.sh, uninstall.sh and doctor.
# shellcheck disable=SC2034  # INI_CHANGED is read by install.sh
if [[ -n ${_SCREENLOG_SYSTEM_SH:-} ]]; then return 0; fi
_SCREENLOG_SYSTEM_SH=1

INI_CHANGED=0

# ini_get_key FILE SECTION KEY: the active (uncommented) value, or return 1.
ini_get_key() {
  [[ -r $1 ]] || return 1
  awk -v sec="$2" -v key="$3" '
    /^[[:space:]]*\[/ { insec = ($0 ~ ("^[[:space:]]*\\[" sec "\\][[:space:]]*$")); next }
    insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; found = 1; exit }
    END { exit !found }' "$1"
}

# ini_set_key FILE SECTION KEY VALUE: idempotent edit. Uncomments or replaces the key inside
# the section, adds it (and the section) when missing, drops later active duplicates. Backs the
# original up once to FILE.screenlog-bak; a no-op leaves the file untouched. Sets INI_CHANGED.
ini_set_key() {
  local file=$1 sec=$2 key=$3 val=$4 tmp
  INI_CHANGED=0
  if [[ ! -e $file ]]; then
    : > "$file" || return 1
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  awk -v sec="$sec" -v key="$key" -v val="$val" '
    function emit() { print key "=" val; done = 1 }
    /^[[:space:]]*\[/ {
      if (insec && !done) emit()
      insec = ($0 ~ ("^[[:space:]]*\\[" sec "\\][[:space:]]*$")); print; next }
    insec && $0 ~ ("^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
      if (!done) { emit(); next }
      if ($0 !~ /^[[:space:]]*#/) next
      print; next }
    { print }
    END { if (!done) { if (!insec) { if (NR > 0) print ""; print "[" sec "]" } emit() } }' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if cmp -s "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 0
  fi
  if [[ ! -e $file.screenlog-bak ]]; then
    cp -p -- "$file" "$file.screenlog-bak" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  mv -f -- "$tmp" "$file" || return 1
  INI_CHANGED=1
}

# version_ge ACTUAL MIN: dotted version comparison.
version_ge() {
  [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]
}

# rclone_version -> "1.60.1" (empty when rclone is missing or unparsable).
rclone_version() {
  local line
  line=$(rclone version 2>/dev/null | head -n1) || true
  if [[ $line =~ v([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

pkg_installed() {
  [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]
}

# os_field KEY: a field of /etc/os-release without sourcing it.
os_field() {
  awk -F= -v k="$1" '$1 == k { v = $2; gsub(/"/, "", v); print v; exit }' "$PATH_OS_RELEASE" 2>/dev/null
}

# system_arch: dpkg's architecture (SCREENLOG_ARCH overrides it for tests on arm64 hosts).
system_arch() {
  if [[ -n ${SCREENLOG_ARCH:-} ]]; then
    printf '%s\n' "$SCREENLOG_ARCH"
  else
    dpkg --print-architecture 2>/dev/null || uname -m
  fi
}

# iec_or_na BYTES: human size, or n/a when systemd answers "[not set]".
iec_or_na() {
  if [[ $1 =~ ^[0-9]+$ ]]; then numfmt --to=iec "$1"; else printf 'n/a\n'; fi
}

# disk_free_mb PATH: free space on PATH's filesystem in MB.
disk_free_mb() {
  df --output=avail -BM "$1" 2>/dev/null | tail -n1 | tr -dc '0-9'
}
