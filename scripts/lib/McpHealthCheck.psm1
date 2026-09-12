Set-StrictMode -Version Latest

function ConvertTo-McpProcessArgumentString {
    param([string[]]$Arguments = @())

    return (
        @($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"' + ($_.Replace('"', '\"')) + '"'
            }
            else {
                "$_"
            }
        }) -join ' '
    )
}

function Test-McpCommandExists {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseSingularNouns", "", Justification = "Exists is a verb suffix not a plural noun")]
    param([string]$Command)

    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Test-McpProcessGroupOwnership {
    param([System.Diagnostics.Process]$Process)

    if ($Process.HasExited -or $Process.Id -le 1) { return $false }
    $stat = Get-Content -LiteralPath "/proc/$($Process.Id)/stat" -Raw -ErrorAction Stop
    $match = [regex]::Match($stat, '^\d+ \(.*\) \S+ \d+ (?<group>\d+) (?<session>\d+) ')
    return ($match.Success -and $match.Groups['group'].Value -eq "$($Process.Id)" -and $match.Groups['session'].Value -eq "$($Process.Id)")
}

function Invoke-McpProcessWithTimeout {
    param(
        [string]$Command,
        [string[]]$Arguments = @(),
        [ValidateRange(1, 2147483)]
        [int]$TimeoutSec = 5
    )

    $process = $null
    $started = $false
    $groupOwned = $false
    $maxOutputChars = 1048576

    try {
        $resolved = Get-Command $Command -ErrorAction Stop
        $filePath = if ($resolved.Source) { $resolved.Source } else { $Command }
        $sessionCommand = Get-Command setsid -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $shellCommand = Get-Command sh -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $killCommand = Get-Command kill -CommandType Application -ErrorAction Stop | Select-Object -First 1
        # leader を回収まで保持し、終了した検査の子も同じグループで回収する。
        $wrapper = @'
printf '%s\n' "$$"
IFS= read -r request || exit 125
[ "$request" = start ] || exit 125
"$@" &
child=$!
wait "$child"
status=$?
exec 1>&- 2>&-
IFS= read -r request
exit "$status"
'@
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo.FileName = $sessionCommand.Source
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $process.StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        foreach ($argument in @('--', $shellCommand.Source, '-c', $wrapper, 'mcp-health', $filePath) + $Arguments) {
            $process.StartInfo.ArgumentList.Add($argument)
        }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$process.Start()
        $started = $true
        $stderrBuffer = [char[]]::new(4096)
        $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
        $remainingMilliseconds = {
            [int][math]::Min([int]::MaxValue, [math]::Max(0, ($TimeoutSec * 1000.0) - $timer.Elapsed.TotalMilliseconds))
        }
        # 初期応答も固定長で読み、不正な改行なし出力を保持し続けない。
        $handshakeBuffer = [char[]]::new(1)
        $handshakeText = [System.Text.StringBuilder]::new()
        $handshakeComplete = $false
        while ($handshakeText.Length -lt 32 -and (& $remainingMilliseconds) -gt 0) {
            $handshake = $process.StandardOutput.ReadAsync($handshakeBuffer, 0, 1)
            if (-not $handshake.Wait((& $remainingMilliseconds))) { break }
            if ($handshake.Result -eq 0) { throw 'MCP health process group ownership could not be verified' }
            if ($handshakeBuffer[0] -eq "`n") { $handshakeComplete = $true; break }
            [void]$handshakeText.Append($handshakeBuffer[0])
        }
        if ($handshakeText.Length -ge 32) { throw 'MCP health process group ownership could not be verified' }
        $outputCompleted = $false
        $exited = $false
        if ($handshakeComplete) {
            if ($handshakeText.ToString() -ne "$($process.Id)" -or -not (Test-McpProcessGroupOwnership -Process $process)) {
                throw 'MCP health process group ownership could not be verified'
            }
            $groupOwned = $true
            $stdoutBuffer = [char[]]::new(4096)
            $streams = @(
                @{ Reader = $process.StandardOutput; Buffer = $stdoutBuffer; Text = [System.Text.StringBuilder]::new(); Task = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length) },
                @{ Reader = $process.StandardError; Buffer = $stderrBuffer; Text = [System.Text.StringBuilder]::new(); Task = $stderrTask }
            )
            $process.StandardInput.WriteLine('start')
            $process.StandardInput.Flush()
            # 各ストリームの保留読み取りは1つだけ。合計上限を超えるチャンクは保存しない。
            $totalChars = 0
            while ((& $remainingMilliseconds) -gt 0) {
                $pending = @($streams | Where-Object { $null -ne $_.Task })
                if ($pending.Count -eq 0) { $outputCompleted = $true; break }
                $tasks = [System.Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Task })
                if ([System.Threading.Tasks.Task]::WaitAny($tasks, (& $remainingMilliseconds)) -lt 0) { break }
                foreach ($stream in $pending) {
                    if (-not $stream.Task.IsCompleted) { continue }
                    $count = $stream.Task.GetAwaiter().GetResult()
                    if ($count -eq 0) { $stream.Task = $null; continue }
                    $totalChars += $count
                    if ($totalChars -gt $maxOutputChars) {
                        return [pscustomobject]@{
                            TimedOut = $false
                            OutputLimitExceeded = $true
                            ExitCode = -1
                            Output = "health command output exceeded ${maxOutputChars} characters"
                        }
                    }
                    [void]$stream.Text.Append($stream.Buffer, 0, $count)
                    $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
                }
            }
            if ($outputCompleted) {
                $process.StandardInput.WriteLine('finish')
                $process.StandardInput.Close()
                $exited = $process.WaitForExit((& $remainingMilliseconds))
            }
        }
        if ($exited -and $outputCompleted) {
            return [pscustomobject]@{
                TimedOut = $false
                OutputLimitExceeded = $false
                ExitCode = $process.ExitCode
                Output   = ($streams[0].Text.ToString() + $streams[1].Text.ToString()).Trim()
            }
        }

        return [pscustomobject]@{
            TimedOut = $true
            OutputLimitExceeded = $false
            ExitCode = -1
            Output   = "health command timed out after ${TimeoutSec}s"
        }
    }
    finally {
        if ($null -ne $process) {
            try {
                if ($started -and -not $process.HasExited) {
                    if ($groupOwned -and (Test-McpProcessGroupOwnership -Process $process)) {
                        & $killCommand.Source -KILL -- "-$($process.Id)" 2>$null
                        if ($LASTEXITCODE -ne 0) { throw 'MCP health process group cleanup failed' }
                    }
                    else {
                        $process.Kill($true)
                    }
                    [void]$process.WaitForExit(5000)
                }
            }
            finally { $process.Dispose() }
        }
    }
}

