Set-StrictMode -Version Latest

# arch-check:ignore (このコメントは正規表現の説明用であり、値のハードコードではない)
# 接続情報は環境変数 ORCHESTRATION_PG_DSN からのみ取得する。値そのものは
# ログ・例外メッセージ・戻り値へ含めない。

$script:DefaultDsnEnvVar = "ORCHESTRATION_PG_DSN"
$script:CircuitBreakerState = @{
    FailureCount     = 0
    OpenedAt         = $null
    FailureThreshold = 5
    OpenSeconds      = 30
}

function Get-PostgreSqlConnectionInfo {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$DsnEnvVar = $script:DefaultDsnEnvVar
    )

    $dsn = [System.Environment]::GetEnvironmentVariable($DsnEnvVar)
    $available = -not [string]::IsNullOrWhiteSpace($dsn)

    return [pscustomobject]@{
        EnvVar    = $DsnEnvVar
        Available = $available
        # Dsn は呼び出し元のみへ返す。Write-Host / ログへは絶対に渡さないこと。
        Dsn       = if ($available) { $dsn } else { $null }
    }
}

function Test-PostgreSqlClientTool {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param()

    return [bool](Get-Command psql -ErrorAction SilentlyContinue)
}

function Reset-PostgreSqlCircuitBreaker {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "In-memory circuit breaker counter reset, not a system-changing operation.")]
    param()

    $script:CircuitBreakerState.FailureCount = 0
    $script:CircuitBreakerState.OpenedAt = $null
}

function Get-PostgreSqlCircuitBreakerState {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param()

    $isOpen = $false
    if ($null -ne $script:CircuitBreakerState.OpenedAt) {
        $elapsed = ((Get-Date) - $script:CircuitBreakerState.OpenedAt).TotalSeconds
        if ($elapsed -lt $script:CircuitBreakerState.OpenSeconds) {
            $isOpen = $true
        }
        else {
            # クールダウン経過。ハーフオープンとして次の1回を試行させる。
            $script:CircuitBreakerState.OpenedAt = $null
            $script:CircuitBreakerState.FailureCount = 0
        }
    }

    return [pscustomobject]@{
        IsOpen           = $isOpen
        FailureCount     = $script:CircuitBreakerState.FailureCount
        FailureThreshold = $script:CircuitBreakerState.FailureThreshold
        OpenSeconds      = $script:CircuitBreakerState.OpenSeconds
    }
}

function Set-PostgreSqlCircuitBreakerOption {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "In-memory tuning of circuit breaker thresholds, not a system-changing operation.")]
    param(
        [int]$FailureThreshold,
        [int]$OpenSeconds
    )

    if ($PSBoundParameters.ContainsKey("FailureThreshold")) {
        $script:CircuitBreakerState.FailureThreshold = $FailureThreshold
    }
    if ($PSBoundParameters.ContainsKey("OpenSeconds")) {
        $script:CircuitBreakerState.OpenSeconds = $OpenSeconds
    }
}

function Add-PostgreSqlCircuitBreakerFailure {
    $script:CircuitBreakerState.FailureCount++
    if ($script:CircuitBreakerState.FailureCount -ge $script:CircuitBreakerState.FailureThreshold) {
        $script:CircuitBreakerState.OpenedAt = Get-Date
    }
}

function Test-PostgreSqlHealth {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$DsnEnvVar = $script:DefaultDsnEnvVar,
        [int]$TimeoutSeconds = 5
    )

    $connectionInfo = Get-PostgreSqlConnectionInfo -DsnEnvVar $DsnEnvVar
    if (-not $connectionInfo.Available) {
        return [pscustomobject]@{ Healthy = $false; Reason = "connection env var '$DsnEnvVar' is not set" }
    }

    if (-not (Test-PostgreSqlClientTool)) {
        return [pscustomobject]@{ Healthy = $false; Reason = "psql client tool not found" }
    }

    if (-not (Get-Command pg_isready -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Healthy = $false; Reason = "pg_isready client tool not found" }
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = "pg_isready"
        $psi.ArgumentList.Add("-d")
        $psi.ArgumentList.Add($connectionInfo.Dsn)
        $psi.ArgumentList.Add("-t")
        $psi.ArgumentList.Add("$TimeoutSeconds")
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false

        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit(($TimeoutSeconds * 1000) + 1000) | Out-Null

        if (-not $process.HasExited) {
            $process.Kill()
            return [pscustomobject]@{ Healthy = $false; Reason = "pg_isready timed out" }
        }

        return [pscustomobject]@{ Healthy = ($process.ExitCode -eq 0); Reason = "pg_isready exit code $($process.ExitCode)" }
    }
    catch {
        return [pscustomobject]@{ Healthy = $false; Reason = "pg_isready invocation failed" }
    }
}

