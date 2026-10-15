# Architecture

screenlog is a set of Bash 5 scripts and three systemd units. There is no daemon beyond a
sleeping bash loop; every piece of work (a screenshot, an upload, a report) is a short-lived
process started by that loop or by a timer.

## Components

| Component | Runs as | Does |
|---|---|---|
| `screenlog.service` → `bin/screenlogd` | root, system service, from boot | sleeps a random gap, then takes one sample inside capture hours: session → lock → idle → ffmpeg → JPEG → CSV row → quick rclone upload of the day folder. On first run it posts the ✅ announcement. |
| `screenlog-report.timer` → `screenlog-report.service` → `bin/screenlog report --pending` | root, at `REPORT_TIME` and hourly | uploads due days, computes stats, builds the contact sheet, resolves the Drive folder link, posts to Discord once per day, runs retention. |
| `bin/screenlog` | root (except `version`, `help`) | the operator CLI: status, test, report, upload, doctor, apply-config, logs. |
| `install.sh` / `uninstall.sh` | root, once per PC | spec section 9. |

It runs as a **system** service (not a user service) so that it starts at boot regardless of who
logs in, keeps secrets and screenshots out of the employee's reach, and can read the logged-in
user's X authority to capture the screen.

## Data flow

```
screenlogd (loop)                               screenlog report --pending (timer)
  gap_next ─ sleep ─ outside hours? skip          due days = local days in the last 14 days,
  sample_take:                                      not in state/reported-days, before today or
    loginctl → seat0/local/user/active session       today at/after REPORT_TIME
    LockedHint (or ScreenShield over D-Bus)         for each: upload_day → report_stats (awk over
    DISPLAY/XAUTHORITY (gnome-shell environ,          samples.csv) → sheet_build (ImageMagick) →
      session processes, GDM cookie), cached         upload_day → rclone lsjson → Drive link →
    xprintidle → idle seconds                        discord_post (multipart) → mark reported
    ffmpeg x11grab → .tmp → mv HH-MM-SS.jpg        missing-day notice when a work day has no samples
  csv_append samples.csv                          retention: local (uploaded + reported + old),
  upload_day quick (rclone copy, flock, 1 try)      Drive (delete --min-age, rmdirs --leave-root)
```

Both sides share `state/rclone.lock` (every rclone call) and the day folders; the report holds
`state/report.lock` so two report runs never overlap.

## Repository layout

```
bin/screenlogd, bin/screenlog      entry points (set -uo pipefail, LC_ALL=C.UTF-8, umask 077)
lib/log.sh        log_*, die, redaction, exit codes, tmp dir, run_child / sleep_interruptible
lib/config.sh     paths_init, the config parser (never sourced) and validator, config_write
lib/time.sh       the only module that reads the clock or calls date; SCREENLOG_NOW
lib/gap.sh        exponential gaps (Park-Miller generator in awk, seeded from /dev/urandom)
lib/slug.sh       EMPLOYEE_SLUG from the name (locale-independent table)
lib/session.sh    loginctl session, lock state, DISPLAY/XAUTHORITY resolution, idle time
lib/capture.sh    the ffmpeg x11grab command, JPEG quality mapping, samples.csv writer
lib/sample.sh     one sample end to end (SAMPLE_* globals)
lib/drive.sh      the single rclone wrapper (flock + timeout), folder ID lookup
lib/upload.sh     whole-day uploads, uploaded/<day> markers, reported-days helpers
lib/retention.sh  local and Drive retention
lib/discord.sh    webhook posts (curl, private URL file), 429/backoff, validation, 960 px copies
lib/sheet.sh      the contact sheet (ImageMagick 6)
lib/report.sh     due days, stats, message text, report flow, dry run
lib/units.sh      render/install the systemd units
lib/system.sh     INI edits with backup, version compare, os-release, arch, disk
systemd/          the three unit files (timer as .in with @REPORT_TIME@)
config/           screenlog.conf.example (secrets never committed: config/*.conf is ignored)
tests/            bats-core suite, stubs, fixtures, Dockerfile for the ubuntu:24.04 test image
```

