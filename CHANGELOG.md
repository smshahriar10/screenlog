# Changelog

All notable changes to screenlog are recorded here. Versions follow `VERSION`.

## [1.0.0] - 2026-10-16

Initial release for Ubuntu 24.04 LTS desktops (GNOME, X11, amd64).

- Sampler daemon `screenlogd`: random exponential gaps (average `SHOTS_PER_HOUR`, clamped),
  capture only inside `CAPTURE_START`–`CAPTURE_END` while an unlocked X11 session is active,
  idle time per sample, `locked` / `no_session` / `unsupported_session` / `error` rows in
  `samples.csv`, one-time ✅ announcement after the first login.
- Uploads with rclone to `<DRIVE_ROOT>/<slug>/<YYYY-MM-DD>` in a dedicated Google Drive, whole
  day folders, serialised with a lock, retried on the next sample or report run.
- Daily Discord report at `REPORT_TIME` (hourly retries): stats, contact sheet with green/amber
  captions, Drive folder link, missing-day notice; idempotent per day.
- Local and Drive retention.
- CLI `screenlog`: status, test, report, upload, doctor, apply-config, logs, version, help.
- `install.sh` (idempotent install/upgrade, forces Xorg, blocks the release upgrade, optional
  vendored rclone) and `uninstall.sh`; `make bundle`.
- Test suite: ShellCheck-clean, bats unit and Xvfb integration tests in an `ubuntu:24.04` image.
