[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(ParameterSetName='Run', Mandatory=$true)]
    [ValidateSet('Update','Time','Defender')]
    [string]$Module,

    [Parameter(ParameterSetName='Run')]
    [ValidateSet('Check','Install','Cleanup','Reboot')]
    [string]$Mode = 'Check',

    [Parameter(ParameterSetName='Run')]
    [switch]$NoProvider,

    [Parameter(ParameterSetName='Run')]
    [ValidateRange(0,86400)]
    [int]$Delay = 0,

    [Parameter(ParameterSetName='Version', Mandatory=$true)]
    [switch]$Version,

    [string]$ConfigPath = "$PSScriptRoot\Config\config.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$versionFile = Join-Path $PSScriptRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile) {
    $WHVersion = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim()
}
else {
    $WHVersion = 'unknown'
}

if ($Version) {
    Write-Output ("Windows Health {0}" -f $WHVersion)
    return
}

. "$PSScriptRoot\Core\Config.ps1"
. "$PSScriptRoot\Core\Logger.ps1"
. "$PSScriptRoot\Core\State.ps1"
. "$PSScriptRoot\Core\Common.ps1"
. "$PSScriptRoot\Providers\Zabbix.ps1"

$config = Get-WHConfig -Path $ConfigPath -RootPath $PSScriptRoot

