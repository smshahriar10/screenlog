# Screenlog — Build Spec

> **For Claude Code:** Build the project described below in this folder.
> - Read the whole spec before writing any code.
> - Work through the phases in §12 in order. Run the checks after each phase and commit to git.
> - For small gaps, make a sensible decision and record it under "Decisions" in `docs/ARCHITECTURE.md`.
> - Stop to ask only if something blocks you or would change behavior this spec describes.
> - If anything here is technically wrong for Ubuntu 24.04, say so and propose a fix before deviating.

**Context:** Our developers work on Ubuntu 24.04 desktop PCs with 16 GB DDR3, an SSD and older CPUs. I want a very lightweight way to see what's on their screens during work hours.

---

## 1. Overview

`screenlog` is a background app installed once per PC. It does four things:

1. It takes screenshots at random moments, averaging 7 per hour. It only does this during configured hours, while someone is logged in and the screen is unlocked.
2. It records keyboard/mouse idle time with every sample. When the screen is locked, it logs `locked` instead of capturing.
3. It uploads the screenshots to a dedicated Google Drive account with rclone, organized per employee and per day.
4. At 17:30 each day, it posts a report to a private Discord channel through a webhook. The report has summary stats, a contact sheet of the day's shots, and a link to that day's Drive folder.

The owner installs it with one command per PC. It runs as a system service, starts automatically on every boot, and needs no interaction afterwards.

Names: the daemon is `screenlogd` and the CLI is `screenlog`.

### Hard requirements

- **Performance comes first.** The app must never cause a noticeable slowdown on these PCs. See the budget in §8.
- **Target:** Ubuntu 24.04 LTS desktop (GNOME), amd64, **X11 session only**. The installer forces Xorg (§9). Wayland is out of scope for v1.
- **Stack:** Bash 5 plus standard Ubuntu (apt) packages. No Python, Node, pip, npm, snap or flatpak. The only long-running process is a sleeping bash loop.
- **Code quality:** plain, auditable scripts. Every script passes `shellcheck` with zero warnings.
- **Transparency:** use normal process and service names, and make no attempt to hide the app from users.

### Out of scope for v1

These are not part of v1:
- video recording;
- Wayland or Ubuntu 26.04 support;
- keystroke logging;
- window titles or app-usage tracking;
- webcam or microphone;
- browser history;
- a central dashboard;
- any GUI or tray icon.

---

## 2. Architecture

```
screenlog.service (root) ── screenlogd: bash loop, sleeps a random gap between samples
   each sample: find active X11 session → locked? → idle time → ffmpeg x11grab → JPEG
                append row to samples.csv → rclone copy today's folder to Drive
        │
        ▼
/var/lib/screenlog/shots/YYYY-MM-DD/   HH-MM-SS.jpg …, samples.csv, contact-sheet.jpg
        │
screenlog-report.timer (REPORT_TIME daily + hourly retries)
   └─ screenlog report --pending
        sync day → stats → contact sheet (ImageMagick) → Discord webhook → retention cleanup
```

It runs as root, as a system service rather than a user service, so that it:
- starts at boot regardless of who logs in;
- keeps its files and credentials out of employees' reach;
- can read the logged-in user's X authority to capture the screen.

---

## 3. Layout

### Repository

```
screenlog/
├── README.md                     # owner's guide (§10)
├── CHANGELOG.md
├── VERSION                       # 1.0.0
├── Makefile                      # lint, test, test-integration, bundle
├── install.sh
├── uninstall.sh
├── bin/
│   ├── screenlogd                # sampler daemon
│   └── screenlog                 # CLI (§7)
├── lib/                          # shared bash modules: config, log, time, session,
│                                 #   capture, upload, report, discord, drive
├── systemd/
│   ├── screenlog.service
│   ├── screenlog-report.service
│   └── screenlog-report.timer.in # @REPORT_TIME@ is rendered at install
├── config/
│   └── screenlog.conf.example    # fully commented
├── docs/
│   ├── ARCHITECTURE.md
│   ├── TROUBLESHOOTING.md
│   └── TEAM_NOTICE.md
├── tests/                        # bats-core tests and fixtures
└── .gitignore                    # config/screenlog.conf, config/rclone.conf, vendor/, dist/
```

