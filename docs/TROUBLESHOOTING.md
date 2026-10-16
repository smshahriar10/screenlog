# Troubleshooting

Start with these two commands on the PC; most problems show up in their output:

```bash
sudo screenlog doctor     # PASS / WARN / FAIL per check, exit 1 on any FAIL
sudo screenlog logs       # the last 200 journal lines of the sampler and the report
```

`sudo screenlog status` shows the service state, the next report time, today's counts and what is
still waiting to upload or to be reported.

## No ✅ message after install

The ✅ message is sent once, within about a minute of the first login after the install.

1. `sudo screenlog status` — is `service:` active? If not: `sudo screenlog logs`.
2. `session:` must say `x11 (...)`. `wayland (unsupported)` means the PC did not reboot after
   the install, or someone chose the Wayland session at login. Reboot, or pick **Ubuntu on Xorg**
   from the gear icon on the login screen.
3. `session: none` means nobody is logged in on the local screen (SSH sessions do not count).
4. `sudo screenlog doctor` — a `FAIL webhook` means the webhook was deleted or mistyped (see
   Discord below); a `FAIL drive` means the Drive token or folder is wrong.
5. The announcement is retried every hour while it has not succeeded. To send it again on demand:
   `sudo bash ./install.sh --reannounce` from the bundle, or
   `sudo rm /var/lib/screenlog/state/setup-announced && sudo systemctl restart screenlog`.

## The session is Wayland

Capture needs an X11 (Xorg) session. The installer sets `WaylandEnable=false` in
`/etc/gdm3/custom.conf`; it takes effect at the next GDM start, so the PC must reboot after the
install. Check with `sudo screenlog doctor` (`wayland` and `session` checks). If the line is
missing, re-run `install.sh`; if an employee re-enabled Wayland by hand, the next upgrade sets it
again. Until then every sample is logged as `unsupported_session` and the daily report shows it.

## The Drive token expired or was revoked

Symptoms: `sudo screenlog doctor` shows `FAIL drive` with `invalid_grant`, `unauthorized_client`
or `token`; reports carry `⚠️ Drive upload failed`; `status` shows pending uploads growing.

Causes and fixes:

- **The Google OAuth consent screen is still in "Testing".** Google expires those tokens after 7
  days. Set the consent screen to **In production** (README, one-time setup), then reconnect.
- **rclone's shared client ID stopped working.** Google retires it during 2026; `doctor` warns
  with `rclone client_id`. Create your own OAuth client (README) and reconnect.
- **The dedicated account changed its password or revoked access.** Reconnect.

To reconnect, on the Mac:

```bash
rclone config --config ./config/rclone.conf reconnect screenlog-gdrive:
```

Then copy the new `config/rclone.conf` into the bundle's `config/` folder and run `install.sh`
again on each PC. The installer keeps the PC's own token only while it still works, so the new
one replaces it. Pending days upload automatically afterwards (`sudo screenlog upload` forces it).

## Discord 401, 404 or 429

- **401 / 404**: the webhook was deleted, regenerated or mistyped. `doctor` shows `FAIL webhook:
  HTTP 404`. Create a new webhook in the channel, put its URL into the bundle's
  `config/screenlog.conf` and run `install.sh` again (or edit `/etc/screenlog/screenlog.conf` on
  the PC and run `sudo screenlog apply-config`). After a 404 the daemon stops posting until it is
  restarted; `apply-config` restarts it.
- **429**: rate limited. The program waits the time Discord asks for and retries by itself. Many
  PCs reporting at the same second is spread out by the timer's random delay; nothing to do.
- **Network errors**: the post is retried 4 times over about 15 minutes; a day that could not be
  posted stays pending and the hourly timer posts it on its next run.

## No shots: outside hours, locked, or no session

Every sample writes a row to `/var/lib/screenlog/shots/<date>/samples.csv` with a status:

| status | meaning |
|---|---|
| `shot` | a screenshot was taken |
| `locked` | the screen was locked (no screenshot, by design) |
| `no_session` | nobody is logged in on the local screen |
| `unsupported_session` | the session is Wayland or a text console |
| `error` | the capture failed; the `detail` column says why |

Outside `CAPTURE_START`–`CAPTURE_END` nothing is written at all. The report lists `locked`,
`no session` and `error` counts, so a day full of `locked` rows means the screen stayed locked.
`error` rows with `no working DISPLAY` or `xprintidle failed` usually mean the X11 session could
not be reached; `sudo screenlog doctor` and `sudo screenlog test` show the cause.

## The wrong time zone

Capture hours and the report time are the PC's local time. `doctor` warns when the time zone is
not Asia/Dhaka or the clock is not synchronised:

```bash
sudo timedatectl set-timezone Asia/Dhaka
sudo timedatectl set-ntp true
```

The CSV timestamps carry the offset (`+06:00`), so earlier samples stay unambiguous.

## A full disk

`doctor` warns below 2 GB free and fails below 500 MB on `/var/lib/screenlog`. The app itself uses
about 10–25 MB per day and deletes local days older than `LOCAL_RETENTION_DAYS` once they are
uploaded and reported. If uploads are failing, local days accumulate: fix the Drive problem (see
above) and run `sudo screenlog upload`. Free space elsewhere is the owner's call; screenlog never
deletes anything it has not uploaded.

## The report did not arrive at 17:30

1. `sudo screenlog status` — `report timer:` must be active with a `next:` time.
2. `sudo systemctl list-timers screenlog-report.timer` shows the next run.
3. `sudo screenlog logs` shows what the last run did. A day that could not be posted stays
   pending and is retried every hour; the PC being off at 17:30 posts the report shortly after the
   next boot (`Persistent=true`).
4. `sudo screenlog report --dry-run --date $(date +%F)` builds today's message and contact sheet
   without posting and prints where it put them (a plain `--dry-run` only previews what the timer
   would post right now, which before `REPORT_TIME` is "nothing to do").

## Reading `doctor` output

Each line is `PASS|WARN|FAIL <check>: <detail>`; the last line counts them and the exit code is 1
when anything failed. Checks in order: `os`, `arch`, `wayland` (Xorg forced), `session`,
`upgrades` (release prompt off), `packages`, `rclone` (version ≥ 1.60), `config`, `config mode`
(root-only files), `rclone client_id` / `rclone remote`, `drive`, `webhook`, the two units,
`last report run`, `disk`, `time zone`, `clock sync`, `last sample`. `WARN` lines do not stop the
app; `FAIL` lines name what to fix and usually say "re-run install.sh" or "sudo screenlog
apply-config".

## Exit codes

| code | meaning |
|---|---|
| 0 | ok |
| 1 | runtime failure (details in the output or `screenlog logs`) |
| 2 | usage error (wrong option) |
| 3 | the configuration is invalid (the `config:` lines say which key) |
| 4 | the command must run as root |
| 5 | another report run holds the lock |
| 6 | a dependency or preflight check failed (OS, architecture, packages, internet) |
| 7 | a remote check failed (Drive or the Discord webhook) |
| 8 | editing a system file or the units failed |
| 130 | interrupted with Ctrl-C |
