Set-StrictMode -Version 2.0

# Windows 10/11 and Windows Server 2016+.

function Get-WHAvailableUpdates {
    [CmdletBinding()]
    param()

    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()

    # Respect the update source/policy already configured on the server (Windows Update or WSUS).
    $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
    $result = $searcher.Search($criteria)

    $updates = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $u = $result.Updates.Item($i)
        $kb = @()
        for ($k = 0; $k -lt $u.KBArticleIDs.Count; $k++) {
            $kb += ('KB' + $u.KBArticleIDs.Item($k))
        }

        Write-WHLog -Message ("Update found: {0}; KB={1}" -f $u.Title, ($kb -join ';'))

        $updates += [pscustomobject]@{
            Title = [string]$u.Title
            KB = $kb
            RebootRequired = [bool]$u.RebootRequired
            EulaAccepted = [bool]$u.EulaAccepted
            UpdateObject = $u
        }
    }

    return @($updates)
}

function Get-WHLastSuccessfulUpdate {
    [CmdletBinding()]
    param()

    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()

        if ($count -gt 0) {
            $take = [Math]::Min($count, 200)
            $history = $searcher.QueryHistory(0, $take)

            # Operation 1 = Installation, ResultCode 2 = Succeeded, 3 = Succeeded with errors.
            $successful = @()
            for ($i = 0; $i -lt $history.Count; $i++) {
                $h = $history.Item($i)
                if ($h.Operation -eq 1 -and ($h.ResultCode -eq 2 -or $h.ResultCode -eq 3)) {
                    $successful += $h
                }
            }

            if ($successful.Count -gt 0) {
                return ($successful | Sort-Object Date -Descending | Select-Object -First 1)
            }
        }
    }
    catch {
        Write-WHLog -Level WARNING -Message ("WUA history query failed: {0}" -f $_.Exception.Message)
    }

    # Fallback for older/odd WUA histories.
    try {
        $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            return [pscustomobject]@{
                Date = [datetime]$hf.InstalledOn
                Title = [string]$hf.HotFixID
                ResultCode = 2
                Operation = 1
            }
        }
    } catch {}

    return $null
}

function Install-WHUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Updates
    )

    if (-not $Updates -or $Updates.Count -eq 0) {
        return [pscustomobject]@{
            Result = 4
            InstalledCount = 0
            FailedCount = 0
            RebootRequired = (Test-WHPendingReboot)
            Error = ''
        }
    }

    $collection = New-Object -ComObject 'Microsoft.Update.UpdateColl'

    foreach ($entry in $Updates) {
        $u = $entry.UpdateObject
        if (-not $u.EulaAccepted) {
            try { $u.AcceptEula() } catch {}
        }
        [void]$collection.Add($u)
    }

    try {
        Write-WHLog -Message ("Downloading {0} update(s)." -f $collection.Count)
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $collection
        $downloadResult = $downloader.Download()
    Write-Host 'Downloading..... done'

        # Build a collection containing only successfully downloaded updates.
        $installCollection = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        for ($i = 0; $i -lt $collection.Count; $i++) {
            $u = $collection.Item($i)
            if ($u.IsDownloaded) {
                [void]$installCollection.Add($u)
            }
        }

        if ($installCollection.Count -eq 0) {
            return [pscustomobject]@{
                Result = 2
                InstalledCount = 0
                FailedCount = $collection.Count
                RebootRequired = (Test-WHPendingReboot)
                Error = 'No updates were downloaded successfully.'
            }
        }

        Write-Host 'Installing...... please wait'
    Write-WHLog -Message ("Installing {0} downloaded update(s)." -f $installCollection.Count)
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $installCollection
        $installResult = $installer.Install()
        Write-Host 'Installing...... done'

        $ok = 0
        $failed = 0
        $partial = 0

        for ($i = 0; $i -lt $installCollection.Count; $i++) {
            $r = $installResult.GetUpdateResult($i)
            if ($r.ResultCode -eq 2) {
                $ok++
            } elseif ($r.ResultCode -eq 3) {
                $partial++
            } else {
                $failed++
            }
        }

        $resultCode = 1
        if ($failed -gt 0 -and ($ok -gt 0 -or $partial -gt 0)) { $resultCode = 3 }
        elseif ($partial -gt 0) { $resultCode = 3 }
        elseif ($failed -gt 0 -and $ok -eq 0) { $resultCode = 2 }

        return [pscustomobject]@{
            Result = $resultCode
            InstalledCount = ($ok + $partial)
            FailedCount = $failed
            RebootRequired = [bool]($installResult.RebootRequired -or (Test-WHPendingReboot))
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Result = 2
            InstalledCount = 0
            FailedCount = $Updates.Count
            RebootRequired = (Test-WHPendingReboot)
            Error = $_.Exception.Message
        }
    }
}