### Installed on each PC

| Path | Owner / mode | Contents |
|---|---|---|
| `/opt/screenlog/` | root, 755 | app code, `VERSION`, `uninstall.sh` |
| `/usr/local/bin/screenlog` | symlink | CLI |
| `/etc/screenlog/` | root, 700 | `screenlog.conf` (600), `rclone.conf` (600) |
| `/var/lib/screenlog/` | root, 700 | `shots/`, `state/` |
| `/etc/systemd/system/` | root | the three units |

---

## 4. Configuration

The config file is `/etc/screenlog/screenlog.conf`, made of simple `KEY="value"` lines.
- Load it with a small parser that only accepts known keys. Do not `source` it.
- Validate it on every load and fail with clear messages.
- Never print secret values in logs or output.

```bash
# --- per PC (set by install.sh) ---
EMPLOYEE_NAME="Rahim Uddin"          # shown in reports
EMPLOYEE_SLUG="rahim-uddin"          # Drive folder name; derived from the name unless --slug is given

# --- secrets / destinations ---
DISCORD_WEBHOOK_URL=""               # https://discord.com/api/webhooks/<id>/<token>
RCLONE_REMOTE="screenlog-gdrive"     # remote name inside /etc/screenlog/rclone.conf
DRIVE_ROOT="Screenlog"               # top-level folder in the dedicated Drive, shared with the owner

# --- sampling ---
SHOTS_PER_HOUR=7                     # average; gaps are random (§5.2)
MIN_GAP_SECONDS=60
MAX_GAP_SECONDS=1800
CAPTURE_START="09:00"                # local time, 24h
CAPTURE_END="17:50"
IDLE_THRESHOLD_SECONDS=300           # a shot counts as "active" if idle < this

# --- images ---
JPEG_QUALITY=85
MAX_HEIGHT=1080                      # downscale only when the screen is taller than this

# --- reporting ---
REPORT_TIME="17:30"
WORK_DAYS="Sun Mon Tue Wed Thu"      # days on which "no screenshots today" is reported
GAP_ALERT_MINUTES=45                 # must be greater than MAX_GAP_SECONDS / 60

# --- storage ---
LOCAL_RETENTION_DAYS=7               # local copies deleted after this, only once uploaded
REMOTE_RETENTION_DAYS=60             # 0 = keep forever
UPLOAD_BWLIMIT="1M"                  # passed to rclone --bwlimit
```

All times are the PC's local time (expected: Asia/Dhaka). Parse day names with `LC_ALL=C`.

---

## 5. Behavior

### 5.1 Sampler daemon (`screenlogd`)

1. Load and validate the config.
2. **First-run announcement.** Do this only if `state/setup-announced` doesn't exist.
   - Check every 30 s for a capturable session (§5.3).
   - When one appears, take a shot and upload it.
   - Post `✅ Screenlog is running on <EMPLOYEE_NAME>'s PC (<hostname>, v<version>)` with the image attached.
   - Create the flag only after the post succeeds.
   - This must happen within about a minute of the first login after install.
3. **Main loop**, forever:
   - Sleep a random gap (§5.2). The sleep must be interruptible (`sleep … & wait $!`) so that SIGTERM stops the daemon immediately.
   - If the current time is outside `CAPTURE_START`–`CAPTURE_END`, continue without logging anything.
   - Take one sample (§5.3) and append a row to that day's `samples.csv`.
   - If a shot was taken, upload it (§5.5). This is best effort.
4. A failed sample or upload must never end the loop. Log one line per sample to stdout (journald), without secrets.

### 5.2 Random gaps

