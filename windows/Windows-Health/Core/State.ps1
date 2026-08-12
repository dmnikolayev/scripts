Set-StrictMode -Version 2.0

function Save-WHState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$StateRoot,
        [Parameter(Mandatory=$true)][string]$Module
    )

    $moduleDir = Join-Path $StateRoot $Module
    if (-not (Test-Path $moduleDir)) {
        New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
    }

    $path = Join-Path $moduleDir 'LastRun.json'
    $tmp = "$path.tmp"
    $Object | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $path -Force
    return $path
}
