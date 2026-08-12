Set-StrictMode -Version 2.0

function Resolve-WHZabbixSender {
    [CmdletBinding()]
    param([string]$ConfiguredPath)

    if ($ConfiguredPath -and (Test-Path $ConfiguredPath)) {
        return $ConfiguredPath
    }

    $candidates = @(
        @(
            "$env:ProgramFiles\Zabbix Agent 2\zabbix_sender.exe",
            "$env:ProgramFiles\Zabbix Agent\zabbix_sender.exe",
            "${env:ProgramFiles(x86)}\Zabbix Agent 2\zabbix_sender.exe",
            "${env:ProgramFiles(x86)}\Zabbix Agent\zabbix_sender.exe"
        ) | Where-Object { $_ -and (Test-Path $_) }
    )

    if ($candidates.Count -gt 0) {
        return [string]$candidates[0]
    }

    $cmd = Get-Command zabbix_sender.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

function Send-WHZabbixMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Metrics,
        [Parameter(Mandatory=$true)]$Config
    )

    if (-not $Config.Provider.Enabled -or $Config.Provider.Name -ne 'Zabbix') {
        return [pscustomobject]@{ Success=$true; Message='Provider disabled.' }
    }

    $sender = Resolve-WHZabbixSender -ConfiguredPath $Config.Zabbix.SenderPath
    if (-not $sender) {
        return [pscustomobject]@{
            Success=$false
            Message='zabbix_sender.exe not found. Set Zabbix.SenderPath in config.json.'
        }
    }

    if (-not (Test-Path $Config.TempRoot)) {
        New-Item -ItemType Directory -Path $Config.TempRoot -Force | Out-Null
    }

    $tmp = Join-Path $Config.TempRoot ('zabbix-{0}.txt' -f ([guid]::NewGuid().ToString('N')))

    try {
        $hostName = [string]$Config.Zabbix.Hostname
        $lines = New-Object System.Collections.Generic.List[string]

        foreach ($m in $Metrics) {
            $value = ([string]$m.Value).Replace('"','\"')
            $lines.Add(('"{0}" {1} "{2}"' -f $hostName, $m.Key, $value))
        }

        $lines | Set-Content -Path $tmp -Encoding ASCII

        $args = @(
            '-z', [string]$Config.Zabbix.Server,
            '-p', [string]$Config.Zabbix.Port,
            '-i', $tmp
        )
        $output = & $sender @args 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            Success=($exitCode -eq 0)
            ExitCode=$exitCode
            Message=($output -join ' ')
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            ExitCode=-1
            Message=$_.Exception.Message
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-WHZabbixProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config
    )

    $sender = Resolve-WHZabbixSender -ConfiguredPath $Config.Zabbix.SenderPath
    $senderFound = [bool]$sender
    $tcpReachable = $false

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect([string]$Config.Zabbix.Server, [int]$Config.Zabbix.Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($async)
            $tcpReachable = $true
        }
        $tcp.Close()
    } catch {
        $tcpReachable = $false
    }

    $metricAccepted = $false
    $sendMessage = ''

    if ($senderFound -and $tcpReachable) {
        $metric = @(
            [pscustomobject]@{
                Key='wh.provider.test'
                Value=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
        )
        $send = Send-WHZabbixMetrics -Metrics $metric -Config $Config
        $metricAccepted = [bool]$send.Success
        $sendMessage = [string]$send.Message
    }
    elseif (-not $senderFound) {
        $sendMessage = 'zabbix_sender.exe not found.'
    }
    else {
        $sendMessage = 'TCP connection to Zabbix server failed.'
    }

    return [pscustomobject]@{
        SenderFound=$senderFound
        TcpReachable=$tcpReachable
        MetricAccepted=$metricAccepted
        Message=$sendMessage
    }
}