foreach ($dir in @($config.LogRoot, $config.StateRoot, $config.TempRoot)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Initialize-WHLogging -RootPath $PSScriptRoot -Module $Module -KeepFiles $config.Logging.KeepFiles

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$providerStatus = 'SKIPPED'
$status = 'OK'
$result = $null
$mutex = $null
$mutexAcquired = $false
$mutexName = 'Global\WindowsHealth'

try {
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try { $mutexAcquired = $mutex.WaitOne(0, $false) }
        catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    }
    catch {
        $mutexName = 'WindowsHealth'
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try { $mutexAcquired = $mutex.WaitOne(0, $false) }
        catch [System.Threading.AbandonedMutexException] { $mutexAcquired = $true }
    }

    if (-not $mutexAcquired) {
        $status = 'SKIPPED'
        Write-WHLog -Level WARNING -Message 'Another Windows Health operation is already running. Current run skipped.'
        return
    }

    Write-WHLog -Message ("Windows Health {0}; Module={1}; Mode={2}; Host={3}" -f `
        $WHVersion, $Module, $Mode, $env:COMPUTERNAME)

    switch ($Module) {
        'Update' {
            . "$PSScriptRoot\Modules\Update\Update.ps1"

            if ($Mode -eq 'Install') {
                $result = Invoke-WHUpdateInstall -Config $config
                $metrics = Convert-WHUpdateResultToMetrics -Result $result
                if ($result.Result -eq 2) { $status = 'FAILED' }
                elseif ($result.Result -eq 3) { $status = 'WARNING' }
            }
            elseif ($Mode -eq 'Cleanup') {
                $result = Invoke-WHUpdateCleanup -Config $config
                $metrics = Convert-WHCleanupResultToMetrics -Result $result
                if ($result.Result -eq 3) { $status = 'FAILED' }
            }
            elseif ($Mode -eq 'Reboot') {
                $result = Invoke-WHUpdateReboot -Config $config -DelaySeconds $Delay
                $metrics = Convert-WHRebootResultToMetrics -Result $result
                if ($result.Result -eq 0) { $status = 'FAILED' }
                elseif ($result.PendingReboot -eq 1 -and $result.Scheduled -eq 1) { $status = 'REBOOT SCHEDULED' }
            }
            else {
                $result = Invoke-WHUpdateCheck
                $metrics = Convert-WHUpdateResultToMetrics -Result $result
                if ($result.Result -eq 2) { $status = 'FAILED' }
                elseif ($result.Result -eq 3) { $status = 'WARNING' }
            }
        }

        'Time' {
            if ($Mode -ne 'Check') { throw 'Time module supports Check mode only.' }
            . "$PSScriptRoot\Modules\Time\Time.ps1"
            $result = Get-WHTimeStatus -Config $config
            $metrics = Convert-WHTimeResultToMetrics -Result $result

            if ($result.Service -eq 0 -or $result.SyncStatus -eq 0) { $status = 'FAILED' }
            elseif ($result.TimeZoneOk -eq 0) { $status = 'WARNING' }
        }

        'Defender' {
            if ($Mode -ne 'Check') { throw 'Defender module supports Check mode only.' }
            . "$PSScriptRoot\Modules\Defender\Defender.ps1"
            $result = Get-WHDefenderStatus -Config $config
            $metrics = Convert-WHDefenderResultToMetrics -Result $result

            if ($result.Installed -eq 0 -or $result.Service -eq 0 -or $result.AntivirusEnabled -eq 0 -or $result.Realtime -eq 0) {
                $status = 'FAILED'
            }
            elseif ($result.SignatureAgeHours -gt $config.Defender.MaxSignatureAgeHours) {
                $status = 'WARNING'
            }
        }
    }

    $statePath = Save-WHState -Object $result -StateRoot $config.StateRoot -Module $Module
    Write-WHLog -Message ("State saved: {0}" -f $statePath)

    if ($NoProvider) {
        $providerStatus = 'SKIPPED'
        Write-WHLog -Message 'Provider send skipped (-NoProvider).'
    }
    else {
        $send = Send-WHZabbixMetrics -Metrics $metrics -Config $config
        if ($send.Success) {
            $providerStatus = 'OK'
            Write-WHLog -Message ("Provider send OK: {0}" -f $send.Message)
        }
        else {
            $providerStatus = 'FAILED'
            Write-WHLog -Level WARNING -Message ("Provider send failed: {0}" -f $send.Message)
        }
    }

    Write-WHLog -Message ("Module completed. Status={0}" -f $status)
}
catch {
    $status = 'FAILED'
    Write-WHLog -Level ERROR -Message $_.Exception.Message -Exception $_.Exception
}
finally {
    if ($mutexAcquired -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { try { $mutex.Dispose() } catch {} }
    $sw.Stop()

    Write-Output ''
    Write-Output ("Windows Health {0}" -f $WHVersion)
    Write-Output ''
    Write-Output ('Module......... {0}' -f $Module)
    Write-Output ('Status......... {0}' -f $status)

    if ($result) {
        switch ($Module) {
            'Update' {
                Write-Output ('Mode........... {0}' -f $Mode)
                if ($Mode -eq 'Cleanup') {
                    Write-Output ('SoftwareDist... {0:N2} MB' -f $result.SoftwareDistributionMB)
                    Write-Output ('Windows Temp... {0:N2} MB' -f $result.WindowsTempMB)
                    Write-Output ('User Temp...... {0:N2} MB' -f $result.UserTempMB)
                    Write-Output ('Profiles....... {0}' -f $result.UserProfilesScanned)
                    Write-Output ('Freed total.... {0:N2} MB' -f $result.TotalMB)
                    Write-Output ('Skipped........ {0}' -f $result.Skipped)
                    Write-Output ('Errors.......... {0}' -f $result.Errors)
                }
                elseif ($Mode -eq 'Reboot') {
                    Write-Output ('Pending reboot. {0}' -f $(if ($result.PendingReboot -eq 1) {'YES'} else {'NO'}))
                    Write-Output ('Scheduled...... {0}' -f $(if ($result.Scheduled -eq 1) {'YES'} else {'NO'}))
                    if ($result.Scheduled -eq 1) {
                        Write-Output ('Restart in..... {0} sec' -f $result.DelaySeconds)
                    }
                    Write-Output ('Message......... {0}' -f $result.Message)
                }
                else {
                    Write-Output ('Updates........ {0}' -f $result.Count)
                    Write-Output ('Pending reboot. {0}' -f $(if ($result.PendingReboot -eq 1) {'YES'} else {'NO'}))
                    if ($result.LastPatchAgeDays -ge 0) {
                        Write-Output ('Last patch..... {0} day(s)' -f $result.LastPatchAgeDays)
                    } else {
                        Write-Output 'Last patch..... unknown'
                    }
                }
            }
            'Time' {
                Write-Output ('Time service.... {0}' -f $(if ($result.Service -eq 1) {'OK'} else {'FAILED'}))
                Write-Output ('Source.......... {0}' -f $result.Source)
                Write-Output ('Time zone....... {0}' -f $result.TimeZone)
                Write-Output ('UTC offset...... {0:+0.##;-0.##;0}' -f $result.UtcOffsetHours)
                if ($result.LastSyncAgeMinutes -ge 0) {
                    Write-Output ('Last sync....... {0} min ago' -f $result.LastSyncAgeMinutes)
                }
            }
            'Defender' {
                Write-Output ('Service......... {0}' -f $(if ($result.Service -eq 1) {'OK'} else {'FAILED'}))
                Write-Output ('Realtime........ {0}' -f $(if ($result.Realtime -eq 1) {'ON'} else {'OFF'}))
                Write-Output ('Signature age... {0} hour(s)' -f $result.SignatureAgeHours)
                Write-Output ('Signature....... {0}' -f $result.SignatureVersion)
                Write-Output ('PUA............. {0}' -f $result.PUAProtection)
                Write-Output ('Tamper.......... {0}' -f $result.TamperProtection)
            }
        }
    }

    Write-Output ('Provider....... {0}' -f $providerStatus)
    Write-Output ('Duration....... {0:N1} sec' -f $sw.Elapsed.TotalSeconds)
    Write-Output ('Log............ {0}' -f $script:WHLogFile)
    Write-Output ''
}
