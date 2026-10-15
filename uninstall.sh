#!/usr/bin/env bash
# uninstall.sh - remove screenlog from this PC (spec section 9). Also installed as
# /opt/screenlog/uninstall.sh. Stops and removes the units, the app and the CLI link, restores the
# GDM and release-upgrades files from their backups, keeps the config and data unless --purge is
# given, and never touches Google Drive.
#
#   sudo /opt/screenlog/uninstall.sh [--purge] [--dry-run]
set -euo pipefail
set -E
export LC_ALL=C.UTF-8
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd) || exit 1
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

OPT_PURGE=0
OPT_DRY=0
STEP="start"

trap 'log_error "uninstall failed during step '"'"'$STEP'"'"' (line $LINENO)"; exit "$EXIT_RUNTIME"' ERR

usage() {
  cat <<USAGE
Usage: sudo $0 [--purge] [--dry-run]
  --purge     also remove $SCREENLOG_CONFIG's folder (config, Drive token) and the local screenshots
  --dry-run   print what would be done without changing anything
USAGE
}

run() {
  if (( OPT_DRY )); then
    printf 'would:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

say() { printf '%s\n' "$*"; }

ul_stop_units() {
  STEP="stop units"
  run systemctl disable --now screenlog-report.timer screenlog.service || true
  run systemctl stop screenlog-report.service || true
  say "units stopped and disabled"
}

ul_remove_units() {
  STEP="remove units"
  local u
  for u in screenlog.service screenlog-report.service screenlog-report.timer; do
    if [[ -e $PATH_UNIT_DIR/$u ]]; then
      run rm -f -- "$PATH_UNIT_DIR/$u"
      say "removed $PATH_UNIT_DIR/$u"
    fi
    if [[ -d $PATH_UNIT_DIR/$u.d ]]; then
      say "note: $PATH_UNIT_DIR/$u.d (your drop-ins) was left in place"
    fi
  done
  run systemctl daemon-reload || true
  run systemctl reset-failed screenlog.service screenlog-report.service || true
}

ul_remove_symlink() {
  STEP="remove CLI link"
  if [[ -L $PATH_CLI_LINK && $(readlink "$PATH_CLI_LINK") == "$PATH_APP_DIR/bin/screenlog" ]]; then
    run rm -f -- "$PATH_CLI_LINK"
    say "removed $PATH_CLI_LINK"
  elif [[ -e $PATH_CLI_LINK ]]; then
    say "note: $PATH_CLI_LINK is not screenlog's link; left in place"
  fi
}

ul_remove_app() {
  STEP="remove app"
  local d
  for d in "$PATH_APP_DIR" "$PATH_APP_DIR.old" "$PATH_APP_DIR".new.*; do
    if [[ -e $d ]]; then
      run rm -rf -- "$d"
      say "removed $d"
    fi
  done
}

ul_restore_backups() {
  STEP="restore system files"
  local f
  for f in "$PATH_GDM_CONF" "$PATH_RELEASE_UPGRADES"; do
    if [[ -e $f.screenlog-bak ]]; then
      run mv -f -- "$f.screenlog-bak" "$f"
      say "restored $f from ${f##*/}.screenlog-bak (takes effect at the next login / update check)"
    else
      say "no backup for $f; left unchanged"
    fi
  done
}

ul_handle_data() {
  STEP="data"
  if (( OPT_PURGE )); then
    run rm -rf -- "$PATH_ETC_DIR" "$SCREENLOG_DATA_DIR"
    say "removed $PATH_ETC_DIR (config, Drive token) and $SCREENLOG_DATA_DIR (local screenshots, state)"
  else
    say "kept $PATH_ETC_DIR and $SCREENLOG_DATA_DIR (add --purge to remove them)"
  fi
}

main() {
  while (($#)); do
    case $1 in
      --purge) OPT_PURGE=1; shift ;;
      --dry-run) OPT_DRY=1; shift ;;
      -h|--help) paths_init; usage; exit 0 ;;
      *) paths_init; usage >&2; die "$EXIT_USAGE" "unknown option: $1" ;;
    esac
  done
  if (( EUID != 0 )); then die "$EXIT_ROOT" "uninstall.sh must run as root: sudo $0"; fi
  paths_init
  cd /
  if (( OPT_DRY )); then say "[dry-run] nothing is changed"; fi
  ul_stop_units
  ul_remove_units
  ul_remove_symlink
  ul_remove_app
  ul_restore_backups
  ul_handle_data
  say "Nothing in Google Drive was touched. The apt packages (ffmpeg, rclone, imagemagick, ...) were left installed."
  say "screenlog is uninstalled."
}

if [[ -z ${SCREENLOG_UNINSTALL_NO_MAIN:-} ]]; then
  main "$@"
fi