function Get-McpServerHealth {
    param(
        [string]$Name,
        [object]$Definition
    )

    $command = if ($Definition.PSObject.Properties.Name -contains "command" -and $Definition.command) { "$($Definition.command)" } else { "" }
    $commandExists = if ($command) { Test-McpCommandExists -Command $command } else { $false }
    $cmdArgs = if ($Definition.PSObject.Properties.Name -contains "args" -and $null -ne $Definition.args) { @($Definition.args | ForEach-Object { "$_" }) } else { @() }
    $healthCommand = if ($Definition.PSObject.Properties.Name -contains "healthCommand" -and $null -ne $Definition.healthCommand) { @($Definition.healthCommand | ForEach-Object { "$_" }) } else { @() }
    $healthTimeoutSec = if ($Definition.PSObject.Properties.Name -contains "healthCommandTimeoutSec" -and $null -ne $Definition.healthCommandTimeoutSec) {
        [int]$Definition.healthCommandTimeoutSec
    }
    else {
        5
    }

    $healthStatus = "not_configured"
    $healthOutput = $null
    $serverStatus = if ($commandExists) { "available" } else { "unavailable" }

    if (@($healthCommand).Count -gt 0) {
        $healthExe = $healthCommand[0]
        if (Test-McpCommandExists -Command $healthExe) {
            try {
                $healthResult = Invoke-McpProcessWithTimeout -Command $healthExe -Arguments @($healthCommand | Select-Object -Skip 1) -TimeoutSec $healthTimeoutSec
                $healthOutput = $healthResult.Output
                if ($healthResult.TimedOut) {
                    $healthStatus = "timeout"
                }
                else {
                    $healthStatus = if ($healthResult.ExitCode -eq 0) { "healthy" } else { "unhealthy" }
                }
            }
            catch {
                $healthStatus = "unhealthy"
                $healthOutput = $_.Exception.Message
            }
        }
        else {
            $healthStatus = "health_command_unavailable"
        }
    }

    return [pscustomobject]@{
        name                    = $Name
        command                 = $command
        args                    = @($cmdArgs)
        configured              = $true
        commandExists           = $commandExists
        healthCommand           = @($healthCommand)
        healthCommandTimeoutSec = $healthTimeoutSec
        healthStatus            = $healthStatus
        healthOutput            = $healthOutput
        status                  = $serverStatus
        kind                    = if ($Name -match "memory") { "memory" } else { "external" }
        operatingProcedure      = [pscustomobject]@{
            health           = if (@($healthCommand).Count -gt 0) { $healthCommand -join " " } else { $null }
            healthTimeoutSec = $healthTimeoutSec
        }
        note = if ($commandExists) { "command detected" } else { "command not found or runtime unavailable" }
    }
}