- Draw each gap from an exponential distribution with mean `3600 / SHOTS_PER_HOUR` seconds.
- Clamp it to `[MIN_GAP_SECONDS, MAX_GAP_SECONDS]`.
- Seed from `/dev/urandom`, not `$RANDOM` alone.

The goal is that a capture says nothing about when the next one will come, so there's no "safe" window right after a shot. Do not use fixed slots or a fixed count per hour.

### 5.3 Taking a sample

1. **Find the session.** Use `loginctl` to find the active, local (`Remote=no`), `Class=user` session on `seat0`.
   - None: status `no_session`.
   - `Type` is not `x11`: status `unsupported_session`.
2. **Check the lock.** If `loginctl show-session <id> -p LockedHint --value` is `yes`, the status is `locked` and no screenshot is taken.
   - If LockedHint isn't available, fall back to `org.gnome.ScreenSaver.GetActive` over the user's session bus (`unix:path=/run/user/<uid>/bus`).
   - Run that fallback as the user with `runuser`, never `sudo`, because `NoNewPrivileges` blocks sudo.
3. **Resolve `DISPLAY` and `XAUTHORITY`.** Don't rely on loginctl's `Display` property; GDM starts Xorg inside the session, so it is often empty. Look in this order:
   1. `/proc/<pid>/environ` of the user's `gnome-shell` process;
   2. any process in that session with `DISPLAY` set;
   3. `/run/user/<uid>/gdm/Xauthority`.

   Confirm the pair works (for example, `xprintidle` succeeds) and cache it per session ID.
4. **Idle time.** `xprintidle` returns milliseconds since the last keyboard or mouse input. Store it as seconds.
5. **Capture.**
   - Grab one frame with `ffmpeg -f x11grab`, including the cursor. The root window covers all monitors.
   - Downscale only when the frame is taller than `MAX_HEIGHT`, keeping the aspect ratio.
   - Write a JPEG at `JPEG_QUALITY` to `shots/YYYY-MM-DD/HH-MM-SS.jpg`, using a temp name and an atomic rename.
   - Code text must be legible at 100% zoom on a 1080p screen.
   - On failure, the status is `error`, with a short reason in `detail`.
6. **Record the sample.** Append a row to `shots/YYYY-MM-DD/samples.csv`, creating the file with a header if it's missing:
   ```
   timestamp,status,idle_seconds,file,detail
   ```
   - `timestamp` is ISO 8601 local time with offset.
   - `status` is one of `shot|locked|no_session|unsupported_session|error`.

**Testing hooks** (document them in ARCHITECTURE.md):
- `SCREENLOG_CONFIG` and `SCREENLOG_DATA_DIR` override paths.
- `SCREENLOG_DISPLAY` and `SCREENLOG_XAUTHORITY` skip session lookup, for use with Xvfb.
- `SCREENLOG_NOW` fakes the current time for scheduling logic.

### 5.4 Daily report (`screenlog report --pending`)

The timer runs this (§6).
- It looks at every day in the last 14 days that has a local `shots/` folder and isn't yet listed in `state/reported-days`.
- A day is **due** if it is before today, or if it is today and the time is at or after `REPORT_TIME`.

For each due day:

1. **Upload** the day's folder (§5.5).
2. **Compute stats** from `samples.csv`:
   - the number of shots;
   - active shots (idle < `IDLE_THRESHOLD_SECONDS`) and their percentage;
   - non-zero counts of the other statuses;
   - the times of the first and last shot;
   - every gap between consecutive samples longer than `GAP_ALERT_MINUTES`, written like `13:05–14:02`.
3. **Build the contact sheet.** If there's at least one shot, build it (§5.6) and upload it into the day's folder as `contact-sheet.jpg`.
4. **Resolve the Drive link.**
   - Run `rclone lsjson --dirs-only` on the employee folder and take the `ID` of the day's folder.
   - The link is `https://drive.google.com/drive/folders/<ID>`.
   - **Never create public links**, so no `rclone link`. The owner opens the link with their own Google account, which has access through the shared root folder.