function Invoke-WHUpdateCheck {
    [CmdletBinding()]
    param()

    Write-WHLog -Message 'Update check started.'
    $updates = @(Get-WHAvailableUpdates)
    Write-Host 'Searching....... done'
    Write-Host ('Updates......... {0}' -f $updates.Count)
    $last = Get-WHLastSuccessfulUpdate
    $pending = Test-WHPendingReboot
    Write-WHLog -Message ("Updates found: {0}" -f $updates.Count)
    Write-WHLog -Message ("Pending reboot: {0}" -f $pending)

    $kb = @($updates | ForEach-Object { $_.KB } | Where-Object { $_ } | Sort-Object -Unique)
    $now = Get-Date

    $lastDate = $null
    $lastAge = -1
    if ($last -and $last.Date) {
        $lastDate = [datetime]$last.Date
        $lastAge = [int][Math]::Floor(($now - $lastDate).TotalDays)
    }

    return [pscustomobject]@{
        Mode = 'Check'
        Timestamp = $now
        Available = [int]($updates.Count -gt 0)
        Count = [int]$updates.Count
        KB = ($kb -join ';')
        PendingReboot = [int]$pending
        Result = 1
        LastPatchAgeDays = $lastAge
        LastPatchDate = $lastDate
        LastInstall = $lastDate
        Error = ''
    }
}

function Invoke-WHUpdateInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config
    )

    Write-Host 'Searching....... please wait'
    Write-WHLog -Message 'Searching for updates before installation.'
    $updates = @(Get-WHAvailableUpdates)
    Write-Host 'Searching....... done'
    Write-Host ('Updates......... {0}' -f $updates.Count)
    $kb = @($updates | ForEach-Object { $_.KB } | Where-Object { $_ } | Sort-Object -Unique)

    $install = Install-WHUpdates -Updates $updates

    # Re-scan after installation so Zabbix receives the actual remaining count.
    $remaining = @()
    try {
        $remaining = @(Get-WHAvailableUpdates)
    } catch {
        Write-WHLog -Level WARNING -Message ("Post-install scan failed: {0}" -f $_.Exception.Message)
    }

    $last = Get-WHLastSuccessfulUpdate
    $now = Get-Date
    $lastDate = $null
    $lastAge = -1

    if ($last -and $last.Date) {
        $lastDate = [datetime]$last.Date
        $lastAge = [int][Math]::Floor(($now - $lastDate).TotalDays)
    }

    $pending = [bool]($install.RebootRequired -or (Test-WHPendingReboot))

    if ($pending -and $Config.Update.AutoReboot) {
        Write-WHLog -Level WARNING -Message 'AutoReboot=true, but reboot is intentionally disabled in v0.1.0 until production testing is complete.'
        # AFTER TESTING, enable the next line:
        # Restart-Computer -Force
    }

    return [pscustomobject]@{
        Mode = 'Install'
        Timestamp = $now
        Available = [int]($remaining.Count -gt 0)
        Count = [int]$remaining.Count
        KB = ($kb -join ';')
        PendingReboot = [int]$pending
        Result = [int]$install.Result
        LastPatchAgeDays = $lastAge
        LastPatchDate = $lastDate
        LastInstall = $lastDate
        InstalledCount = [int]$install.InstalledCount
        FailedCount = [int]$install.FailedCount
        Error = [string]$install.Error
    }
}

