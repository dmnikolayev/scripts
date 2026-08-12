Set-StrictMode -Version 2.0

function Get-WHTimeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config
    )

    Write-WHLog -Message 'Time check started.'

    $service = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    $serviceRunning = [int]($service -and $service.Status -eq 'Running')

    $tz = Get-TimeZone
    $utcOffsetHours = [TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours
    $timezoneOk = [int]([string]$tz.Id -eq [string]$Config.Time.ExpectedTimeZone)

    $source = ''
    $syncStatus = 0
    $stratum = -1
    $lastSyncAgeMinutes = -1
    $statusText = @()

    try {
        $sourceOutput = & w32tm.exe /query /source 2>&1
        if ($LASTEXITCODE -eq 0) {
            $source = (($sourceOutput | Out-String).Trim())
        } else {
            $source = 'Unknown'
        }
    }
    catch {
        $source = 'Unknown'
        Write-WHLog -Level WARNING -Message ("w32tm source query failed: {0}" -f $_.Exception.Message)
    }

    try {
        $statusOutput = @(& w32tm.exe /query /status /verbose 2>&1)
        $statusExit = $LASTEXITCODE
        $statusText = $statusOutput
        $syncStatus = [int]($statusExit -eq 0)

        if ($syncStatus -eq 1) {
            foreach ($line in $statusOutput) {
                if ($stratum -lt 0 -and $line -match '^\s*Stratum\s*:\s*(\d+)') {
                    $stratum = [int]$matches[1]
                }

                if ($lastSyncAgeMinutes -lt 0 -and $line -match '^\s*Last Successful Sync Time\s*:\s*(.+)$') {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($matches[1].Trim(), [ref]$parsed)) {
                        $lastSyncAgeMinutes = [int][Math]::Floor(((Get-Date) - $parsed).TotalMinutes)
                    }
                }
            }
        }
    }
    catch {
        $syncStatus = 0
        Write-WHLog -Level WARNING -Message ("w32tm status query failed: {0}" -f $_.Exception.Message)
    }

    Write-WHLog -Message ("W32Time running={0}; Source={1}; TimeZone={2}; UTC offset={3}" -f `
        $serviceRunning, $source, $tz.Id, $utcOffsetHours)

    if ($lastSyncAgeMinutes -ge 0) {
        Write-WHLog -Message ("Last successful time sync age: {0} minute(s)." -f $lastSyncAgeMinutes)
    }

    $overall = 1
    if ($serviceRunning -eq 0 -or $syncStatus -eq 0) { $overall = 0 }

    return [pscustomobject]@{
        Timestamp = Get-Date
        Overall = $overall
        Service = $serviceRunning
        SyncStatus = $syncStatus
        Source = $source
        Stratum = $stratum
        LastSyncAgeMinutes = $lastSyncAgeMinutes
        TimeZone = [string]$tz.Id
        TimeZoneExpected = [string]$Config.Time.ExpectedTimeZone
        TimeZoneOk = $timezoneOk
        UtcOffsetHours = [double]$utcOffsetHours
        Error = ''
    }
}

function Convert-WHTimeResultToMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Result
    )

    # Only metrics used by the slim "Windows Time" Zabbix template.
    # W32Time service and system local time are already monitored by the standard Windows template.
    return @(
        [pscustomobject]@{ Key='wh.time.sync_status'; Value=$Result.SyncStatus },
        [pscustomobject]@{ Key='wh.time.source'; Value=$Result.Source },
        [pscustomobject]@{ Key='wh.time.stratum'; Value=$Result.Stratum },
        [pscustomobject]@{ Key='wh.time.last_sync_age'; Value=$Result.LastSyncAgeMinutes },
        [pscustomobject]@{ Key='wh.time.timezone'; Value=$Result.TimeZone },
        [pscustomobject]@{ Key='wh.time.timezone_ok'; Value=$Result.TimeZoneOk },
        [pscustomobject]@{ Key='wh.time.utc_offset'; Value=$Result.UtcOffsetHours }
    )
}
