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

function Invoke-McpProcessWithTimeout {
    param(
        [string]$Command,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 5
    )

    $stdoutPath = Join-Path $env:TEMP ("codex-startup-mcp-" + [guid]::NewGuid().ToString() + ".out")
    $stderrPath = Join-Path $env:TEMP ("codex-startup-mcp-" + [guid]::NewGuid().ToString() + ".err")
    $process = $null

    try {
        $resolved = Get-Command $Command -ErrorAction Stop
        $filePath = if ($resolved.Source) { $resolved.Source } else { $Command }
        $process = Start-Process -FilePath $filePath -ArgumentList (ConvertTo-McpProcessArgumentString -Arguments $Arguments) -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        if ($process.WaitForExit($TimeoutSec * 1000)) {
            $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -Encoding UTF8 } else { "" }
            $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -Encoding UTF8 } else { "" }
            return [pscustomobject]@{
                TimedOut = $false
                ExitCode = $process.ExitCode
                Output   = ($stdout + $stderr).Trim()
            }
        }

        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            TimedOut = $true
            ExitCode = -1
            Output   = "health command timed out after ${TimeoutSec}s"
        }
    }
    finally {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
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