Libs are sourced by the entry points in a fixed order (log, config, time, gap, slug, session,
capture, sample, drive, upload, retention, discord, sheet, report, units, system); they define
functions only and never source each other. Every tool is called by its bare name; nothing
assigns `PATH`. Long-running children (sleep, flock, timeout + rclone / ffmpeg, curl) go through
`run_child`, so a SIGTERM reaches them at once.

## Installed layout

| Path | Owner / mode | Contents |
|---|---|---|
| `/opt/screenlog/` | root 755 | bin, lib, systemd, docs, VERSION, uninstall.sh, config/screenlog.conf.example |
| `/usr/local/bin/screenlog` | symlink | the CLI |
| `/etc/screenlog/` | root 700 | `screenlog.conf` (600), `rclone.conf` (600, rewritten by rclone on token refresh) |
| `/var/lib/screenlog/` | root 700 | `shots/YYYY-MM-DD/HH-MM-SS.jpg, samples.csv, contact-sheet.jpg`; `state/`; `tmp/` (ImageMagick temp) |
| `/etc/systemd/system/` | root 644 | `screenlog.service`, `screenlog-report.service`, `screenlog-report.timer` |

## State files (`/var/lib/screenlog/state/`)

| File | Meaning |
|---|---|
| `reported-days` | one `YYYY-MM-DD` per line, appended only after a successful Discord post (or a skipped empty past day); the idempotency key |
| `uploaded/<day>` | exists after a successful `rclone copy`; its mtime is the copy's **start** time, so any file newer than it is re-copied by the next run |
| `setup-announced` | the ✅ announcement was posted; created only after HTTP 2xx |
| `session-cache` | session id, DISPLAY, XAUTHORITY of the last working X session (dropped when the session id changes or a probe fails) |
| `rclone.lock` | flock for every rclone call (daemon waits 5 s, report and CLI 900 s) |
| `report.lock` | one report run at a time |
| `install-history` | one line per install/upgrade (time, version, mode, name, slug) |

`samples.csv`: `timestamp,status,idle_seconds,file,detail`; timestamp is local ISO 8601 with
offset; status is `shot|locked|no_session|unsupported_session|error`; `detail` never contains
commas or line breaks.

## Log lines

`log_info` goes to stdout, warnings and errors to stderr (journald keeps both). Under systemd
there is no timestamp prefix (journald adds one). One line per sample:
`sample day=2026-10-15 status=shot idle=3 file=10-09-41.jpg upload=ok`. Any text taken from a
child process (rclone, curl, ffmpeg) passes through a redactor that replaces webhook URLs and
the webhook token with `<webhook>` / `<token>`; the webhook URL reaches curl only through a
private config file, never on the command line.

## Testing hooks (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `SCREENLOG_CONFIG` | `/etc/screenlog/screenlog.conf` | config file |
| `SCREENLOG_RCLONE_CONF` | beside the config | rclone config |
| `SCREENLOG_DATA_DIR` | `/var/lib/screenlog` | shots, state, tmp |
| `SCREENLOG_SYSROOT` | empty | prefix for every other system path (`/etc/gdm3`, `/etc/update-manager`, `/etc/systemd/system`, `/etc/os-release`, `/run/user`, `/run/systemd`, `/tmp/.X11-unix`, `/opt/screenlog`, `/usr/local/bin`) so install, uninstall, doctor and session discovery can run against a fake root |
| `SCREENLOG_NOW` | unset | freezes "now" (anything GNU `date -d` accepts): file names, CSV timestamps, the capture window, due days |
| `SCREENLOG_DISPLAY`, `SCREENLOG_XAUTHORITY` | unset | skip session and lock lookup; capture this display (Xvfb) |
| `SCREENLOG_ARCH` | `dpkg --print-architecture` | architecture seen by install.sh and doctor |
| `SCREENLOG_SESSION_PIDS` | unset | PIDs to scan for DISPLAY/XAUTHORITY instead of the session cgroup |
| `SCREENLOG_SEED` | from `/dev/urandom` | gap generator seed |
| `SCREENLOG_DISCORD_BACKOFF` | `60 240 600` | sleeps between Discord attempts; empty = one attempt |
| `SCREENLOG_LOCK_WAIT` | daemon 5, CLI 900 | seconds to wait for `rclone.lock` |
| `SCREENLOG_RCLONE_TIMEOUT` | 1200 | outer timeout of one rclone call |
| `SCREENLOG_CAPTURE_TIMEOUT` | 15 | outer timeout of ffmpeg |
| `SCREENLOG_CURL_MAX_TIME` | 120 | `curl --max-time` |
| `SCREENLOG_REPORT_DEADLINE` | 1500 | seconds a report run may spend before deferring the rest |
| `SCREENLOG_ANNOUNCE_INTERVAL` | 30 | announcement poll interval (clamped to ≥ 0.2) |
| `SCREENLOG_ANNOUNCE_BOUND` | 900 | seconds the start-up announcement phase may take before sampling starts |
| `SCREENLOG_SKIP_ANNOUNCE` | unset | skip the announcement entirely (tests) |
| `SCREENLOG_MAX_SHEET_BYTES` | 8388608 | contact sheet size cap |
| `SCREENLOG_TILE_WIDTH` | 320 | first contact sheet tile width |
| `SCREENLOG_FONT`, `SCREENLOG_FONT_BOLD` | DejaVu Sans files | contact sheet fonts |
| `SCREENLOG_EXPECTED_TZ` | `Asia/Dhaka` | doctor's time zone check |
| `SCREENLOG_REBOOT_COUNTDOWN` | 10 | install.sh --reboot countdown |
| `SCREENLOG_INSTALL_SETTLE` | 2 | seconds install.sh waits before checking the service |
| `SCREENLOG_INSTALL_NO_MAIN`, `SCREENLOG_UNINSTALL_NO_MAIN` | unset | source the scripts without running them |

