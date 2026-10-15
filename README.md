# screenlog

A very lightweight way to see what is on the developers' screens during work hours, built for
Ubuntu 24.04 desktop PCs (GNOME, X11). It is installed once per PC with one command, runs as a
system service from every boot, and needs no interaction afterwards.

What it does, four things:

1. Takes screenshots at random moments, on average 7 per hour, only during configured hours,
   only while someone is logged in and the screen is unlocked.
2. Records keyboard/mouse idle time with every sample; while the screen is locked it logs
   `locked` instead of capturing.
3. Uploads the screenshots to a dedicated Google Drive account with rclone, one folder per
   employee and per day.
4. At 17:30 posts a report to a private Discord channel: summary stats, a contact sheet of the
   day's shots and a link to the day's Drive folder.

The daemon is `screenlogd`, the command-line tool is `screenlog`. Everything is plain Bash plus
standard Ubuntu packages; nothing is hidden from the users (`systemctl status screenlog` shows it).

This guide is for the owner. It assumes you can use a terminal but are not a Linux sysadmin.

## 1. What it captures, and what it does not

| Captured | Never captured |
|---|---|
| The whole screen (all monitors) as a JPEG, at random moments inside the capture hours | Keystrokes: idle time is one number per sample, not a key log |
| Seconds since the last keyboard or mouse input, with each sample | Audio, webcam, microphone |
| `locked` samples (no image) while the screen is locked | Browser history, clipboard, window titles |
| | Anything outside the capture hours, or while nobody is logged in |

The screenshots live in a root-only folder on the PC for about a week and in the dedicated
Drive for 60 days (both configurable). `docs/TEAM_NOTICE.md` is a plain-language notice you can
adapt and share with the team before the rollout.

## 2. One-time setup (on your Mac)

You need: a Mac with Homebrew, a Google account dedicated to the screenshots, a private Discord
channel, and this repository.

### 2.1 The dedicated Google account and your own OAuth client

Create a new Google account used only for the screenshots (for example
`screenlog@yourdomain`). Then create your own Google OAuth client for rclone. rclone's built-in
client ID is being retired by Google during 2026, so this step is required, not optional:

1. Open <https://console.cloud.google.com/> signed in as the dedicated account and create a
   project (any name, for example "screenlog").
2. **APIs & Services → Library**: enable the **Google Drive API**.
3. **APIs & Services → OAuth consent screen**: user type **External**, fill in the app name and
   your e-mail, scope `https://www.googleapis.com/auth/drive`, then **Publish** it. Its status
   must read **In production**. While it stays in **Testing**, Google expires the login after
   7 days and uploads stop.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**, type
   **Desktop app**. Note the client ID and the client secret.

### 2.2 rclone on the Mac

```bash
brew install rclone
rclone config --config ./config/rclone.conf
```

In the wizard: `n` (new remote), name **`screenlog-gdrive`**, storage **`drive`**, paste the
client ID and client secret from step 2.1, scope **`1`** (full `drive` access), leave the other
questions at their defaults, answer **`y`** to "Use web browser to automatically authenticate",
and log in **with the dedicated account**. Google shows a "this app isn't verified" screen once:
choose *Advanced → Go to screenlog*. Finish with `q`.

Then create the top-level folder and check it:

```bash
rclone --config ./config/rclone.conf mkdir screenlog-gdrive:Screenlog
rclone --config ./config/rclone.conf lsd screenlog-gdrive:
```

Finally, in the Drive web UI of the dedicated account, **share the `Screenlog` folder with your
own main Google account** (viewer is enough). The report links open with your own account; the
dedicated account's password never leaves the Mac and the PCs.

### 2.3 Discord

In your Discord server create a private channel (for example `#screenlog`), open its settings,
**Integrations → Webhooks → New Webhook**, and **Copy Webhook URL**. The URL looks like
`https://discord.com/api/webhooks/<numbers>/<long token>`; treat it like a password.

### 2.4 The configuration file

```bash
cp config/screenlog.conf.example config/screenlog.conf
```

Edit `config/screenlog.conf`: paste the webhook URL into `DISCORD_WEBHOOK_URL`, and adjust the
hours, report time, work days, retention and image settings if the defaults do not fit. Leave
`EMPLOYEE_NAME` and `EMPLOYEE_SLUG` out: they are set per PC by the installer. Every key is
explained in the file. Both `config/screenlog.conf` and `config/rclone.conf` are ignored by git.

### 2.5 Optional: a newer rclone

Ubuntu 24.04 ships rclone 1.60.1, which works. If you want the current release on the PCs, put
the official Debian package into `vendor/` and the installer uses it instead of the apt package:

