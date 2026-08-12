# Windows Health

PowerShell tool for controlled Windows maintenance and Zabbix monitoring.

**Version:** 0.8.0  
**Targets:** Windows Server 2016+, Windows 10/11, PowerShell 5.1+, Zabbix 7.0.

## Modules

```powershell
.\WindowsHealth.ps1 -Module Update -Mode Check
.\WindowsHealth.ps1 -Module Update -Mode Install
.\WindowsHealth.ps1 -Module Update -Mode Reboot
.\WindowsHealth.ps1 -Module Update -Mode Cleanup
.\WindowsHealth.ps1 -Module Time
.\WindowsHealth.ps1 -Module Defender
```

### Update
- `Check` checks available updates, last patch age and Pending Reboot.
- `Install` downloads and installs Windows Updates and shows minimal live console progress.
- `Reboot` is conditional. If Pending Reboot is false, nothing happens. If true, Windows displays a native Ukrainian warning and reboots after 5 minutes.
- `Cleanup` cleans Windows Update cache, Windows Temp and User Temp files older than 7 days.

### Cleanup safety

Cleanup touches only:

```text
C:\Windows\SoftwareDistribution\Download
C:\Windows\Temp
C:\Users\*\AppData\Local\Temp
```

User profile roots are never deleted.

Locked/protected files are counted as `Skipped`, not as real errors.

```text
Cleanup result:
1 = Success
2 = Success with skipped files
3 = Failed
```

The Zabbix trigger fires only for `Failed`.

### Reboot

```text
Pending Reboot = NO  -> no reboot
Pending Reboot = YES -> native Windows warning -> 300 sec -> reboot
```

Message:

> Планове перезавантаження після встановлення оновлень Windows. Комп'ютер буде перезавантажено протягом 5 хвилин. Будь ласка, збережіть свою роботу та вийдіть із системи.

`msg.exe` is not used.

### Concurrency

A Named Mutex prevents overlapping Windows Health operations. If an Install is still running and another scheduled task starts, the second run exits with:

```text
Status......... SKIPPED
```

## Recommended maintenance schedule

| Time | Task |
|---|---|
| Daily | Update Check |
| Sunday 18:00 | Install |
| Sunday 20:00 | Conditional Reboot |
| Sunday 23:00 | DB / other maintenance |
| Monday 03:00 | Cleanup |
| 08:00 | Workday starts |

Reboot can be scheduled every week because it only runs when Pending Reboot is set.

For Domain Controllers, stagger Install windows between DCs.

## Task Scheduler

Program:

```text
powershell.exe
```

Examples:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Update -Mode Check
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Update -Mode Install
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Update -Mode Reboot
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Update -Mode Cleanup
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Time
-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\WindowsHealth\WindowsHealth.ps1" -Module Defender
```

Recommended account: `NT AUTHORITY\SYSTEM`.

## Zabbix

Templates in `Templates/Zabbix`:

- `Windows Health.yaml` — Update / Cleanup / Reboot.
- `Windows Time.yaml` — sync status, source, stratum, sync age, timezone, UTC offset.
- `Microsoft Defender.yaml` — AV enabled, real-time, signatures, PUA, Tamper.

Time and Defender templates intentionally avoid service-state metrics already available from the standard Windows Zabbix template.

Configure `Config/config.json`:

```json
"Zabbix": {
  "Server": "10.10.1.5",
  "Port": 10051,
  "Hostname": "",
  "SenderPath": ""
}
```

When `Hostname` is empty, the Windows computer name is used. The Zabbix **Host name** must match it.

## Downloaded files / Execution Policy

If Windows marks downloaded `.ps1` files as Internet files:

```powershell
Get-ChildItem C:\scripts\WindowsHealth -Recurse -File | Unblock-File
```

This removes Mark-of-the-Web from the project files; it does not change the global Execution Policy.

## Runtime data

```text
Logs\
State\
Temp\
```

These folders are ignored by Git.

## Project layout

```text
WindowsHealth\
├── WindowsHealth.ps1
├── VERSION
├── Config\
├── Core\
├── Modules\
│   ├── Update\
│   ├── Time\
│   └── Defender\
├── Providers\
├── Templates\Zabbix\
└── Docs\
```

Test changes on a non-critical system before broad deployment.
