Set-StrictMode -Version 2.0

function Get-WHPropertyValue {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default = $null
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Get-WHDefenderStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config
    )

    Write-WHLog -Message 'Defender check started.'

    $cmd = Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-WHLog -Level WARNING -Message 'Get-MpComputerStatus is not available.'
        return [pscustomobject]@{
            Timestamp = Get-Date
            Installed = 0
            Service = 0
            AntivirusEnabled = 0
            Realtime = 0
            Behavior = 0
            SignatureAgeHours = -1
            SignatureVersion = ''
            EngineVersion = ''
            PlatformVersion = ''
            CloudProtection = -1
            PUAProtection = -1
            TamperProtection = -1
            QuickScanAgeDays = -1
            FullScanAgeDays = -1
            Error = 'Microsoft Defender cmdlets are not available.'
        }
    }

    try {
        $status = Get-MpComputerStatus
        $pref = Get-MpPreference

        $sigDate = Get-WHPropertyValue -Object $status -Name 'AntivirusSignatureLastUpdated'
        $sigAgeHours = -1
        if ($sigDate) {
            $sigAgeHours = [int][Math]::Floor(((Get-Date) - [datetime]$sigDate).TotalHours)
        }

        $quickEnd = Get-WHPropertyValue -Object $status -Name 'QuickScanEndTime'
        $fullEnd = Get-WHPropertyValue -Object $status -Name 'FullScanEndTime'
        $quickAge = -1
        $fullAge = -1
        if ($quickEnd -and ([datetime]$quickEnd).Year -gt 2000) {
            $quickAge = [int][Math]::Floor(((Get-Date) - [datetime]$quickEnd).TotalDays)
        }
        if ($fullEnd -and ([datetime]$fullEnd).Year -gt 2000) {
            $fullAge = [int][Math]::Floor(((Get-Date) - [datetime]$fullEnd).TotalDays)
        }

        $tamper = -1
        $isTamper = $status.PSObject.Properties['IsTamperProtected']
        if ($isTamper) {
            $tamper = [int][bool]$isTamper.Value
        }

        $maps = Get-WHPropertyValue -Object $pref -Name 'MAPSReporting' -Default -1
        $cloud = if ([int]$maps -gt 0) { 1 } elseif ([int]$maps -eq 0) { 0 } else { -1 }

        $pua = Get-WHPropertyValue -Object $pref -Name 'PUAProtection' -Default -1

        $result = [pscustomobject]@{
            Timestamp = Get-Date
            Installed = 1
            Service = [int][bool](Get-WHPropertyValue -Object $status -Name 'AMServiceEnabled' -Default $false)
            AntivirusEnabled = [int][bool](Get-WHPropertyValue -Object $status -Name 'AntivirusEnabled' -Default $false)
            Realtime = [int][bool](Get-WHPropertyValue -Object $status -Name 'RealTimeProtectionEnabled' -Default $false)
            Behavior = [int][bool](Get-WHPropertyValue -Object $status -Name 'BehaviorMonitorEnabled' -Default $false)
            SignatureAgeHours = $sigAgeHours
            SignatureVersion = [string](Get-WHPropertyValue -Object $status -Name 'AntivirusSignatureVersion' -Default '')
            EngineVersion = [string](Get-WHPropertyValue -Object $status -Name 'AMEngineVersion' -Default '')
            PlatformVersion = [string](Get-WHPropertyValue -Object $status -Name 'AMProductVersion' -Default '')
            CloudProtection = [int]$cloud
            PUAProtection = [int]$pua
            TamperProtection = [int]$tamper
            QuickScanAgeDays = $quickAge
            FullScanAgeDays = $fullAge
            Error = ''
        }

        Write-WHLog -Message ("Defender service={0}; AV={1}; RTP={2}; signature age={3}h; version={4}" -f `
            $result.Service, $result.AntivirusEnabled, $result.Realtime, $result.SignatureAgeHours, $result.SignatureVersion)

        return $result
    }
    catch {
        Write-WHLog -Level ERROR -Message ("Defender query failed: {0}" -f $_.Exception.Message) -Exception $_.Exception
        return [pscustomobject]@{
            Timestamp = Get-Date
            Installed = 1
            Service = 0
            AntivirusEnabled = 0
            Realtime = 0
            Behavior = 0
            SignatureAgeHours = -1
            SignatureVersion = ''
            EngineVersion = ''
            PlatformVersion = ''
            CloudProtection = -1
            PUAProtection = -1
            TamperProtection = -1
            QuickScanAgeDays = -1
            FullScanAgeDays = -1
            Error = $_.Exception.Message
        }
    }
}

function Convert-WHDefenderResultToMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Result
    )

    # Only metrics used by the slim "Microsoft Defender" Zabbix template.
    # WinDefend / MDCoreSvc service state is already monitored by the standard Windows template.
    return @(
        [pscustomobject]@{ Key='wh.defender.antivirus'; Value=$Result.AntivirusEnabled },
        [pscustomobject]@{ Key='wh.defender.realtime'; Value=$Result.Realtime },
        [pscustomobject]@{ Key='wh.defender.signature_age'; Value=$Result.SignatureAgeHours },
        [pscustomobject]@{ Key='wh.defender.signature_version'; Value=$Result.SignatureVersion },
        [pscustomobject]@{ Key='wh.defender.pua'; Value=$Result.PUAProtection },
        [pscustomobject]@{ Key='wh.defender.tamper'; Value=$Result.TamperProtection }
    )
}