```bash
V=1.75.2
mkdir -p vendor
curl -fsSLo vendor/rclone-v$V-linux-amd64.deb https://downloads.rclone.org/v$V/rclone-v$V-linux-amd64.deb
curl -fsSLo vendor/SHA256SUMS https://downloads.rclone.org/v$V/SHA256SUMS
(cd vendor && grep " rclone-v$V-linux-amd64.deb$" SHA256SUMS | shasum -a 256 -c -)   # must print: OK
```

The installer verifies the package against `vendor/SHA256SUMS` and refuses it on a mismatch.

### 2.6 Build the bundle

```bash
make bundle
```

This creates `dist/screenlog-<version>/` and `dist/screenlog-<version>.tar.gz` without any
secrets. Now copy the two secret files into it:

```bash
cp config/screenlog.conf config/rclone.conf dist/screenlog-1.0.0/config/
```

Copy the whole `dist/screenlog-1.0.0` folder to a USB stick or a private link.

## 3. Install on each PC

On the PC, as a user with sudo, with the bundle folder copied somewhere local (for example
`~/screenlog-1.0.0`):

```bash
cd ~/screenlog-1.0.0
sudo bash ./install.sh --name "Rahim Uddin"
```

Use `--slug <name>` as well when the display name has no ASCII letters (for example a name in
Bengali script): the slug is the Drive folder name. Add `--dry-run` to see every step without
changing anything, or `--reboot` to reboot automatically at the end.

The installer checks the OS, installs the packages, copies the app to `/opt/screenlog`, writes
the root-only config, checks Drive and the webhook, forces the Xorg session, blocks the Ubuntu
release upgrade, installs and starts the services, and prints a summary. Then:

1. Delete the bundle folder (it holds the secrets) and wipe the USB stick.
2. **Reboot**, log in as the employee.
3. Within about a minute a message appears in the Discord channel, with a screenshot attached:

   > ✅ Screenlog is running on Rahim Uddin's PC (dev-pc-03, v1.0.0)

If it does not, run `sudo screenlog doctor` on the PC and see `docs/TROUBLESHOOTING.md`.

## 4. Reading the report

Every day at 17:30 (and, if the PC was off or offline then, on the next hourly retry) the
channel receives, per PC:

```
📸 Rahim Uddin — Thu 15 Oct 2026
58 shots · 49 active (84%) · locked 6× · first 09:12 · last 17:24
⚠️ No samples 13:05–14:02
Full size: https://drive.google.com/drive/folders/…
dev-pc-03 · v1.0.0
```

with the contact sheet attached: one thumbnail per shot in time order, each with a caption bar,
**green** for an active shot (input in the last 5 minutes) and **amber** for an idle one
(`10:47 · idle 14m`). The header shows the name, the date, the shot count and the active
percentage. `locked`, `no session` and `error` counts appear only when they are not zero. The
"No samples" line lists every pause between two samples longer than 45 minutes: the PC was off,
asleep, logged out, or the service was stopped. On a work day with no samples at all the report is
`⚠️ No screenshots from Rahim Uddin today (dev-pc-03)`.

The "Full size" link opens the day's folder in Drive with your own Google account (the one the
Screenlog folder is shared with). Thumbnails are not meant to be readable; the full-size images
are.

**How much to read into the numbers.** With about 60 random samples a day, a single day's
active percentage has an uncertainty of roughly ±10 percentage points; over a week it is about
±5. A single screenshot says nothing. Look at patterns over days and weeks, not at single shots or
single days.

## 5. Everyday tasks

**Change the hours, the report time or the work days.** On the PC edit
`/etc/screenlog/screenlog.conf` (as root) and run:

```bash
sudo screenlog apply-config
```

It re-validates the file, re-renders the timer from `REPORT_TIME` and restarts the services.
Make the same change in the bundle's `config/screenlog.conf` on the Mac: the shared keys are
written from the bundle on every install, and the installer lists every key it resets.

**Rename an employee.** Edit `EMPLOYEE_NAME` in `/etc/screenlog/screenlog.conf` and run
`sudo screenlog apply-config`. The Drive folder (the slug) stays the same. To change the folder
as well, run `install.sh --name "New Name"` (optionally with `--slug`) from the bundle.

**Move a PC to a new employee.**

```bash
sudo screenlog upload                 # push every local day
sudo screenlog report --pending       # post what is still due
sudo /opt/screenlog/uninstall.sh --purge
cd ~/screenlog-1.0.0 && sudo bash ./install.sh --name "New Person"
```

**Update to a new version.** Build the new bundle on the Mac (`make bundle`, copy the two
config files in), copy it to the PC and run `sudo bash ./install.sh` again. No `--name` is
needed: the name, the slug, the state and the Drive token are kept. `--reannounce` sends the ✅
message again if you want a visible confirmation.