5. **Post to Discord** (§5.7) with the contact sheet attached:
   ```
   📸 Rahim Uddin — Thu 15 Oct 2026
   58 shots · 49 active (84%) · locked 6× · first 09:12 · last 17:24
   ⚠️ No samples 13:05–14:02
   Full size: https://drive.google.com/drive/folders/…
   dev-pc-03 · v1.0.0
   ```
   If the Drive upload failed, still post the report. Replace the link line with `⚠️ Drive upload failed: <reason> — will retry`.
6. **Mark it done.** After a successful post, append the day to `state/reported-days`.

**Missing day.** Post `⚠️ No screenshots from <name> today (<hostname>)` and mark today as reported when all of these hold:
- today is in `WORK_DAYS`;
- it's past `REPORT_TIME`;
- there are no samples at all today;
- today isn't reported yet.

After the reports, run retention (§5.8).

Report runs must be idempotent: running twice never posts twice. Shots taken after the report time still upload to the same Drive folder, but they don't appear in that day's contact sheet.

### 5.5 Upload

Upload a whole day's folder at a time:

```
rclone --config /etc/screenlog/rclone.conf copy <local day dir> \
  <RCLONE_REMOTE>:<DRIVE_ROOT>/<EMPLOYEE_SLUG>/<YYYY-MM-DD> --bwlimit <UPLOAD_BWLIMIT>
```

- Use sensible timeouts and few retries; the next sample retries anyway.
- Copying the whole folder makes retries automatic and idempotent. When the PC is offline, files stay local and go up later.
- Serialize **every** rclone operation with `flock` on `state/rclone.lock`. Google Drive allows duplicate file names, so concurrent uploads from the daemon and the report could create duplicate files.

### 5.6 Contact sheet

Use ImageMagick (IM6 on 24.04: `convert` and `montage`).

- **Tiles:** one per shot, in time order.
  - Each tile has a caption bar like `09:12 · active` or `10:47 · idle 14m`.
  - Idle tiles must stand out, for example with an amber caption bar instead of green.