function Invoke-PostgreSqlCommand {
    <#
        単一SQL文をpsql経由で実行する薄いラッパー。
        - 接続情報が無い、psqlが無い、Circuit Breakerが開いている場合はOk=$falseで即時返す（例外にしない）
        - 呼び出し元はOkを見てFile Fallbackへ切り替える
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Sql,

        [string]$DsnEnvVar = $script:DefaultDsnEnvVar,
        [int]$TimeoutSeconds = 10,
        [int]$MaxRetry = 3,
        [int]$InitialBackoffMilliseconds = 250
    )

    $breaker = Get-PostgreSqlCircuitBreakerState
    if ($breaker.IsOpen) {
        return [pscustomobject]@{ Ok = $false; Reason = "circuit breaker open"; Output = $null }
    }

    $connectionInfo = Get-PostgreSqlConnectionInfo -DsnEnvVar $DsnEnvVar
    if (-not $connectionInfo.Available) {
        return [pscustomobject]@{ Ok = $false; Reason = "connection env var '$DsnEnvVar' is not set"; Output = $null }
    }

    if (-not (Test-PostgreSqlClientTool)) {
        return [pscustomobject]@{ Ok = $false; Reason = "psql client tool not found"; Output = $null }
    }

    $attempt = 0
    $backoff = $InitialBackoffMilliseconds
    $lastReason = ""

    while ($attempt -lt $MaxRetry) {
        $attempt++
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = "psql"
            $psi.ArgumentList.Add($connectionInfo.Dsn)
            $psi.ArgumentList.Add("-v")
            $psi.ArgumentList.Add("ON_ERROR_STOP=1")
            $psi.ArgumentList.Add("-tAq")
            $psi.ArgumentList.Add("-c")
            $psi.ArgumentList.Add($Sql)
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $process = [System.Diagnostics.Process]::Start($psi)
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit(($TimeoutSeconds * 1000) + 1000) | Out-Null

            if (-not $process.HasExited) {
                $process.Kill()
                $lastReason = "timed out after ${TimeoutSeconds}s"
            }
            elseif ($process.ExitCode -eq 0) {
                Reset-PostgreSqlCircuitBreaker
                return [pscustomobject]@{ Ok = $true; Reason = "ok"; Output = $stdout }
            }
            else {
                # psqlのエラー本文には値が含まれる可能性があるため保持しない。件数のみ記録する。
                $lastReason = "psql exited with code $($process.ExitCode)"
                if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                    $lastReason += " (stderr present)"
                }
            }
        }
        catch {
            $lastReason = "psql invocation threw an exception"
        }

        Add-PostgreSqlCircuitBreakerFailure
        if ((Get-PostgreSqlCircuitBreakerState).IsOpen) {
            break
        }

        if ($attempt -lt $MaxRetry) {
            Start-Sleep -Milliseconds $backoff
            $backoff *= 2
        }
    }

    return [pscustomobject]@{ Ok = $false; Reason = $lastReason; Output = $null }
}

Export-ModuleMember -Function @(
    "Add-PostgreSqlCircuitBreakerFailure",
    "Get-PostgreSqlCircuitBreakerState",
    "Get-PostgreSqlConnectionInfo",
    "Invoke-PostgreSqlCommand",
    "Reset-PostgreSqlCircuitBreaker",
    "Set-PostgreSqlCircuitBreakerOption",
    "Test-PostgreSqlClientTool",
    "Test-PostgreSqlHealth"
)
