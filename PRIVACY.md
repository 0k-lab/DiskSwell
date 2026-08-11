# Privacy

Last updated: 2026-08-11

DiskSwell performs monitoring and history processing entirely on your Mac. It has no telemetry, analytics, accounts, or DiskSwell-operated cloud service. Its only network feature is the updater described below. It does not upload files, file contents, paths, monitoring history, browsing history, or website data.

## Updates

Automatic update checks are enabled by default and can be disabled in Settings. When enabled, DiskSwell requests the latest public release metadata from `api.github.com` at most once per day. A manual **Check for Updates…** performs the same request even when automatic checks are disabled.

DiskSwell downloads `DiskSwell.pkg` and its SHA-256 file from GitHub only after the user chooses **Download and Install**. It verifies the checksum locally, then asks macOS Installer to open the signed and notarized package. These requests contain normal network metadata, such as the IP address and DiskSwell version in the user-agent, but no monitoring data.

## Local processing

DiskSwell watches configured local folders through macOS FSEvents and reads file metadata needed to estimate size and growth. For Safari/WebKit WAL files, it may read a small nearby text metadata file to derive a best-effort website hostname. It does not read Safari databases, localStorage values, or file contents generally.

DiskSwell stores its bounded history at:

```text
~/Library/Application Support/DiskSwell/history.sqlite3
```

That local database can contain:

- file and directory paths;
- item type and detector classification;
- an optional Safari/WebKit hostname when locally discoverable;
- size samples and timestamps;
- anomaly severity, growth, interval, reason, and resolution time.

History is automatically downsampled and removed according to the retention policy documented in the README. **Reset DiskSwell Data…** removes only this local database and in-memory tracked state; it does not delete or modify monitored files or unrelated preferences. Deleting DiskSwell's Application Support folder while the app is not running also removes its stored history.

## Diagnostics and notifications

Debug builds log diagnostics to the macOS unified log. Release diagnostics are off unless DiskSwell is launched with `DISKSWELL_DIAGNOSTICS=1`; error details are marked private and counters are public within the local unified log.

The optional Settings diagnostics view uses only bounded counters already held in memory. **Copy Diagnostics** writes a bounded plain-text report to the local clipboard, replaces the home directory with `~`, redacts usernames in user-home paths, and excludes file contents, browser-storage values, credentials, and secrets.

Notifications are delivered by macOS. Permission is requested only when DiskSwell first has an anomaly to deliver. DiskSwell does not send notification data to a DiskSwell-operated service.

## Permissions

DiskSwell uses the current user's filesystem access and macOS privacy controls. It does not install a privileged helper and does not automatically request Full Disk Access. If macOS denies a monitored location, DiskSwell reports limited access and continues monitoring locations it can read.
