# Changelog

## 0.8.1
- Added host-local `Config\ExtraCleanup.txt`; the real file is ignored by Git.
- Added `MinFileSizeMB` and recursive filters for extra cleanup rules.
- Extra cleanup removes files only; the configured directory is never deleted.
- Locked/in-use extra files are counted as `Skipped`, not `Errors`.
- Added `wh.cleanup.extra_mb` Zabbix metric.
- Added `Install-Scheduler.ps1` to the package.
- Keeps native 300-second reboot warning without `msg.exe`.

## 0.8.0
- Split Zabbix templates into Windows Health, Windows Time and Microsoft Defender.
- Slim Time and Defender sender metrics to match their templates.
- Separate Cleanup `Skipped` from real `Errors`.
- Cleanup locked/protected files no longer create WARNING/FAILED.
- Cleanup result codes: 1 Success, 2 Success with skipped files, 3 Failed.
- Added `wh.cleanup.skipped` and `wh.cleanup.last_run`.
- Cleanup Zabbix trigger only fires on result=3.
- Removed msg.exe reboot notification.
- Native Windows reboot warning in Ukrainian; fixed 300-second grace period.
- Added Named Mutex protection against overlapping runs.
- Version remains a single source of truth in `VERSION`.
- Added GitHub README, docs and .gitignore.
