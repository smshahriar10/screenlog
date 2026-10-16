#!/usr/bin/env bash
# install.sh - install or upgrade screenlog on this PC (spec section 9). Idempotent: re-running
# it upgrades in place and keeps the employee name, slug, state and refreshed Drive tokens.
#
#   sudo bash ./install.sh --name "Rahim Uddin" [--slug rahim-uddin] [--reboot] [--dry-run]
#                          [--force] [--reannounce]
set -euo pipefail
set -E
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
umask 077
BUNDLE_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd) || exit 1
readonly BUNDLE_DIR
# shellcheck source=lib/log.sh
. "$BUNDLE_DIR/lib/log.sh"
# shellcheck source=lib/config.sh
. "$BUNDLE_DIR/lib/config.sh"
# shellcheck source=lib/time.sh
. "$BUNDLE_DIR/lib/time.sh"
# shellcheck source=lib/slug.sh
. "$BUNDLE_DIR/lib/slug.sh"
# shellcheck source=lib/session.sh
. "$BUNDLE_DIR/lib/session.sh"
# shellcheck source=lib/drive.sh
. "$BUNDLE_DIR/lib/drive.sh"
# shellcheck source=lib/discord.sh
. "$BUNDLE_DIR/lib/discord.sh"
# shellcheck source=lib/units.sh
. "$BUNDLE_DIR/lib/units.sh"
# shellcheck source=lib/system.sh
. "$BUNDLE_DIR/lib/system.sh"

# The exact apt list (spec 9.2 plus jq, used for lsjson and the Discord payload, and
# libglib2.0-bin for gdbus). tests/Dockerfile mirrors it; a guard test keeps them equal.
APT_PACKAGES="ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core rclone jq libglib2.0-bin"
RCLONE_MIN_VERSION=1.60.0

OPT_NAME=""; OPT_SLUG=""; OPT_REBOOT=0; OPT_DRY=0; OPT_FORCE=0; OPT_REANNOUNCE=0
STEP="start"
MODE=""
BUNDLE_VERSION=""; INSTALLED_VERSION=""
BUNDLE_CONF=""; BUNDLE_RCLONE=""
STOPPED_SERVICE=0
RESET_LINES=()
SUMMARY_XORG=""; SUMMARY_UPGRADES=""; SUMMARY_RCLONE_CONF=""
VENDOR_DEB=""

on_err() {
  log_error "install failed during step '$STEP' (line $1); nothing after this step was done"
  exit "$EXIT_RUNTIME"
}
trap 'on_err $LINENO' ERR

# on_exit: whatever the way out (die, ERR, Ctrl-C), a sampler this run stopped is started again
# so a failed upgrade never leaves the PC unsampled until the next reboot.
on_exit() {
  local rc=$?
  if (( rc != 0 && STOPPED_SERVICE )); then
    if systemctl start screenlog.service 2>/dev/null; then
      log_warn "the previously installed screenlog.service was started again after this failed install"
    else
      log_error "screenlog.service is stopped; start it with: sudo systemctl start screenlog.service"
    fi
  fi
  tmp_cleanup
}

usage() {
  cat <<USAGE
Usage: sudo bash ./install.sh --name "<display name>" [options]
  --name "<name>"   employee display name (required on first install; renames on upgrade)
  --slug <slug>     Drive folder name; required when the name has no ASCII letters
  --reboot          reboot after a 10 s countdown when done
  --dry-run         show every step without changing anything (read-only checks still run)
  --force           skip the Ubuntu 24.04 and amd64 checks (warnings instead)
  --reannounce      send the ✅ setup message again after this install
USAGE
}