function Convert-WHUpdateResultToMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Result
    )

    $lastCheckUnix = ConvertTo-WHUnixTime -DateTime $Result.Timestamp
    $lastInstallUnix = 0
    if ($Result.LastInstall) {
        $lastInstallUnix = ConvertTo-WHUnixTime -DateTime $Result.LastInstall
    }

    return @(
        [pscustomobject]@{ Key='wh.update.available'; Value=$Result.Available },
        [pscustomobject]@{ Key='wh.update.count'; Value=$Result.Count },
        [pscustomobject]@{ Key='wh.update.kb'; Value=$Result.KB },
        [pscustomobject]@{ Key='wh.update.pending_reboot'; Value=$Result.PendingReboot },
        [pscustomobject]@{ Key='wh.update.result'; Value=$Result.Result },
        [pscustomobject]@{ Key='wh.update.last_patch_age'; Value=$Result.LastPatchAgeDays },
        [pscustomobject]@{ Key='wh.update.last_check'; Value=$lastCheckUnix },
        [pscustomobject]@{ Key='wh.update.last_install'; Value=$lastInstallUnix },
        [pscustomobject]@{ Key='wh.update.last_error'; Value=$Result.Error }
    )
}


function Get-WHDirectorySizeBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }

    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Measure-Object Length -Sum).Sum
        if ($null -eq $sum) { return [int64]0 }
        return [int64]$sum
    }
    catch { return [int64]0 }
}

function Remove-WHDirectoryContents {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ FreedBytes=[int64]0; Skipped=0 }
    }

    $before = Get-WHDirectorySizeBytes -Path $Path
    $skipped = 0

    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            $skipped++
            Write-WHLog -Level INFO -Message ("Cleanup skipped locked/protected item: {0}" -f $item.FullName)
        }
    }

    $after = Get-WHDirectorySizeBytes -Path $Path
    $freed = [Math]::Max([int64]0, ([int64]$before - [int64]$after))
    return [pscustomobject]@{ FreedBytes=[int64]$freed; Skipped=[int]$skipped }
}

