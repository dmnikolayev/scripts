[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Remove
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$WHPath   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WHScript = Join-Path $WHPath 'WindowsHealth.ps1'

$Tasks = @(
    [pscustomobject]@{ Id=1; Name='Windows Updates Check';   Schedule='Daily 09:00';  Module='Update';   Mode='Check';   Type='Daily';  At='09:00'; Day=$null },
    [pscustomobject]@{ Id=2; Name='Windows Defender Check';  Schedule='Daily 09:10';  Module='Defender'; Mode=$null;     Type='Daily';  At='09:10'; Day=$null },
    [pscustomobject]@{ Id=3; Name='Windows Time Check';      Schedule='Daily 09:20';  Module='Time';     Mode=$null;     Type='Daily';  At='09:20'; Day=$null },
    [pscustomobject]@{ Id=4; Name='Windows Updates Install'; Schedule='Sunday 18:00'; Module='Update';   Mode='Install'; Type='Weekly'; At='18:00'; Day='Sunday' },
    [pscustomobject]@{ Id=5; Name='Windows Updates Reboot';  Schedule='Sunday 20:00'; Module='Update';   Mode='Reboot';  Type='Weekly'; At='20:00'; Day='Sunday' },
    [pscustomobject]@{ Id=6; Name='Windows Updates CleanUp'; Schedule='Monday 03:00'; Module='Update';   Mode='Cleanup'; Type='Weekly'; At='03:00'; Day='Monday' }
)

function Header {
    Clear-Host
    Write-Host ""
    Write-Host "Windows Health - Scheduler Setup" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor DarkCyan
    Write-Host ("Host : {0}" -f $env:COMPUTERNAME)
    Write-Host ("Path : {0}" -f $WHPath)
    Write-Host ""
}

function Assert-Ready {
    if (-not (Test-Path $WHScript)) {
        throw "WindowsHealth.ps1 not found next to Install-Scheduler.ps1"
    }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator."
    }
}

function Get-ActionArgs($t) {
    $cmd = "& '$WHScript' -Module $($t.Module)"
    if ($t.Mode) { $cmd += " -Mode $($t.Mode)" }
    return ('-NoProfile -ExecutionPolicy Bypass -Command "{0}"' -f $cmd)
}

function Get-Trigger($t) {
    if ($t.Type -eq 'Daily') {
        return New-ScheduledTaskTrigger -Daily -At $t.At
    }
    return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $t.Day -At $t.At
}

function Install-One($t) {
    if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
        Write-Host ("Replacing: {0}" -f $t.Name) -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
    } else {
        Write-Host ("Creating : {0}" -f $t.Name)
    }

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument (Get-ActionArgs $t) `
        -WorkingDirectory $WHPath

    $trigger = Get-Trigger $t

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    Register-ScheduledTask `
        -TaskName $t.Name `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings | Out-Null

    Write-Host ("OK       : {0} [{1}]" -f $t.Name,$t.Schedule) -ForegroundColor Green
}

function Show-Tasks {
    Header
    $rows = foreach ($t in $Tasks) {
        $task = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) {
            $info = Get-ScheduledTaskInfo -TaskName $t.Name -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Task=$t.Name; Installed='YES'; State=$task.State; Schedule=$t.Schedule
                NextRun=if ($info.NextRunTime.Year -gt 2000) { $info.NextRunTime } else { $null }
                LastResult=$info.LastTaskResult
            }
        } else {
            [pscustomobject]@{ Task=$t.Name; Installed='NO'; State='-'; Schedule=$t.Schedule; NextRun=$null; LastResult=$null }
        }
    }
    $rows | Format-Table -AutoSize
}

function Choose-Ids {
    Write-Host ""
    foreach ($t in $Tasks) {
        $installed = if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) { 'installed' } else { 'not installed' }
        Write-Host ("[{0}] {1,-30} {2,-16} ({3})" -f $t.Id,$t.Name,$t.Schedule,$installed)
    }
    Write-Host ""
    $raw = Read-Host "Enter numbers separated by comma (example: 1,2,3)"
    $ids = @($raw -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^\d+$'} | ForEach-Object {[int]$_} | Select-Object -Unique)
    return @($Tasks | Where-Object {$ids -contains $_.Id})
}

function Remove-Interactive {
    Header
    Write-Host "[A] Remove ALL Windows Health tasks"
    Write-Host "[S] Select tasks to remove"
    Write-Host "[0] Cancel"
    Write-Host ""
    $c = (Read-Host "Selection").Trim()

    if ($c -eq '0') { return }
    if ($c -match '^[Aa]$') { $selected = @($Tasks) }
    elseif ($c -match '^[Ss]$') { $selected = @(Choose-Ids) }
    else { Write-Host "Cancelled."; return }

    foreach ($t in $selected) {
        if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            Write-Host ("Removed: {0}" -f $t.Name) -ForegroundColor Green
        }
    }
}

try {
    Assert-Ready

    if ($List)   { Show-Tasks; exit 0 }
    if ($Remove) { Remove-Interactive; exit 0 }

    while ($true) {
        Header
        Write-Host "[A] Install ALL recommended tasks"
        Write-Host "[S] Select individual tasks"
        Write-Host "[L] List current tasks"
        Write-Host "[R] Remove tasks"
        Write-Host "[0] Cancel"
        Write-Host ""
        $choice = (Read-Host "Selection").Trim()

        if ($choice -eq '0') { exit 0 }
        if ($choice -match '^[Ll]$') {
            Show-Tasks
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        if ($choice -match '^[Rr]$') {
            Remove-Interactive
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }
        if ($choice -match '^[Aa]$') { $selected = @($Tasks); break }
        if ($choice -match '^[Ss]$') { $selected = @(Choose-Ids); break }

        Write-Host "Invalid selection." -ForegroundColor Yellow
        Start-Sleep 1
    }

    if (-not $selected -or $selected.Count -eq 0) {
        Write-Host "No valid tasks selected." -ForegroundColor Yellow
        exit 0
    }

    Header
    Write-Host "The following tasks will be created/replaced:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($t in $Tasks) {
        $mark = if ($selected.Id -contains $t.Id) { '[x]' } else { '[ ]' }
        Write-Host ("{0} {1,-30} {2}" -f $mark,$t.Name,$t.Schedule)
    }
    Write-Host ""
    Write-Host "Existing tasks with the same names will be replaced." -ForegroundColor Yellow
    $ok = (Read-Host "Continue? [Y/N]").Trim()
    if ($ok -notmatch '^[Yy]$') { exit 0 }

    Write-Host ""
    foreach ($t in $selected) { Install-One $t }

    Write-Host ""
    Write-Host "Scheduler setup completed." -ForegroundColor Green
    Write-Host ""
    Show-Tasks
    Write-Host ""
    Write-Host "Safe manual tests:" -ForegroundColor DarkGray
    Write-Host '  Start-ScheduledTask -TaskName "Windows Updates Check"'
    Write-Host '  Start-ScheduledTask -TaskName "Windows Defender Check"'
    Write-Host '  Start-ScheduledTask -TaskName "Windows Time Check"'
}
catch {
    Write-Host ""
    Write-Host ("Scheduler setup failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
