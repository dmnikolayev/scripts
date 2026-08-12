Set-StrictMode -Version 2.0

function Initialize-WHLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RootPath,
        [Parameter(Mandatory=$true)][string]$Module,
        [int]$KeepFiles = 10
    )

    $moduleDir = Join-Path (Join-Path $RootPath 'Logs') $Module
    if (-not (Test-Path $moduleDir)) {
        New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
    }

    $month = Get-Date -Format 'yyyy-MM'
    $script:WHLogFile = Join-Path $moduleDir ("{0}-{1}.log" -f $Module, $month)
    $script:WHRunId = ([guid]::NewGuid().ToString('N').Substring(0,8)).ToUpperInvariant()

    Invoke-WHLogRotation -Path $moduleDir -Pattern ("{0}-*.log" -f $Module) -KeepFiles $KeepFiles
}

function Invoke-WHLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [int]$KeepFiles = 10
    )

    try {
        $files = @(Get-ChildItem -Path $Path -Filter $Pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)

        if ($files.Count -gt $KeepFiles) {
            $files | Select-Object -Skip $KeepFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Log rotation must never break the health check.
    }
}

function Write-WHLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO',
        [System.Exception]$Exception
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $runId = if ($script:WHRunId) { $script:WHRunId } else { '--------' }
    $line = '{0} [{1}] [{2}] {3}' -f $timestamp, $Level, $runId, $Message

    try {
        if ($script:WHLogFile) {
            Add-Content -Path $script:WHLogFile -Value $line -Encoding UTF8

            if ($Exception) {
                Add-Content -Path $script:WHLogFile -Value $Exception.ToString() -Encoding UTF8
            }
        }
    }
    catch {
        # Logging must never break the health check.
    }
}