- **Header:** name, date, shot count and active %.
- **Memory:** make thumbnails one at a time, or use the `jpeg:size` read hint. Never load all the full-size images at once.
- **Size:** output a JPEG of at most 8 MB (Discord's limit is 10 MB). Shrink the tiles if needed.
- **Detail:** text in thumbnails doesn't need to be readable. The Drive link is for detail.
- **Font:** DejaVu Sans.

### 5.7 Discord

- Post with `curl` as multipart: `payload_json` (`content`, plus `allowed_mentions: {"parse": []}`) and `files[0]`.
- Images sent to Discord are always downscaled: either a contact sheet or a copy at most 960 px wide. Full-size images only go to Drive.
- On HTTP 429, wait for `retry_after`.
- Retry network errors with backoff, for example 4 attempts over about 15 minutes.
- To validate a webhook without posting, send a `GET` to it. A valid webhook returns 200 and JSON.
- Never log the webhook URL.

### 5.8 Retention

- **Local:** delete day folders older than `LOCAL_RETENTION_DAYS`, but only after a successful `rclone copy` of that folder.
- **Drive:** if `REMOTE_RETENTION_DAYS` is greater than 0:
  - run `rclone delete --min-age <N>d` on the employee folder;
  - then run `rclone rmdirs --leave-root`.

  Deleted files go to the Drive trash, which is rclone's default for Drive.

---

## 6. systemd units

`screenlog.service`
```ini
[Unit]
Description=Screenlog screenshot sampler
After=systemd-logind.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/screenlog/bin/screenlogd
Restart=always
RestartSec=30
Nice=19
IOSchedulingClass=idle
CPUQuota=10%
MemoryHigh=200M
MemoryMax=256M
NoNewPrivileges=yes
ProtectSystem=full
ReadWritePaths=/etc/screenlog /var/lib/screenlog

[Install]
WantedBy=multi-user.target
```

`screenlog-report.service`
```ini
[Unit]
Description=Screenlog daily report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/screenlog/bin/screenlog report --pending
Nice=19
IOSchedulingClass=idle
CPUQuota=50%
MemoryMax=400M
TimeoutStartSec=30min
NoNewPrivileges=yes
ProtectSystem=full
ReadWritePaths=/etc/screenlog /var/lib/screenlog
```

`screenlog-report.timer.in` (the installer replaces `@REPORT_TIME@`)
```ini
[Unit]
Description=Screenlog daily report timer

[Timer]
OnCalendar=*-*-* @REPORT_TIME@:00
OnCalendar=hourly
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
```

Notes:
- The hourly run retries anything still pending, for example when the PC was off or offline at report time. It exits at once when there's nothing to do.
- The random delay keeps all the PCs from hitting Discord's rate limit in the same second.
- **Do not add `PrivateTmp=` or `ProtectHome=`.** They hide `/tmp/.X11-unix` and `/run/user`, which X11 capture needs.
- `/etc/screenlog` must stay writable, because rclone saves refreshed OAuth tokens into `rclone.conf`.
- Verify any further hardening on a real PC before keeping it.

---

## 7. CLI (`screenlog`)

| Command | Purpose |
|---|---|
| `status` | Service and timer state, next report time, last sample, today's counts, pending uploads and reports, session type and version. No secrets. |
| `test` | Take a shot now, upload it, and post `🧪 Test from <name>` with the image. |
| `report [--date YYYY-MM-DD] [--pending] [--dry-run]` | Build and post reports. `--dry-run` writes the message JSON and contact sheet to a temp dir, prints the paths, and makes no network calls. |
| `upload` | Upload all local days now. |
| `doctor` | PASS / WARN / FAIL checks (listed below the table). |
| `apply-config` | Re-validate the config, re-render the timer from `REPORT_TIME`, and restart the services. |
| `logs` | `journalctl -u screenlog -u screenlog-report -n 200 --no-pager` |
| `version` | Print the version. |
| `help` | Usage for all commands. |

`doctor` checks:
- the OS is Ubuntu 24.04;
- `WaylandEnable=false` is set;
- the current session is X11;
- the upgrade prompt is off;
- the packages are installed, and the rclone version is new enough;
- the config is valid;
- Drive is reachable;
- the webhook is valid (GET);
- the units are enabled;
- there's enough disk space;
- the time zone;
- the age of the last sample.

Commands that need root say so clearly when run without it.

---

## 8. Performance budget

These are acceptance criteria.

| What | Budget |
|---|---|
| Between samples | Only a sleeping bash process: RSS under 10 MB, no CPU use. |
| Each sample (capture + encode) | Under 1 s wall time unthrottled, under 0.5 s CPU. |
| Each upload | rclone exits after every run; nothing stays resident. |
| Report run | Under 60 s, peak memory under 300 MB, at `Nice=19`. |
| Hard caps | systemd limits as in §6, so even a bug can't take more. |
| Disk | Roughly 10–25 MB per day locally, pruned automatically. |

The README must explain how to check these on a real PC:
- `systemctl status` for memory peak;
- `systemd-cgtop`;
- `/usr/bin/time -v screenlog test`.

---

## 9. Install and uninstall

### Deployment flow (owner)

1. On the Mac, run `make bundle`. This produces `dist/screenlog-<version>/` and a `.tar.gz`.
2. Put the filled-in `config/screenlog.conf` and `config/rclone.conf` into the bundle's `config/` folder.
3. Copy the folder to each PC, by USB or a private link.
4. Run `sudo ./install.sh --name "Rahim Uddin"`, then reboot.

### `install.sh`

Options:
- `--name "<display name>"`: required on first install.
- `--slug <slug>`: the Drive folder name. Required if the name has no ASCII letters.
- `--reboot`: reboot when done.
- `--dry-run`: show what would happen without changing anything.
- `--force`: skip the OS check.
- `--reannounce`: send the ✅ setup message again.

The installer must be idempotent: re-running it upgrades in place and keeps config and state. Steps:

1. **Preflight.** Check all of these:
   - it's running as root;
   - the OS is Ubuntu 24.04 per `/etc/os-release` (unless `--force`), on amd64;
   - the config files exist and are valid: webhook URL format, required keys, and `GAP_ALERT_MINUTES` greater than `MAX_GAP_SECONDS / 60`;
   - the internet is reachable.
2. **Dependencies.** Run `apt-get install -y ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core rclone`. Add `jq` only if the code actually uses it.
   - If `vendor/rclone-*.deb` is present, install that instead of the apt rclone. Document how to download it from rclone.org and verify its checksum.
   - Require rclone 1.60 or newer.
3. **Files.** Create `/opt/screenlog`, `/etc/screenlog` (700) and `/var/lib/screenlog` (700). Copy the app and symlink the CLI.
4. **Config.** Write `/etc/screenlog/screenlog.conf` and `rclone.conf`, both 600.
   - Shared keys come from the bundle's `config/screenlog.conf`.
   - `EMPLOYEE_NAME` and `EMPLOYEE_SLUG` come from `--name` and `--slug`. On upgrade, keep them from the installed config.
   - Missing keys get their defaults.
5. **Remote checks.** Fail clearly if either of these fails:
   - check Drive access with `rclone lsd`, then `rclone mkdir` the employee folder;
   - validate the webhook with a GET.
6. **Force Xorg.** In `/etc/gdm3/custom.conf`, set `WaylandEnable=false` under `[daemon]`, uncommenting or adding it. Back up the original once, to `custom.conf.screenlog-bak`.
7. **Block release upgrades.** Set `Prompt=never` in `/etc/update-manager/release-upgrades`, backing it up the same way. Ubuntu 26.04 is Wayland-only and would break capture. Security updates for 24.04 are unaffected.
8. **Units.** Install the units, rendering `@REPORT_TIME@`. Run `systemctl daemon-reload`, then `systemctl enable --now screenlog.service screenlog-report.timer`.
9. **Finish.** Print a short summary and the next step: "Reboot, log in, and a ✅ message will appear in Discord within about a minute." With `--reboot`, reboot after a 10-second countdown.

Never print secrets. On any failure, exit non-zero with a clear message.

### `uninstall.sh`

This script is also copied to `/opt/screenlog/uninstall.sh`. It:
- stops, disables and removes the units;
- removes the app and the CLI symlink;
- restores `custom.conf` and `release-upgrades` from their backups;
- keeps `/etc/screenlog` and `/var/lib/screenlog` unless `--purge` is given;
- never touches files in Drive;
- prints what it did.

---

## 10. Documentation

### `README.md`

This is the owner's guide, written for a developer who isn't a Linux sysadmin. It must cover:

1. **What it captures and what it doesn't.** It captures no keystrokes, audio, webcam or browsing history. It captures nothing while the screen is locked or outside capture hours.
2. **One-time setup.**
   - Create a dedicated Google account for the screenshots.
   - On the Mac, run `brew install rclone`, then `rclone config --config ./config/rclone.conf`. Use the remote name `screenlog-gdrive`, type `drive` and full `drive` scope, and log in through the browser with the dedicated account.
   - Run `rclone mkdir` for the `Screenlog` folder. Then share that folder with the owner's main Google account from the Drive web UI.
   - Explain that rclone's built-in client ID is fine at this volume. If the owner ever creates their own Google OAuth client, its consent screen must be set to "In production". Tokens for apps in "Testing" expire after 7 days, and uploads then stop.
   - Create a private Discord channel and a webhook for it.
   - Fill in `config/screenlog.conf`.
   - Run `make bundle`.
3. **Per-PC install.** Install, reboot and confirm, with an example of the ✅ message.
4. **Reading the report.** About 60 samples a day gives roughly ±10 percentage points of uncertainty for a single day, and about ±5 over a week. Judge patterns, not single shots.
5. **Everyday tasks:**
   - change hours, report time or work days, then run `apply-config`;
   - rename an employee;
   - move a PC to a new employee;
   - update to a new version by re-running `install.sh` from the new bundle;
   - uninstall.
6. **Performance** and how to verify it (§8).
7. **Security:**
   - secrets live only in root-only files;
   - wipe the USB stick after deploying;
   - employees with sudo can stop the app, and gaps then show up in the report.
8. **Manual test checklist** for the first real PC.

### `docs/ARCHITECTURE.md`

This covers the components, data flow, file layout, state files and testing hooks. It ends with a "Decisions" section explaining:
- why a system service;
- why X11 only;
- why exponential gaps;
- why JPEG;
- why no public links.

### `docs/TROUBLESHOOTING.md`

This covers:
- no ✅ message after install;
- the session is Wayland;
- the Drive token expired or was revoked;
- Discord 401, 404 or 429;
- no shots: outside hours, locked, or no session;
- the wrong time zone;
- a full disk;
- how to read `doctor` output.

### `docs/TEAM_NOTICE.md`

This is a short, plain-language notice the owner can adapt and share with employees before rollout. It covers:
- what's captured and how often;
- the capture hours;
- what's never captured;
- that idle time is recorded but keystrokes are not;
- who can see the screenshots;
- how long they're kept;
- a tip to lock the screen (Super+L) for anything personal.

### Also

Also write `CHANGELOG.md`, a fully commented `config/screenlog.conf.example`, and `screenlog help`.

---

## 11. Testing

The dev machine is a Mac (Apple Silicon), but the target is Ubuntu.
- The scripts rely on GNU coreutils, so run all tests inside an `ubuntu:24.04` Docker container.
- `make test` should do this automatically when not on Linux.
- If Docker isn't available, tell me, run what you can (shellcheck), and continue.

The test targets:

- **`make lint`:** `shellcheck -x` on every script, with zero warnings.
- **`make test`:** bats-core unit tests covering:
  - the gap generator: draws always stay within bounds, and over many draws (e.g. 10,000) the mean is within ±5% of the expected clamped mean;
  - the capture-window logic, including boundary minutes;
  - the due/pending-day logic, including catch-up after missed days and the 14-day window (use `SCREENLOG_NOW`);
  - stats from fixture CSVs: counts, active % and gaps;
  - config parsing and validation;
  - slug generation, including names with no ASCII letters;
  - idempotency: reporting the same day twice posts only once (stub `curl`).
- **`make test-integration`:** run in Docker with Xvfb, stubbing `rclone` and `curl`.
  - Capture via `SCREENLOG_DISPLAY` produces a valid JPEG no taller than `MAX_HEIGHT`, plus a CSV row.
  - `report --dry-run` produces a contact sheet of at most 8 MB, with captions.
  - If `xprintidle` doesn't work under Xvfb, stub it there.

---

## 12. Build phases

1. Skeleton, config loader and validator, logging, time helpers and slugify, with tests.
2. Session resolution, lock and idle checks, capture and CSV, with an integration test.
3. Upload, locking and retention.
4. Report: stats, contact sheet, Discord, pending logic and dry-run, with tests.
5. CLI and systemd units.
6. `install.sh`, `uninstall.sh` and `make bundle`.
7. Documentation (§10).
8. Final pass against this spec. Run everything, then give me a short summary and the manual test checklist for the first real PC.

---

## 13. Definition of done

- Everything in §11 passes.
- `install.sh` is idempotent, refuses anything but 24.04 without `--force`, and never prints secrets.
- `uninstall.sh` fully reverses the install.
- On a real Ubuntu 24.04 PC, following the manual checklist:
  - after install and reboot, the ✅ message arrives within about a minute of login;
  - shots appear in Drive;
  - the 17:30 report arrives with the contact sheet and the folder link;
  - resource use stays within §8.
- The docs in §10 are complete and accurate.