function Get-McpHealthReport {
    param([string]$ProjectRoot)

    $configPath = if ($env:AI_STARTUP_MCP_CONFIG_PATH) {
        $env:AI_STARTUP_MCP_CONFIG_PATH
    }
    else {
        Join-Path $ProjectRoot ".mcp.json"
    }

    $report = [ordered]@{
        configured  = $false
        configPath  = $configPath
        servers     = @()
        connections = @()
        summary     = "MCP 設定なし"
    }

    if (-not (Test-Path $configPath)) {
        return [pscustomobject]$report
    }

    try {
        $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.configured = $true

        if ($null -eq $config -or $null -eq $config.mcpServers) {
            $report.summary = "MCP 設定あり: server 定義なし"
            return [pscustomobject]$report
        }

        foreach ($serverProperty in @($config.mcpServers.PSObject.Properties)) {
            $server = Get-McpServerHealth -Name $serverProperty.Name -Definition $serverProperty.Value
            $report.servers += $server
            $report.connections += [pscustomobject]@{
                name               = $server.name
                kind               = $server.kind
                connected          = ($server.healthStatus -eq "healthy")
                status             = $server.healthStatus
                output             = $server.healthOutput
                operatingProcedure = $server.operatingProcedure
            }
        }

        if (@($report.servers).Count -gt 0) {
            $report.summary = "MCP 設定あり: $(@($report.servers).Count) server(s)"
        }
        else {
            $report.summary = "MCP 設定あり: server 定義なし"
        }
    }
    catch {
        $report.summary = "MCP 設定の解析に失敗: $($_.Exception.Message)"
    }

    return [pscustomobject]$report
}

function Get-McpQuickStatus {
    param([string]$ProjectRoot)

    try {
        $report = Get-McpHealthReport -ProjectRoot $ProjectRoot
        if (-not $report.configured) {
            return "MCP: not configured"
        }
        $available = @($report.servers | Where-Object { $_.status -eq "available" }).Count
        $total = @($report.servers).Count
        $icon = if ($available -eq $total) { "OK" } else { "WARN" }
        return "MCP: [$icon] $available/$total servers"
    }
    catch {
        return "MCP: check failed"
    }
}

Export-ModuleMember -Function @(
    "ConvertTo-McpProcessArgumentString",
    "Test-McpCommandExists",
    "Invoke-McpProcessWithTimeout",
    "Get-McpServerHealth",
    "Get-McpHealthReport",
    "Get-McpQuickStatus"
)
