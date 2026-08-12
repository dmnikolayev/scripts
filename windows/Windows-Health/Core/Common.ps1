Set-StrictMode -Version 2.0

function Test-WHPendingReboot {
    [CmdletBinding()]
    param()

    $pending = $false

    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

    if ($cbs -or $wu) { $pending = $true }

    try {
        $sessionMgr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction Stop
        $pfr = [bool]$sessionMgr.PendingFileRenameOperations
        if ($pfr) { $pending = $true }
    } catch {
    }

    return [bool]$pending
}

function ConvertTo-WHUnixTime {
    [CmdletBinding()]
    param([datetime]$DateTime)

    if (-not $DateTime) { return 0 }
    return [int64]([DateTimeOffset]$DateTime.ToUniversalTime()).ToUnixTimeSeconds()
}
