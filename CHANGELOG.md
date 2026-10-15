# Changelog

All notable changes to screenlog are recorded here.

## [1.0.0] - 2026-10-15

Initial release.

- Sampler daemon (`screenlogd`): random-gap screenshots during capture hours, idle time, lock detection.
- Upload to Google Drive with rclone, one folder per employee and day.
- Daily Discord report with stats, contact sheet and Drive folder link.
- CLI (`screenlog`): status, test, report, upload, doctor, apply-config, logs, version, help.
- `install.sh` / `uninstall.sh`, systemd units, `make bundle`.
