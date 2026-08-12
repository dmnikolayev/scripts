Set-StrictMode -Version 2.0

function Get-WHConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RootPath
    )

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $config = $raw | ConvertFrom-Json

    if (-not $config.Zabbix.Hostname) {
        $config.Zabbix.Hostname = $env:COMPUTERNAME
    }

    Add-Member -InputObject $config -NotePropertyName RootPath -NotePropertyValue $RootPath -Force
    Add-Member -InputObject $config -NotePropertyName LogRoot -NotePropertyValue (Join-Path $RootPath 'Logs') -Force
    Add-Member -InputObject $config -NotePropertyName StateRoot -NotePropertyValue (Join-Path $RootPath 'State') -Force
    Add-Member -InputObject $config -NotePropertyName TempRoot -NotePropertyValue (Join-Path $RootPath 'Temp') -Force

    return $config
}