**Check a PC.**

| Command | What it tells you |
|---|---|
| `sudo screenlog status` | service and timer state, next report, today's counts, last sample, pending uploads and reports, the public config |
| `sudo screenlog doctor` | PASS / WARN / FAIL for every requirement; exit 1 on any FAIL |
| `sudo screenlog test` | takes a shot now, uploads it, posts `🧪 Test from <name>` with the image, prints timings |
| `sudo screenlog logs` | the last 200 journal lines (add `-f` to follow) |
| `sudo screenlog report --dry-run` | builds today's message and contact sheet in a temp dir without posting |
| `sudo screenlog upload` | uploads every local day now |

**Uninstall.**

```bash
sudo /opt/screenlog/uninstall.sh            # keeps /etc/screenlog and the local screenshots
sudo /opt/screenlog/uninstall.sh --purge    # removes them too
```

It stops and removes the services, the app and the CLI, and restores the GDM and
release-upgrade files from their backups. Nothing in Drive is touched.

## 6. Performance

Performance comes first: the app must never slow the PCs down. The budget and how to check it on
a real PC:

| What | Budget | How to check on the PC |
|---|---|---|
| Between samples | only a sleeping bash process: RSS under 10 MB, no CPU | `ps -o rss,pcpu,etime,cmd -C screenlogd` (RSS in kB), `systemd-cgls -u screenlog.service` (bash + sleep only) |
| Each sample (capture + encode) | under 1 s wall, under 0.5 s CPU, unthrottled | `sudo /usr/bin/time -v screenlog test`: "Elapsed (wall clock)" and "User time" + "System time" (the `capture:` line prints the capture alone; the rest is the upload and the post) |
| Each upload | rclone exits after every run; nothing stays resident | `pgrep -a rclone` prints nothing between uploads |
| Report run | under 60 s, peak memory under 300 MB, at `Nice=19` | `systemctl show screenlog-report.service -p MemoryPeak -p CPUUsageNSec --value` after 17:30, or `sudo /usr/bin/time -v screenlog report --dry-run --date $(date +%F)` |
| Hard caps | systemd limits: `CPUQuota=10%`, `MemoryMax=256M` for the sampler; `CPUQuota=50%`, `MemoryMax=400M` for the report | `systemctl status screenlog` shows `Memory: … (peak: …)`; `sudo systemd-cgtop -1 -n 5` shows live CPU and memory per unit |
| Disk | roughly 10–25 MB per day locally, pruned automatically | `du -sh /var/lib/screenlog/shots/*` |

Two things to know when reading the numbers. The `Memory:` line of `systemctl status` is the
cgroup's memory, which includes the page cache of the files the service just wrote, so it can read
tens of MB while the loop's own RSS (the `ps` column) is around 4 MB. And inside the service the
sampler is throttled to 10 % of one CPU, so a capture that takes 0.3 s of CPU takes about 3 s of
wall time there; that only stretches the encode, the screenshot itself is still a single instant.
A day that was never uploaded (PC offline all day) takes longer than 60 s to upload at the 1 MB/s
limit; the report service allows 30 minutes for that case.

## 7. Security

- The secrets (the webhook URL and the Drive token) live only in `/etc/screenlog/`, readable by
  root alone. Screenshots and state live in `/var/lib/screenlog/`, also root-only. The CLI never
  prints them and the logs redact them.
- The webhook URL is passed to curl through a private file, never on a command line.
- Delete the bundle folder after every install and wipe the USB stick (on the Mac: Disk Utility →
  Erase, or `diskutil secureErase`); it contains both secrets.
- Employees with sudo can stop the service or read the config. Nothing is hidden from them by
  design; if the service is stopped, the gaps show up in the report ("No samples …").
- Reports link to Drive folders that only accounts with access to the shared `Screenlog` folder
  can open; no public links are ever created.
- The release upgrade prompt is turned off because Ubuntu 26.04 drops the X11 session and would
  break capture. Security updates for 24.04 are unaffected.

## 8. Manual test checklist for the first real PC

Before: `make lint test test-integration` green on the Mac, the one-time setup done, the bundle
built with the two config files inside and copied to the PC (fresh Ubuntu 24.04, default
Wayland session, the employee logged in).

1. `sudo bash ./install.sh --name "Test User" --dry-run` prints every step as "would …", exit 0,
   and changes nothing.
2. `sudo bash ./install.sh --name "Test User"` exits 0; the summary shows the slug, "drive …
   reachable", "discord: webhook valid", Xorg "set now", upgrades "set now", the service active.
   Read the whole output once: no webhook URL and no token anywhere.