# run CMD ARGS...: execute, or print it in --dry-run.
run() {
  if (( OPT_DRY )); then
    printf '  would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

say() { printf '%s\n' "$*"; }

parse_args() {
  while (($#)); do
    case $1 in
      --name) [[ -n ${2:-} ]] || die "$EXIT_USAGE" "--name needs a value"; OPT_NAME=$2; shift 2 ;;
      --name=*) OPT_NAME=${1#--name=}; shift ;;
      --slug) [[ -n ${2:-} ]] || die "$EXIT_USAGE" "--slug needs a value"; OPT_SLUG=$2; shift 2 ;;
      --slug=*) OPT_SLUG=${1#--slug=}; shift ;;
      --reboot) OPT_REBOOT=1; shift ;;
      --dry-run) OPT_DRY=1; shift ;;
      --force) OPT_FORCE=1; shift ;;
      --reannounce) OPT_REANNOUNCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "$EXIT_USAGE" "unknown option: $1" ;;
    esac
  done
  OPT_NAME=${OPT_NAME#"${OPT_NAME%%[![:space:]]*}"}
  OPT_NAME=${OPT_NAME%"${OPT_NAME##*[![:space:]]}"}
  if [[ -n $OPT_SLUG && ! $OPT_SLUG =~ $CONFIG_SLUG_RE ]] || (( ${#OPT_SLUG} > 64 )); then
    die "$EXIT_USAGE" "--slug must be lowercase letters, digits and single hyphens (max 64)"
  fi
}

# ---- 1. preflight ---------------------------------------------------------------------------

preflight() {
  STEP="preflight"
  local id ver pretty arch f code
  if (( BASH_VERSINFO[0] < 5 )); then
    die "$EXIT_DEPENDENCY" "bash 5 is required (found $BASH_VERSION)"
  fi
  id=$(os_field ID); ver=$(os_field VERSION_ID); pretty=$(os_field PRETTY_NAME)
  if [[ $id != ubuntu || $ver != 24.04 ]]; then
    if (( OPT_FORCE )); then
      log_warn "unsupported OS (${pretty:-unknown}); continuing because of --force"
    else
      die "$EXIT_DEPENDENCY" "only Ubuntu 24.04 LTS is supported (found: ${pretty:-unknown}); use --force to override"
    fi
  fi
  arch=$(system_arch)
  if [[ $arch != amd64 ]]; then
    if (( OPT_FORCE )); then
      log_warn "architecture $arch is not amd64; continuing because of --force"
    else
      die "$EXIT_DEPENDENCY" "only amd64 PCs are supported (found: $arch); use --force to override"
    fi
  fi
  if [[ ! -d $SCREENLOG_SYSROOT/run/systemd/system ]]; then
    if (( OPT_DRY || OPT_FORCE )); then
      log_warn "systemd does not seem to be running (no /run/systemd/system)"
    else
      die "$EXIT_DEPENDENCY" "systemd is not running; is this an Ubuntu desktop?"
    fi
  fi
  for f in bin/screenlogd bin/screenlog lib/log.sh systemd/screenlog.service systemd/screenlog-report.service \
           systemd/screenlog-report.timer.in VERSION uninstall.sh config/screenlog.conf.example; do
    [[ -e $BUNDLE_DIR/$f ]] || die "$EXIT_DEPENDENCY" "bundle incomplete: $f missing; run install.sh from a folder made by 'make bundle'"
  done
  BUNDLE_VERSION=$(<"$BUNDLE_DIR/VERSION")
  [[ $BUNDLE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$EXIT_DEPENDENCY" "bundle VERSION is not X.Y.Z"
  INSTALLED_VERSION=$(cat "$PATH_APP_DIR/VERSION" 2>/dev/null || true)
  if [[ -f $SCREENLOG_CONFIG ]]; then MODE=upgrade; else MODE=first-install; fi
  BUNDLE_CONF="$BUNDLE_DIR/config/screenlog.conf"
  BUNDLE_RCLONE="$BUNDLE_DIR/config/rclone.conf"
  if [[ $MODE == first-install ]]; then
    [[ -f $BUNDLE_CONF ]] || die "$EXIT_CONFIG" "config/screenlog.conf is missing from the bundle ($BUNDLE_CONF); fill it in on the Mac first"
    [[ -f $BUNDLE_RCLONE ]] || die "$EXIT_CONFIG" "config/rclone.conf is missing from the bundle ($BUNDLE_RCLONE); run rclone config on the Mac first"
  fi
  for f in "$BUNDLE_CONF" "$BUNDLE_RCLONE"; do
    if [[ -f $f ]] && [[ $(stat -c %a "$f") != *00 ]]; then
      if (( OPT_DRY )); then
        log_warn "$f is readable by others; it holds secrets (the real run sets it to 600). Delete the bundle after the install."
      elif chmod 600 "$f" 2>/dev/null; then
        log_warn "$f was readable by others; it holds secrets (now 600). Delete the bundle after the install."
      else
        log_warn "$f is readable by others and its mode cannot be changed (USB stick?); copy the bundle to the PC's disk, install from there and delete it afterwards."
      fi
    fi
  done
  merge_config
  STEP="internet check"
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://discord.com/api/v10/gateway 2>/dev/null || true)
    [[ $code == 200 ]] || die "$EXIT_DEPENDENCY" "no internet access to discord.com (HTTP ${code:-none}); connect the PC first"
    code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://www.googleapis.com/ 2>/dev/null || true)
    [[ $code =~ ^[0-9]{3}$ && $code != 000 ]] || die "$EXIT_DEPENDENCY" "no internet access to googleapis.com; connect the PC first"
  else
    log_warn "curl not found; internet check skipped (apt will install curl)"
  fi
}

# merge_config: shared keys from the bundle (or the installed file on an upgrade without one),
# EMPLOYEE_NAME/EMPLOYEE_SLUG from --name/--slug or the installed config; then validate.
merge_config() {
  STEP="config"
  local name slug old k newv oldv
  config_defaults
  if [[ -f $BUNDLE_CONF ]]; then
    config_parse_file "$BUNDLE_CONF" || die "$EXIT_CONFIG" "bundle config invalid: ${CONFIG_ERRORS[*]}"
    if [[ -n ${CONFIG_SEEN[EMPLOYEE_NAME]:-} || -n ${CONFIG_SEEN[EMPLOYEE_SLUG]:-} ]]; then
      log_warn "EMPLOYEE_NAME/EMPLOYEE_SLUG in the bundle config are ignored; they come from --name/--slug"
    fi
  elif [[ -f $SCREENLOG_CONFIG ]]; then
    config_parse_file "$SCREENLOG_CONFIG" || die "$EXIT_CONFIG" "installed config invalid: ${CONFIG_ERRORS[*]}"
  fi
  unset 'CONFIG_SEEN[EMPLOYEE_NAME]' 'CONFIG_SEEN[EMPLOYEE_SLUG]'
  name=$OPT_NAME
  if [[ -z $name && -f $SCREENLOG_CONFIG ]]; then
    name=$(config_read_key "$SCREENLOG_CONFIG" EMPLOYEE_NAME || true)
  fi
  [[ -n $name ]] || die "$EXIT_USAGE" "--name \"<display name>\" is required on the first install"
  slug=$OPT_SLUG
  if [[ -z $slug && -z $OPT_NAME && -f $SCREENLOG_CONFIG ]]; then
    slug=$(config_read_key "$SCREENLOG_CONFIG" EMPLOYEE_SLUG || true)
  fi
  if [[ -z $slug ]]; then
    slug=$(slug_from_name "$name" || true)
    [[ -n $slug ]] || die "$EXIT_USAGE" "the name has no ASCII letters; pass --slug <ascii-slug> for the Drive folder"
  fi
  if [[ $MODE == upgrade && -f $BUNDLE_CONF ]]; then
    for k in "${CONFIG_KEYS[@]}"; do
      [[ $k == EMPLOYEE_NAME || $k == EMPLOYEE_SLUG ]] && continue
      oldv=$(config_read_key "$SCREENLOG_CONFIG" "$k" || true)
      newv=${!k}
      if [[ $oldv != "$newv" ]]; then
        if config_is_secret "$k"; then RESET_LINES+=("$k: changed"); else RESET_LINES+=("$k: ${oldv:-<default>} -> $newv"); fi
      fi
    done
    old=$(config_read_key "$SCREENLOG_CONFIG" EMPLOYEE_SLUG || true)
    if [[ -n $old && $old != "$slug" ]]; then
      log_warn "slug changes from $old to $slug: pending days upload under the new Drive folder; run 'screenlog upload' and 'screenlog report --pending' before moving a PC to another employee"
    fi
  fi
  config_set EMPLOYEE_NAME "$name"
  config_set EMPLOYEE_SLUG "$slug"
  if ! config_validate; then
    local e
    for e in "${CONFIG_ERRORS[@]}"; do printf 'config: %s\n' "$e" >&2; done
    die "$EXIT_CONFIG" "the configuration is invalid (see above)"
  fi
}

# ---- 2. dependencies ------------------------------------------------------------------------

install_packages() {
  STEP="packages"
  local -a debs=() missing=()
  local p pkgs=$APT_PACKAGES sums line v
  shopt -s nullglob
  debs=("$BUNDLE_DIR"/vendor/rclone-*.deb)
  shopt -u nullglob
  if (( ${#debs[@]} > 1 )); then
    die "$EXIT_DEPENDENCY" "more than one rclone .deb in vendor/; keep exactly one"
  elif (( ${#debs[@]} == 1 )); then
    VENDOR_DEB=${debs[0]}
    pkgs=${pkgs/ rclone / }
    sums="$BUNDLE_DIR/vendor/SHA256SUMS"
    if [[ -f $sums ]]; then
      line=$(grep -E "[[:space:]]\*?${VENDOR_DEB##*/}$" "$sums" | head -n1 || true)
      [[ -n $line ]] || die "$EXIT_DEPENDENCY" "vendor/SHA256SUMS has no line for ${VENDOR_DEB##*/}"
      (cd "$BUNDLE_DIR/vendor" && printf '%s\n' "$line" | sha256sum -c --status -) \
        || die "$EXIT_DEPENDENCY" "checksum mismatch for ${VENDOR_DEB##*/}; download it again"
      say "vendor rclone: ${VENDOR_DEB##*/} (checksum verified)"
    else
      log_warn "vendor/SHA256SUMS missing: ${VENDOR_DEB##*/} is installed unverified (see README)"
    fi
  fi
  for p in $pkgs; do
    pkg_installed "$p" || missing+=("$p")
  done
  if (( ${#missing[@]} > 0 )); then
    say "installing packages: ${missing[*]}"
    run apt-get update -q
    run apt-get install -y "${missing[@]}"
  else
    say "packages: all present"
  fi
  if [[ -n $VENDOR_DEB ]]; then
    v=$(dpkg-deb -f "$VENDOR_DEB" Version 2>/dev/null || true)
    if [[ -n $v && $(dpkg-query -W -f='${Version}' rclone 2>/dev/null || true) == "$v" ]]; then
      say "vendor rclone $v already installed"
    else
      run apt-get install -y "$(readlink -f "$VENDOR_DEB")"
    fi
  fi
  v=$(rclone_version)
  if [[ -z $v ]]; then
    if (( OPT_DRY )); then
      log_warn "rclone not installed yet; its version is checked on the real run"
    else
      die "$EXIT_DEPENDENCY" "rclone is not installed after apt-get"
    fi
  elif ! version_ge "$v" "$RCLONE_MIN_VERSION"; then
    die "$EXIT_DEPENDENCY" "rclone $v is too old (need $RCLONE_MIN_VERSION or newer); put a newer rclone .deb into vendor/ (see README)"
  else
    say "rclone: version $v"
  fi
}

# ---- 3. files -------------------------------------------------------------------------------

install_files() {
  STEP="files"
  local new
  run install -d -m 755 -o root -g root "$PATH_APP_DIR"
  run install -d -m 700 -o root -g root "$PATH_ETC_DIR" "$SCREENLOG_DATA_DIR" "$SHOTS_DIR" "$STATE_DIR" "$STATE_DIR/uploaded" "$WORK_TMP_DIR"
  if [[ $MODE == upgrade ]] && systemctl is-active --quiet screenlog.service 2>/dev/null; then
    run systemctl stop screenlog.service
    STOPPED_SERVICE=1
  fi
  if (( OPT_DRY )); then
    say "  would copy bin/ lib/ systemd/ docs/ README.md CHANGELOG.md VERSION uninstall.sh config/screenlog.conf.example to $PATH_APP_DIR (staged swap)"
    say "  would link $PATH_CLI_LINK -> $PATH_APP_DIR/bin/screenlog"
    return 0
  fi
  new="$PATH_APP_DIR.new.$$"
  rm -rf -- "$new"
  install -d -m 755 -o root -g root "$new"
  cp -R "$BUNDLE_DIR/bin" "$BUNDLE_DIR/lib" "$BUNDLE_DIR/systemd" "$new/"
  [[ -d $BUNDLE_DIR/docs ]] && cp -R "$BUNDLE_DIR/docs" "$new/"
  cp "$BUNDLE_DIR/README.md" "$BUNDLE_DIR/CHANGELOG.md" "$BUNDLE_DIR/VERSION" "$BUNDLE_DIR/uninstall.sh" "$new/"
  install -d "$new/config"
  cp "$BUNDLE_DIR/config/screenlog.conf.example" "$new/config/"
  chown -R root:root "$new"
  find "$new" -type d -exec chmod 755 {} +
  find "$new" -type f -exec chmod 644 {} +
  chmod 755 "$new"/bin/* "$new/uninstall.sh"
  rm -rf -- "$PATH_APP_DIR.old"
  if [[ -d $PATH_APP_DIR ]]; then mv "$PATH_APP_DIR" "$PATH_APP_DIR.old"; fi
  mv "$new" "$PATH_APP_DIR"
  rm -rf -- "$PATH_APP_DIR.old"
  install -d -m 755 "${PATH_CLI_LINK%/*}"
  ln -sfn "$PATH_APP_DIR/bin/screenlog" "$PATH_CLI_LINK"
  say "app installed in $PATH_APP_DIR, CLI linked at $PATH_CLI_LINK"
}

# ---- 4. config ------------------------------------------------------------------------------

write_config() {
  STEP="write config"
  local tmp keep=0 check_conf rc
  if (( OPT_DRY )); then
    say "  would write $SCREENLOG_CONFIG (mode 600) with keys: ${CONFIG_KEYS[*]}"
  else
    config_write "$SCREENLOG_CONFIG" || die "$EXIT_RUNTIME" "cannot write $SCREENLOG_CONFIG"
    chown root:root "$SCREENLOG_CONFIG"
    say "config written: $SCREENLOG_CONFIG (600)"
  fi
  if [[ -f $BUNDLE_RCLONE ]]; then
    if [[ ! -f $SCREENLOG_RCLONE_CONF ]]; then
      SUMMARY_RCLONE_CONF="installed from the bundle"
    elif ! cmp -s <(grep -vE '^[[:space:]]*token[[:space:]]*=' "$BUNDLE_RCLONE") <(grep -vE '^[[:space:]]*token[[:space:]]*=' "$SCREENLOG_RCLONE_CONF"); then
      SUMMARY_RCLONE_CONF="replaced from the bundle (remote settings changed)"
    elif (( OPT_DRY )) && ! command -v rclone >/dev/null 2>&1; then
      keep=1
      SUMMARY_RCLONE_CONF="would be kept or replaced depending on whether its token still works (checked on the real run)"
    else
      # dry run: check a temp copy, so rclone's token refresh cannot rewrite the installed file
      check_conf=$SCREENLOG_RCLONE_CONF
      if (( OPT_DRY )); then
        check_conf=$(mktemp "${TMPDIR:-/tmp}/rclone.conf.XXXXXX")
        cp "$SCREENLOG_RCLONE_CONF" "$check_conf" && chmod 600 "$check_conf"
      fi
      rc=0
      SCREENLOG_RCLONE_CONF=$check_conf SCREENLOG_RCLONE_TIMEOUT=60 drive_check || rc=$?
      if (( OPT_DRY )); then rm -f -- "$check_conf"; fi
      if (( rc == 0 )); then
        keep=1
        SUMMARY_RCLONE_CONF="kept (its refreshed token still works)"
      elif (( rc == 75 || rc == 124 )); then
        keep=1
        SUMMARY_RCLONE_CONF="kept (Drive could not be checked right now: $DRIVE_LAST_ERR)"
      else
        SUMMARY_RCLONE_CONF="replaced from the bundle (the installed token no longer works)"
      fi
    fi
    if (( keep == 0 )); then
      if (( OPT_DRY )); then
        say "  would install $BUNDLE_RCLONE as $SCREENLOG_RCLONE_CONF (600)"
      else
        tmp=$(mktemp "$PATH_ETC_DIR/.rclone.conf.XXXXXX")
        cp "$BUNDLE_RCLONE" "$tmp" && chmod 600 "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$SCREENLOG_RCLONE_CONF"
      fi
    fi
  else
    [[ -f $SCREENLOG_RCLONE_CONF ]] || die "$EXIT_CONFIG" "no rclone.conf installed and none in the bundle"
    SUMMARY_RCLONE_CONF="kept (no rclone.conf in the bundle)"
  fi
  if (( OPT_DRY )) && [[ ! -f $SCREENLOG_RCLONE_CONF ]]; then
    return 0
  fi
  grep -qx "\[$RCLONE_REMOTE\]" "$SCREENLOG_RCLONE_CONF" \
    || die "$EXIT_CONFIG" "rclone.conf has no [$RCLONE_REMOTE] section (RCLONE_REMOTE in screenlog.conf must match the remote name)"
  if (( OPT_DRY == 0 )); then
    printf '%s version=%s mode=%s name=%s slug=%s\n' "$(time_iso "$(time_now_epoch)")" "$BUNDLE_VERSION" "$MODE" "$EMPLOYEE_NAME" "$EMPLOYEE_SLUG" >> "$STATE_DIR/install-history"
  fi
}

# ---- 5. remote checks -----------------------------------------------------------------------

remote_checks() {
  STEP="remote checks"
  local rc=0 conf_for_check tmp src
  if (( OPT_DRY )) && ! { command -v rclone && command -v jq && command -v curl; } >/dev/null 2>&1; then
    say "  would check Drive ($RCLONE_REMOTE:$DRIVE_ROOT, then rclone mkdir $(drive_remote_employee)) and the Discord webhook once the packages are installed"
    return 0
  fi
  conf_for_check=$SCREENLOG_RCLONE_CONF
  if (( OPT_DRY )) || [[ ! -f $SCREENLOG_RCLONE_CONF ]]; then
    # a temp copy: rclone's token refresh must not touch the bundle or, in a dry run, the PC
    src=$BUNDLE_RCLONE
    [[ -f $src ]] || src=$SCREENLOG_RCLONE_CONF
    tmp=$(mktemp "${TMPDIR:-/tmp}/rclone.conf.XXXXXX")
    cp "$src" "$tmp" && chmod 600 "$tmp"
    conf_for_check=$tmp
  fi
  SCREENLOG_RCLONE_CONF=$conf_for_check SCREENLOG_RCLONE_TIMEOUT=90 drive_check || rc=$?
  if (( rc != 0 )); then
    case "$rc:$DRIVE_LAST_ERR" in
      124:*) die "$EXIT_REMOTE" "Drive check timed out; check the internet connection" ;;
      *invalid_grant*|*unauthorized_client*|*oken*) die "$EXIT_REMOTE" "Drive token invalid or expired: re-run 'rclone config reconnect' on the Mac, copy the new rclone.conf into the bundle and install again" ;;
      *"directory not found"*) die "$EXIT_REMOTE" "Drive folder '$DRIVE_ROOT' does not exist; create it on the Mac: rclone mkdir $RCLONE_REMOTE:$DRIVE_ROOT" ;;
      *) die "$EXIT_REMOTE" "Drive check failed: $DRIVE_LAST_ERR" ;;
    esac
  fi
  say "drive: $RCLONE_REMOTE:$DRIVE_ROOT reachable"
  if (( OPT_DRY )); then
    say "  would run: rclone mkdir $(drive_remote_employee)"
  else
    drive_mkdir_employee || die "$EXIT_REMOTE" "cannot create the employee folder in Drive: $DRIVE_LAST_ERR"
    say "drive: employee folder $(drive_remote_employee) present"
  fi
  if ! awk -v s="[$RCLONE_REMOTE]" -F' *= *' '$0 == s { f = 1; next } /^\[/ { f = 0 } f && $1 == "client_id" && $2 != "" { ok = 1 } END { exit !ok }' "$conf_for_check"; then
    log_warn "rclone.conf uses rclone's shared Google client_id, which Google is retiring in 2026; set up your own OAuth client (README, one-time setup)"
  fi
  if discord_validate; then
    say "discord: webhook valid (HTTP 200, \"$DISCORD_WEBHOOK_NAME\")"
  else
    case $DISCORD_LAST_ERROR in
      "HTTP 401"|"HTTP 403"|"HTTP 404") die "$EXIT_REMOTE" "Discord webhook rejected ($DISCORD_LAST_ERROR): deleted, or mistyped in config/screenlog.conf" ;;
      "HTTP 429") log_warn "Discord rate-limited the check (HTTP 429); continuing" ;;
      *) die "$EXIT_REMOTE" "cannot validate the Discord webhook ($DISCORD_LAST_ERROR)" ;;
    esac
  fi
  if [[ -n ${tmp:-} ]]; then rm -f -- "$tmp"; fi
}

# ---- 6. and 7. GDM and release upgrades -----------------------------------------------------

EDIT_INI_RESULT=""

# edit_ini FILE SECTION KEY VALUE LABEL: sets EDIT_INI_RESULT to "set now" / "already set"
# (dry-run: prints the diff it would apply).
edit_ini() {
  local file=$1 sec=$2 key=$3 val=$4 label=$5 tmp
  STEP="$label"
  EDIT_INI_RESULT=""
  if [[ ! -e $file ]]; then
    log_warn "$file does not exist; it is created with [$sec] $key=$val"
  fi
  if (( OPT_DRY )); then
    tmp=$(mktemp "${TMPDIR:-/tmp}/ini.XXXXXX")
    [[ -e $file ]] && cp "$file" "$tmp"
    ini_set_key "$tmp" "$sec" "$key" "$val"
    if (( INI_CHANGED )); then
      say "  would change $file:"
      diff -u "$file" "$tmp" 2>/dev/null | sed 's/^/    /' || true
      EDIT_INI_RESULT="set now"
    else
      EDIT_INI_RESULT="already set"
    fi
    rm -f -- "$tmp" "$tmp.screenlog-bak"
    return 0
  fi
  ini_set_key "$file" "$sec" "$key" "$val" || die "$EXIT_SYSTEM" "cannot edit $file"
  [[ $(ini_get_key "$file" "$sec" "$key" || true) == "$val" ]] || die "$EXIT_SYSTEM" "$file: $key=$val not in effect after the edit"
  if (( INI_CHANGED )); then EDIT_INI_RESULT="set now"; else EDIT_INI_RESULT="already set"; fi
}

force_xorg() {
  edit_ini "$PATH_GDM_CONF" daemon WaylandEnable false "force Xorg"
  SUMMARY_XORG=$EDIT_INI_RESULT
}

block_release_upgrades() {
  edit_ini "$PATH_RELEASE_UPGRADES" DEFAULT Prompt never "block release upgrades"
  SUMMARY_UPGRADES=$EDIT_INI_RESULT
}

# ---- 8. units -------------------------------------------------------------------------------

install_units() {
  STEP="units"
  local tmpdir
  if (( OPT_DRY )); then
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/units.XXXXXX")
    units_render "$BUNDLE_DIR/systemd" "$tmpdir" "$REPORT_TIME" > /dev/null
    say "  would install screenlog.service, screenlog-report.service, screenlog-report.timer (REPORT_TIME $REPORT_TIME) into $PATH_UNIT_DIR"
    rm -rf -- "$tmpdir"
    run systemctl daemon-reload
    run systemctl enable --now screenlog.service screenlog-report.timer
    run systemctl restart screenlog.service screenlog-report.timer
    return 0
  fi
  install -d -m 755 "$PATH_UNIT_DIR"
  units_render "$BUNDLE_DIR/systemd" "$PATH_UNIT_DIR" "$REPORT_TIME" || die "$EXIT_SYSTEM" "cannot install the units"
  if (( OPT_REANNOUNCE )); then
    rm -f -- "$STATE_DIR/setup-announced"
    say "announcement flag removed: the ✅ message is sent again after the restart"
  fi
  systemctl daemon-reload || die "$EXIT_SYSTEM" "systemctl daemon-reload failed"
  systemctl enable --now screenlog.service screenlog-report.timer || die "$EXIT_SYSTEM" "systemctl enable failed"
  systemctl restart screenlog.service screenlog-report.timer || die "$EXIT_SYSTEM" "systemctl restart failed"
  STOPPED_SERVICE=0
  sleep "${SCREENLOG_INSTALL_SETTLE:-2}"
  systemctl is-active --quiet screenlog.service || die "$EXIT_SYSTEM" "screenlog.service is not running: journalctl -u screenlog -n 50"
}

# ---- 9. finish ------------------------------------------------------------------------------

finish() {
  STEP="finish"
  local l host i
  host=$(hostname)
  say ""
  if [[ $MODE == first-install ]]; then
    say "screenlog $BUNDLE_VERSION - first install"
  elif [[ $INSTALLED_VERSION == "$BUNDLE_VERSION" ]]; then
    say "screenlog $BUNDLE_VERSION - reinstalled"
  else
    say "screenlog ${INSTALLED_VERSION:-?} -> $BUNDLE_VERSION - upgraded"
  fi
  say "  employee   $EMPLOYEE_NAME (slug $EMPLOYEE_SLUG)"
  say "  host       $host"
  say "  capture    $CAPTURE_START-$CAPTURE_END, ~$SHOTS_PER_HOUR shots/h, report $REPORT_TIME on ${WORK_DAYS:-no days}"
  say "  drive      $(drive_remote_employee)"
  say "  rclone.conf $SUMMARY_RCLONE_CONF"
  say "  xorg       WaylandEnable=false in $PATH_GDM_CONF ($SUMMARY_XORG; backup: ${PATH_GDM_CONF##*/}.screenlog-bak)"
  say "  upgrades   Prompt=never in $PATH_RELEASE_UPGRADES ($SUMMARY_UPGRADES)"
  if (( OPT_DRY )); then
    say "  services   would be enabled and started"
  else
    say "  services   screenlog.service $(systemctl is-active screenlog.service 2>/dev/null || true), report timer next: $(units_next_report)"
  fi
  if (( ${#RESET_LINES[@]} > 0 )); then
    say ""
    say "Shared keys reset from the bundle (edit the bundle's config/screenlog.conf to make a change permanent):"
    for l in "${RESET_LINES[@]}"; do say "  $l"; done
  fi
  say ""
  say "The bundle folder holds secrets: delete it now (rm -rf \"$BUNDLE_DIR\") and wipe the USB stick."
  if (( OPT_DRY )); then
    say "[dry-run] nothing was changed."
    return 0
  fi
  if [[ $MODE == upgrade ]] && session_find 2>/dev/null; then
    if [[ -f $STATE_DIR/setup-announced ]] && (( OPT_REANNOUNCE == 0 )); then
      say "Done. The service is running; no reboot needed."
    else
      say "Done. An X11 session is active: a ✅ message will appear in Discord within about a minute."
    fi
  else
    say "Next step: reboot, log in, and a ✅ message will appear in Discord within about a minute."
  fi
  if (( OPT_REBOOT )); then
    for i in $(seq "${SCREENLOG_REBOOT_COUNTDOWN:-10}" -1 1); do
      printf '\rRebooting in %2d s (Ctrl-C to cancel)' "$i"
      sleep 1
    done
    printf '\n'
    systemctl reboot
  fi
}

main() {
  parse_args "$@"
  if (( EUID != 0 )); then
    die "$EXIT_ROOT" "install.sh must run as root: sudo bash ./install.sh --name \"...\""
  fi
  paths_init
  tmp_init
  trap on_exit EXIT
  SCREENLOG_VERSION=$(<"$BUNDLE_DIR/VERSION")
  SCREENLOG_LOCK_WAIT=${SCREENLOG_LOCK_WAIT:-60}
  if (( OPT_DRY )); then
    say "[dry-run] every step is printed; nothing is changed"
    STATE_DIR="$SCREENLOG_TMP/dry-state"   # the rclone lock must not land on the real system
  fi
  preflight
  say "mode: $MODE${INSTALLED_VERSION:+ (installed: $INSTALLED_VERSION)} -> $BUNDLE_VERSION"
  install_packages
  install_files
  write_config
  remote_checks
  force_xorg
  say "gdm: WaylandEnable=false ($SUMMARY_XORG)"
  block_release_upgrades
  say "release upgrades: Prompt=never ($SUMMARY_UPGRADES)"
  install_units
  finish
}

if [[ -z ${SCREENLOG_INSTALL_NO_MAIN:-} ]]; then
  main "$@"
fi