## Exit codes

0 ok · 1 runtime failure · 2 usage · 3 config invalid · 4 root required · 5 lock busy ·
6 dependency or preflight · 7 remote check (Drive, webhook) · 8 system file edit · 130 interrupted.

## Testing

`make lint` runs ShellCheck (zero output at default severity) over every script, stub, helper and
bats file, plus a `set -x` grep. `make test` runs the bats unit suite, `make test-integration`
the Xvfb-backed suite. On macOS both delegate to the `ubuntu:24.04` image built from
`tests/Dockerfile` (tag = checksum of the Dockerfile, built once; the repo is mounted read-only
with `--network none`, so every network tool is stubbed). Stubs under `tests/stubs/` record their
argv to `$STUB_LOG_DIR/<name>.log`; the rclone stub keeps a fake remote on disk and the curl stub
follows `STUB_CURL_PLAN`.

What a container can verify: every parser and rule, the scheduling logic, the stats and the
message text, real `ffmpeg` x11grab against Xvfb, the real contact sheet, the daemon loop (RSS,
SIGTERM, resilience, announcement), install/uninstall against a fake root, the bundle.

What only a real Ubuntu 24.04 desktop can verify: logind sessions on seat0, `LockedHint`, the
GDM cookie and `gnome-shell`'s environment, capture of a real Xorg desktop with the cursor, the
systemd units in action (CPUQuota, MemoryMax, ProtectSystem), GDM's reaction to
`WaylandEnable=false`, and the performance budget on the real CPUs. These are the manual
checklist in the README.

## Decisions

**Why a system service.** It must start at boot before anyone logs in, hold root-only secrets
(`/etc/screenlog`), keep screenshots out of the employee's reach, and read the user's X authority
file. A user service would run as the employee, who could stop it or read the token.

**Why X11 only.** Wayland has no root-window capture: every screenshot would go through the
portal with a consent dialog, and `xprintidle` has no Wayland equivalent. Ubuntu 24.04 still ships
the Xorg session; the installer forces it (`WaylandEnable=false`) and blocks the release upgrade
because Ubuntu 26.04 drops the X11 session entirely.

**Why exponential gaps.** With an exponential distribution the chance of the next shot in the
next minute is the same whether the last one was 10 seconds or 25 minutes ago, so there is no safe
window after a capture. Fixed slots or "N per hour" would be predictable. The clamp to
[`MIN_GAP_SECONDS`, `MAX_GAP_SECONDS`] bounds the extremes; with the defaults the effective mean
is about 502 s (≈ 7.2 shots/hour). The generator is a Park–Miller LCG written in awk because
mawk's `srand()` is not repeatable, so a seed gives the same sequence on every awk.