function Remove-WHOldUserTemp {
    [CmdletBinding()]
    param([int]$OlderThanDays = 7)

    $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
    $totalFreed = [int64]0
    $skipped = 0
    $profiles = 0
    $profileRoot = Join-Path $env:SystemDrive 'Users'

    if (-not (Test-Path -LiteralPath $profileRoot)) {
        return [pscustomobject]@{ FreedBytes=[int64]0; Skipped=0; Profiles=0 }
    }

    foreach ($profile in @(Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $tempPath = Join-Path $profile.FullName 'AppData\Local\Temp'
        if (-not (Test-Path -LiteralPath $tempPath)) { continue }
        $profiles++

        foreach ($file in @(Get-ChildItem -LiteralPath $tempPath -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -lt $cutoff -and
                -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
            })) {
            $len = [int64]$file.Length
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $totalFreed += $len
            }
            catch {
                $skipped++
                Write-WHLog -Level INFO -Message ("Cleanup skipped locked/protected user temp file: {0}" -f $file.FullName)
            }
        }

        $dirs = @(Get-ChildItem -LiteralPath $tempPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Sort-Object { $_.FullName.Length } -Descending)

        foreach ($dir in $dirs) {
            try {
                if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

    return [pscustomobject]@{
        FreedBytes=[int64]$totalFreed
        Skipped=[int]$skipped
        Profiles=[int]$profiles
    }
}

function Invoke-WHUpdateCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Config)

    Write-WHLog -Message 'Update cleanup started.'

    $sdFreed = [int64]0
    $winTempFreed = [int64]0
    $userTempFreed = [int64]0
    $skipped = 0
    $errors = 0
    $profiles = 0

    $serviceState = @{}
    foreach ($name in @('bits','wuauserv')) {
        try { $serviceState[$name] = [string](Get-Service -Name $name -ErrorAction Stop).Status }
        catch { $serviceState[$name] = 'Unknown' }
    }

    if ($Config.Update.CleanupSoftwareDistribution) {
        try {
            foreach ($name in @('bits','wuauserv')) {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Stopped') {
                    Stop-Service -Name $name -Force -ErrorAction Stop
                    $deadline = (Get-Date).AddSeconds(30)
                    do {
                        Start-Sleep -Milliseconds 500
                        $current = Get-Service -Name $name -ErrorAction SilentlyContinue
                    } while ($current -and $current.Status -ne 'Stopped' -and (Get-Date) -lt $deadline)
                    if ($current -and $current.Status -ne 'Stopped') {
                        throw ("Service {0} did not stop within 30 seconds." -f $name)
                    }
                }
            }

            $r = Remove-WHDirectoryContents -Path (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
            $sdFreed = $r.FreedBytes
            $skipped += $r.Skipped
            Write-WHLog -Message ("SoftwareDistribution cleanup freed {0:N0} MB." -f ($sdFreed / 1MB))
        }
        catch {
            $errors++
            Write-WHLog -Level ERROR -Message ("SoftwareDistribution cleanup failed: {0}" -f $_.Exception.Message) -Exception $_.Exception
        }
        finally {
            foreach ($name in @('bits','wuauserv')) {
                try {
                    if ($serviceState[$name] -eq 'Running') {
                        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                        if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop }
                    }
                }
                catch {
                    $errors++
                    Write-WHLog -Level ERROR -Message ("Failed to restore service {0}: {1}" -f $name, $_.Exception.Message)
                }
            }
        }
    }

    if ($Config.Update.CleanupWindowsTemp) {
        try {
            $r = Remove-WHDirectoryContents -Path (Join-Path $env:SystemRoot 'Temp')
            $winTempFreed = $r.FreedBytes
            $skipped += $r.Skipped
            Write-WHLog -Message ("Windows Temp cleanup freed {0:N0} MB." -f ($winTempFreed / 1MB))
        }
        catch {
            $errors++
            Write-WHLog -Level ERROR -Message ("Windows Temp cleanup failed: {0}" -f $_.Exception.Message) -Exception $_.Exception
        }
    }

    if ($Config.Update.CleanupUserTemp) {
        try {
            $r = Remove-WHOldUserTemp -OlderThanDays ([int]$Config.Update.UserTempOlderThanDays)
            $userTempFreed = $r.FreedBytes
            $skipped += $r.Skipped
            $profiles = $r.Profiles
            Write-WHLog -Message ("User Temp cleanup freed {0:N0} MB across {1} profile(s)." -f ($userTempFreed / 1MB), $profiles)
        }
        catch {
            $errors++
            Write-WHLog -Level ERROR -Message ("User Temp cleanup failed: {0}" -f $_.Exception.Message) -Exception $_.Exception
        }
    }

    $total = $sdFreed + $winTempFreed + $userTempFreed
    $resultCode = if ($errors -gt 0) { 3 } elseif ($skipped -gt 0) { 2 } else { 1 }

    Write-WHLog -Message ("Cleanup completed. Total freed={0:N0} MB; skipped={1}; errors={2}; result={3}" -f `
        ($total / 1MB), $skipped, $errors, $resultCode)

    return [pscustomobject]@{
        Timestamp = Get-Date
        Result = [int]$resultCode
        TotalMB = [math]::Round(($total / 1MB),2)
        SoftwareDistributionMB = [math]::Round(($sdFreed / 1MB),2)
        WindowsTempMB = [math]::Round(($winTempFreed / 1MB),2)
        UserTempMB = [math]::Round(($userTempFreed / 1MB),2)
        UserProfilesScanned = [int]$profiles
        Skipped = [int]$skipped
        Errors = [int]$errors
    }
}

function Convert-WHCleanupResultToMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Result)

    $lastRunUnix = ConvertTo-WHUnixTime -DateTime $Result.Timestamp
    return @(
        [pscustomobject]@{ Key='wh.cleanup.result'; Value=$Result.Result },
        [pscustomobject]@{ Key='wh.cleanup.total_mb'; Value=$Result.TotalMB },
        [pscustomobject]@{ Key='wh.cleanup.softwaredistribution_mb'; Value=$Result.SoftwareDistributionMB },
        [pscustomobject]@{ Key='wh.cleanup.windows_temp_mb'; Value=$Result.WindowsTempMB },
        [pscustomobject]@{ Key='wh.cleanup.user_temp_mb'; Value=$Result.UserTempMB },
        [pscustomobject]@{ Key='wh.cleanup.user_profiles'; Value=$Result.UserProfilesScanned },
        [pscustomobject]@{ Key='wh.cleanup.skipped'; Value=$Result.Skipped },
        [pscustomobject]@{ Key='wh.cleanup.errors'; Value=$Result.Errors },
        [pscustomobject]@{ Key='wh.cleanup.last_run'; Value=$lastRunUnix }
    )
}

function Invoke-WHUpdateReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config,
        [int]$DelaySeconds = 0
    )

    Write-WHLog -Message 'Reboot check started.'
    $pending = Test-WHPendingReboot

    if (-not $pending) {
        Write-WHLog -Message 'Reboot not required. No reboot scheduled.'
        return [pscustomobject]@{
            Timestamp = Get-Date
            PendingReboot = 0
            Scheduled = 0
            DelaySeconds = 0
            Result = 1
            Message = 'Reboot not required.'
        }
    }

    $DelaySeconds = 300

    try {
        Write-WHLog -Level WARNING -Message 'Pending reboot detected. Scheduling restart in 300 second(s).'
        $comment = 'Планове перезавантаження після встановлення оновлень Windows. Комп''ютер буде перезавантажено протягом 5 хвилин. Будь ласка, збережіть свою роботу та вийдіть із системи.'
        $args = @('/r','/t','300','/c',$comment,'/d','p:2:17')
        $output = & shutdown.exe @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("shutdown.exe failed with exit code {0}: {1}" -f $LASTEXITCODE, ($output -join ' '))
        }

        Write-WHLog -Message 'Reboot scheduled successfully in 300 second(s).'
        return [pscustomobject]@{
            Timestamp = Get-Date
            PendingReboot = 1
            Scheduled = 1
            DelaySeconds = 300
            Result = 1
            Message = 'Reboot scheduled in 300 second(s).'
        }
    }
    catch {
        Write-WHLog -Level ERROR -Message ("Failed to schedule reboot: {0}" -f $_.Exception.Message) -Exception $_.Exception
        return [pscustomobject]@{
            Timestamp = Get-Date
            PendingReboot = 1
            Scheduled = 0
            DelaySeconds = 300
            Result = 0
            Message = $_.Exception.Message
        }
    }
}

function Convert-WHRebootResultToMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Result
    )

    return @(
        [pscustomobject]@{ Key='wh.reboot.pending'; Value=$Result.PendingReboot },
        [pscustomobject]@{ Key='wh.reboot.scheduled'; Value=$Result.Scheduled },
        [pscustomobject]@{ Key='wh.reboot.delay'; Value=$Result.DelaySeconds },
        [pscustomobject]@{ Key='wh.reboot.result'; Value=$Result.Result }
    )
}