3. `ls -la /etc/screenlog` shows the folder 700 and both files 600, owned by root;
   `grep WaylandEnable /etc/gdm3/custom.conf` shows the active `WaylandEnable=false` line and the
   `.screenlog-bak` backup exists; `grep Prompt /etc/update-manager/release-upgrades` shows
   `Prompt=never`.
4. `sudo screenlog doctor` before the reboot: everything PASS except `session` (still Wayland).
5. Delete the bundle folder, eject the USB stick, reboot, log in.
6. Within about a minute the ✅ message with a screenshot arrives in Discord.
   `sudo screenlog status` shows `session: x11 (…)`, the service active, no pending reports.
7. `sudo screenlog doctor` is all PASS (WARN is acceptable for the clock sync).
   `screenlog doctor` without sudo says clearly that it needs root.
8. `sudo /usr/bin/time -v screenlog test`: a 🧪 message with an image arrives; the `capture:` line
   is under 1000 ms; "User time" + "System time" is under 0.5 s.
9. In Drive (your own account) open `Screenlog/<slug>/<today>/`: the ✅ shot and the test shot are
   there as `HH-MM-SS.jpg`, and code text in them is legible at 100 % zoom. Open the link in a
   private browser window: access denied (not public).
10. Lock the screen (Super+L) for a while, unlock, leave the PC idle for more than 5 minutes,
    then work normally. `sudo screenlog status` and `samples.csv` show `locked` rows without
    images, then shots with large idle values, then active shots.
11. `awk -F, 'NR>1 {print $1}' /var/lib/screenlog/shots/$(date +%F)/samples.csv` shows irregular
    gaps, all between `MIN_GAP_SECONDS` and `MAX_GAP_SECONDS`.
12. Between samples `ps -o rss,pcpu,cmd -C screenlogd` shows RSS under 10 MB and 0.0 % CPU;
    `systemd-cgls -u screenlog.service` shows only bash and sleep; `pgrep rclone` is empty.
13. The 17:30 report arrives (or set `REPORT_TIME` to a few minutes ahead with
    `sudo screenlog apply-config` and watch `systemctl list-timers screenlog-report.timer`): stats
    line, contact sheet with green and amber captions, the Drive link opens with your account,
    hostname and version in the footer. `/var/lib/screenlog/state/reported-days` lists today.
14. `sudo screenlog report --pending` again prints "nothing to do" and posts nothing;
    `sudo systemctl start screenlog-report.service` exits quickly and posts nothing.
15. Unplug the network, `sudo screenlog test`: the capture works, the upload fails gracefully,
    the service stays up; plug it back in, `sudo screenlog upload` (or wait for the next sample):
    the backlog goes up and `status` shows no pending uploads.
16. Reboot: the service is active without anyone logging in; after login no second ✅ message.
17. Power the PC off before 17:30, boot it the next morning: the previous day's report arrives
    within a few minutes of the boot.
18. Upgrade in place: bump `VERSION`, `make bundle`, copy, `sudo bash ./install.sh` without
    `--name`: the name and slug are kept, the services restart, no new ✅ (then `--reannounce`
    sends one).
19. `systemctl show screenlog -p CPUQuotaPerSecUSec -p MemoryMax --value` prints `100ms` and
    `268435456`; after a day `systemctl show screenlog-report.service -p MemoryPeak --value` is
    under 300 MB and `sudo screenlog logs` shows the report run took under 60 s.
20. After `LOCAL_RETENTION_DAYS` days, old local day folders disappear once uploaded and reported;
    after `REMOTE_RETENTION_DAYS` days, Drive files move to the trash.
21. `sudo /opt/screenlog/uninstall.sh`: services gone, `/opt/screenlog` and the CLI gone,
    `custom.conf` and `release-upgrades` restored, `/etc/screenlog` and `/var/lib/screenlog`
    kept, Drive untouched. Reinstall with `--name`: ✅ again. `uninstall.sh --purge` removes the
    two folders.

## 9. Development and tests

The code is Bash 5 for Ubuntu; it is written on the Mac and run only inside an `ubuntu:24.04`
container. Install a container runtime once (`brew install colima docker && colima start`), then:

```bash
make lint               # shellcheck over every script and test, zero warnings
make test               # bats unit tests
make test-integration   # Xvfb-backed tests: real capture, contact sheet, daemon, install
make bundle             # the folder and tarball for the PCs
```

The first run builds the test image (a few minutes). `docs/ARCHITECTURE.md` describes the
modules, the state files, the testing hooks and the decisions behind the design;
`docs/TROUBLESHOOTING.md` covers the problems you are likely to meet.