**Why JPEG.** A 1080p PNG of a code editor is 2–6 MB; a JPEG at the chosen quality is 300–600 KB
with code text still legible at 100 % zoom. Chroma is kept at full resolution (`yuvj444p`) so
coloured syntax does not smear. ffmpeg's mjpeg encoder has no libjpeg quality scale, so
`JPEG_QUALITY` is mapped to its `-q:v` (85 → 3) and documented as approximate.

**Why no public links.** `rclone link` would make a folder readable by anyone with the URL. The
report links `https://drive.google.com/drive/folders/<ID>`; the ID comes from `rclone lsjson`
and the link only works for accounts the Screenlog folder is shared with.

**Smaller decisions (spec gaps).**

- The capture window is `[CAPTURE_START, CAPTURE_END)` at minute granularity: 17:50:00 is outside.
  "Last 14 days" means today−13 … today. REPORT_TIME has passed when the current minute ≥ it.
- `--force` skips both the Ubuntu 24.04 and the amd64 check (with warnings); `doctor` reports a
  non-amd64 PC as WARN. Needed to run the installer in the arm64 test container and VMs.
- Lock state: `LockedHint`, then gnome-shell's `org.gnome.Shell.ScreenShield` over the user's
  session bus (the `org.gnome.ScreenSaver` name is a bus-activated proxy on GNOME 46), then that
  proxy. An unknown lock state captures anyway and warns once per session.
- `jq` is used (Drive folder ID, the Discord payload, `retry_after`) and `libglib2.0-bin` is
  installed for `gdbus`; both are added to the spec's apt line.
- An upload that succeeded but whose folder-ID lookup failed posts
  `⚠️ Drive link unavailable: <reason>` rather than the "upload failed" line.
- An empty past-day folder is skipped and marked reported; today's empty folder follows the
  missing-day rule.
- `report --date` on an already reported day refuses (exit 0 with a hint); on a not-yet-due day
  it runs. A post that fails after all retries exits 1 and leaves the day pending for the timer.
- A report run stops starting new days after 25 minutes (`SCREENLOG_REPORT_DEADLINE`) and after
  Discord became unreachable; the hourly run continues. An hourly run with nothing due only
  retries pending uploads of earlier days (today uploads from the daemon during capture hours).
- The daemon waits at most 5 s for the rclone lock (`upload=skipped(lock busy)`), the report 900 s.
- Local retention deletes a day only when uploaded completely **and** reported (or out of the
  14-day window) **and** older than `LOCAL_RETENTION_DAYS`; Drive retention runs only in report
  runs that posted something (about once a day).
- The ✅ shot is taken whenever a session appears, even outside capture hours; its CSV row is
  written only inside the window. The announcement phase is bounded (15 minutes or a permanent
  webhook error); sampling then starts and the announcement is retried hourly.
- A contact sheet that cannot be shrunk under 8 MB posts the text with
  `⚠️ Contact sheet too large to attach`.
- `screenlog test` shots count in the day's stats and sheet (`detail=manual test`).
- Every CLI command except `version` and `help` requires root, checked before any file is read.
- Config: duplicate keys are errors; the webhook URL may be version-less, `discordapp.com`,
  `ptb.` or `canary.`; it is always called as `https://discord.com/api/v10/...`.
- The slug uses a fixed transliteration table (no `iconv`): it names a permanent Drive folder and
  must not depend on which locales a PC has generated.
- On an upgrade `rclone.conf` is kept when its non-token lines equal the bundle's and `rclone lsd`
  still works; otherwise the bundle's file replaces it. Shared keys follow the bundle (spec), and
  the installer lists every key it reset.
- A missing `/etc/gdm3/custom.conf` or `release-upgrades` is created with a warning.
- `/opt/screenlog` is replaced by a staged copy and a rename; `uninstall.sh` has `--dry-run`;
  `make bundle` never copies `config/*.conf`.
- Units: the spec's text plus `Environment=HOME=/root LANG=C.UTF-8 MAGICK_THREAD_LIMIT=1` on both
  services, ImageMagick memory limits and `MAGICK_TEMPORARY_PATH` on the report service, and
  `TimeoutStopSec`. No `PrivateTmp`/`ProtectHome` (they hide `/tmp/.X11-unix` and `/run/user`).
- ffmpeg is run without `-framerate` (a frame rate makes x11grab wait one interval before the
  first frame) and without `-video_size` (it defaults to the whole root window).
