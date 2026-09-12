[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/LauncherCommon.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $script:StartupRoot "scripts/lib/Config.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/TokenBudget.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/McpHealthCheck.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/MessageBus.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/LogManager.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/ErrorHandler.psm1") -Force

function Get-BootstrapStatePath {
    if ($env:AI_STARTUP_STATE_PATH) {
        return $env:AI_STARTUP_STATE_PATH
    }

    return Join-Path $script:StartupRoot "state.json"
}

function Get-BootstrapStateExamplePath {
    return Join-Path $script:StartupRoot "state.json.example"
}

function Initialize-BootstrapState {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [switch]$PreviewOnly
    )

    if (Test-Path $StatePath) {
        return [pscustomobject]@{
            Exists   = $true
            Created  = $false
            Path     = $StatePath
            Message  = "state.json already exists"
        }
    }

    $examplePath = Get-BootstrapStateExamplePath
    if (-not (Test-Path $examplePath)) {
        throw "state.json.example が見つかりません: $examplePath"
    }

    if ($PreviewOnly) {
        return [pscustomobject]@{
            Exists   = $false
            Created  = $false
            Path     = $StatePath
            Message  = "state.json would be created from state.json.example"
        }
    }

    $directory = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Copy-Item -Path $examplePath -Destination $StatePath -Force

    return [pscustomobject]@{
        Exists   = $false
        Created  = $true
        Path     = $StatePath
        Message  = "state.json created from state.json.example"
    }
}

function Get-BootstrapSummary {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$StatePath,

        [Parameter(Mandatory)]
        [object]$Config
    )

    $toolConfig = $Config.tools.codex
    $toolCommand = "$($toolConfig.command)"
    $toolAvailable = [bool](Get-Command $toolCommand -ErrorAction SilentlyContinue)
    $mcpStatus = Get-McpQuickStatus -ProjectRoot $script:StartupRoot
    $tokenStatus = Get-TokenBudgetStatus -StatePath $StatePath

    return [pscustomobject]@{
        ConfigPath     = $ConfigPath
        StatePath      = $StatePath
        ToolCommand    = $toolCommand
        ToolAvailable  = $toolAvailable
        TokenZone      = $tokenStatus.Zone.Label
        TokenUsed      = $tokenStatus.UsedPercent
        McpStatus      = $mcpStatus
        NonInteractive = [bool]$NonInteractive
        DryRun         = [bool]$DryRun
    }
}

function Get-BootstrapPreflightChecks {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$StatePath,

        [Parameter(Mandatory)]
        [object]$Config
    )

    $gitRoot = git -C $script:StartupRoot rev-parse --show-toplevel 2>$null
    $toolCommand = "$($Config.tools.codex.command)"
    $toolAvailable = [bool](Get-Command $toolCommand -ErrorAction SilentlyContinue)
    $workflowPath = Join-Path $script:StartupRoot ".github/workflows"
    $workflowExists = Test-Path $workflowPath
    $mcpReport = Get-McpHealthReport -ProjectRoot $script:StartupRoot

    return @(
        [pscustomobject]@{
            Name = "Git repository"
            Ok = -not [string]::IsNullOrWhiteSpace($gitRoot)
            Detail = if ($gitRoot) { $gitRoot } else { "git repository not detected" }
        },
        [pscustomobject]@{
            Name = "Config file"
            Ok = (Test-Path $ConfigPath)
            Detail = $ConfigPath
        },
        [pscustomobject]@{
            Name = "State file"
            Ok = (Test-Path $StatePath)
            Detail = $StatePath
        },
        [pscustomobject]@{
            Name = "Codex command"
            Ok = $toolAvailable
            Detail = $toolCommand
        },
        [pscustomobject]@{
            Name = "CI workflow"
            Ok = $workflowExists
            Detail = if ($workflowExists) { $workflowPath } else { "no .github/workflows directory" }
        },
        [pscustomobject]@{
            Name = "MCP status"
            Ok = $true
            Detail = $mcpReport.summary
        }
    )
}

function Update-BootstrapExecutionState {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [switch]$PreviewOnly
    )

    if (-not (Test-Path $StatePath)) {
        if ($PreviewOnly) {
            return [pscustomobject]@{
                phase = "Monitor"
                start_time = $null
                last_bootstrap_at = $null
            }
        }

        throw "state.json が見つかりません: $StatePath"
    }

    $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($state.PSObject.Properties.Name -contains "execution") -or $null -eq $state.execution) {
        $state | Add-Member -NotePropertyName "execution" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $timestamp = (Get-Date).ToString("o")
    $state.execution | Add-Member -NotePropertyName "phase" -NotePropertyValue "Monitor" -Force
    $state.execution | Add-Member -NotePropertyName "start_time" -NotePropertyValue $timestamp -Force
    $state.execution | Add-Member -NotePropertyName "last_bootstrap_at" -NotePropertyValue $timestamp -Force

    if ($PreviewOnly) {
        return $state.execution
    }

    $json = $state | ConvertTo-Json -Depth 20
    Set-Content -Path $StatePath -Value $json -Encoding UTF8 -NoNewline
    return $state.execution
}

function Publish-BootstrapPhaseTransition {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [switch]$PreviewOnly
    )

    if ($PreviewOnly -or -not (Test-Path $StatePath)) {
        return $null
    }

    Initialize-MessageBus -StatePath $StatePath | Out-Null
    return (Publish-BusMessage -Topic "phase.transition" -Publisher "Start-CodexBootstrap" -Payload @{
            from   = "Idle"
            to     = "Monitor"
            source = "bootstrap"
        } -StatePath $StatePath)
}

function Write-BootstrapBanner {
    Write-Host ""
    Write-Host "Codex StartUp Bootstrap" -ForegroundColor Cyan
    Write-Host "Codex-native startup preflight" -ForegroundColor Cyan
    Write-Host ""
}

function Write-BootstrapSummary {
    param([Parameter(Mandatory)][object]$Summary)

    Write-Host "Bootstrap Summary" -ForegroundColor Magenta
    Write-Host ("  Config      : {0}" -f $Summary.ConfigPath)
    Write-Host ("  State       : {0}" -f $Summary.StatePath)
    Write-Host ("  Tool        : {0}" -f $Summary.ToolCommand)
    Write-Host ("  Tool Ready  : {0}" -f $(if ($Summary.ToolAvailable) { "yes" } else { "no" }))
    Write-Host ("  Token Zone  : {0} ({1}%)" -f $Summary.TokenZone, $Summary.TokenUsed)
    Write-Host ("  MCP         : {0}" -f $Summary.McpStatus)
    Write-Host ("  Mode        : {0}" -f $(if ($Summary.NonInteractive) { "non-interactive" } else { "interactive" }))
    if ($Summary.DryRun) {
        Write-Host "  Dry Run     : enabled"
    }
    Write-Host ""
}

function Write-BootstrapPreflightChecks {
    param([Parameter(Mandatory)][object[]]$Checks)

    Write-Host "Preflight Checks" -ForegroundColor Magenta
    foreach ($check in $Checks) {
        $mark = if ($check.Ok) { "[OK]" } else { "[WARN]" }
        $color = if ($check.Ok) { "Green" } else { "Yellow" }
        Write-Host ("  {0} {1}: {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $color
    }
    Write-Host ""
}

function Get-BootstrapReadiness {
    param([Parameter(Mandatory)][object[]]$Checks)

    $mandatoryNames = @(
        "Git repository",
        "Config file",
        "Codex command"
    )

    $failedMandatory = @($Checks | Where-Object { $_.Name -in $mandatoryNames -and -not $_.Ok })
    $warnings = @($Checks | Where-Object { -not $_.Ok })

    if ($failedMandatory.Count -gt 0) {
        return [pscustomobject]@{
            Status = "BLOCKED"
            Ready = $false
            WarningCount = $warnings.Count
            BlockingChecks = @($failedMandatory.Name)
        }
    }

    if ($warnings.Count -gt 0) {
        return [pscustomobject]@{
            Status = "READY_WITH_WARNINGS"
            Ready = $true
            WarningCount = $warnings.Count
            BlockingChecks = @()
        }
    }

    return [pscustomobject]@{
        Status = "READY"
        Ready = $true
        WarningCount = 0
        BlockingChecks = @()
    }
}

function Write-BootstrapReadiness {
    param([Parameter(Mandatory)][object]$Readiness)

    $color = switch ($Readiness.Status) {
        "READY" { "Green" }
        "READY_WITH_WARNINGS" { "Yellow" }
        default { "Red" }
    }

    Write-Host ("Readiness: {0}" -f $Readiness.Status) -ForegroundColor $color
    if (@($Readiness.BlockingChecks).Count -gt 0) {
        Write-Host ("  Blocking: {0}" -f ($Readiness.BlockingChecks -join ", ")) -ForegroundColor Red
    }
    elseif ($Readiness.WarningCount -gt 0) {
        Write-Host ("  Warnings: {0}" -f $Readiness.WarningCount) -ForegroundColor Yellow
    }
    Write-Host ""
}

function Get-BootstrapLogProjectName {
    return "bootstrap"
}

function Initialize-BootstrapConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [switch]$PreviewOnly
    )

    if (Test-Path $ConfigPath) {
        return [pscustomobject]@{
            Exists   = $true
            Created  = $false
            Path     = $ConfigPath
            Message  = "config.json already exists"
        }
    }

    $templatePath = Join-Path (Split-Path $ConfigPath -Parent) "config.json.template"
    if (-not (Test-Path $templatePath)) {
        throw "config.json.template が見つかりません: $templatePath"
    }

    if ($PreviewOnly) {
        return [pscustomobject]@{
            Exists   = $false
            Created  = $false
            Path     = $ConfigPath
            Message  = "config.json would be created from config.json.template"
        }
    }

    Copy-Item -Path $templatePath -Destination $ConfigPath -Force
    Write-Host "[SETUP] config.json を config.json.template から作成しました。" -ForegroundColor Green
    Write-Host "        必要に応じて config/config.json を編集してください:" -ForegroundColor Yellow
    Write-Host "          projectsDir : プロジェクトルートディレクトリ" -ForegroundColor Yellow
    Write-Host "          registeredProjects.roots : 登録プロジェクト候補ルート" -ForegroundColor Yellow
    Write-Host "          supervisor  : Codex Supervisor 適用設定" -ForegroundColor Yellow
    Write-Host ""

    return [pscustomobject]@{
        Exists   = $false
        Created  = $true
        Path     = $ConfigPath
        Message  = "config.json created from config.json.template"
    }
}

$bootstrapSucceeded = $false
$config = $null
$configPath = $null
$statePath = $null

try {
    Write-BootstrapBanner

    $configPath = Get-StartupConfigPath -StartupRoot $script:StartupRoot
    $configResult = Initialize-BootstrapConfig -ConfigPath $configPath -PreviewOnly:$DryRun
    Write-Host ("Config: {0}" -f $configResult.Message) -ForegroundColor $(
        if ($configResult.Created) { "Green" }
        elseif ($configResult.Exists) { "Cyan" }
        else { "Yellow" }
    )
    $configSourcePath = $configPath
    if ($DryRun -and -not $configResult.Exists) {
        $configSourcePath = Join-Path (Split-Path $configPath -Parent) "config.json.template"
    }
    $config = Import-LauncherConfig -ConfigPath $configSourcePath
    if (-not $DryRun) {
        Start-SessionLog -Config $config -ProjectName (Get-BootstrapLogProjectName) -ToolName "codex-bootstrap" | Out-Null
    }
    Assert-StartupConfigSchema -ConfigPath $configSourcePath | Out-Null

    if (-not $config.tools.codex.enabled) {
        throw "config.json で tools.codex.enabled が false です。"
    }

    $statePath = Get-BootstrapStatePath
    $stateResult = Initialize-BootstrapState -StatePath $statePath -PreviewOnly:$DryRun
    Write-Host ("State: {0}" -f $stateResult.Message) -ForegroundColor $(if ($stateResult.Created) { "Green" } elseif ($stateResult.Exists) { "Cyan" } else { "Yellow" })
    $executionState = Update-BootstrapExecutionState -StatePath $statePath -PreviewOnly:$DryRun
    $phaseMessageId = Publish-BootstrapPhaseTransition -StatePath $statePath -PreviewOnly:$DryRun

    $checks = Get-BootstrapPreflightChecks -ConfigPath $configSourcePath -StatePath $statePath -Config $config
    Write-BootstrapPreflightChecks -Checks $checks
    $readiness = Get-BootstrapReadiness -Checks $checks
    Write-BootstrapReadiness -Readiness $readiness

    $summary = Get-BootstrapSummary -ConfigPath $configPath -StatePath $statePath -Config $config
    Write-BootstrapSummary -Summary $summary

    if (-not $readiness.Ready) {
        throw "Bootstrap readiness blocked: $($readiness.BlockingChecks -join ', ')"
    }

    if (-not $summary.ToolAvailable) {
        throw "Codex コマンドが見つかりません: $($summary.ToolCommand)"
    }

    Write-Host ("Execution Phase: {0}" -f $executionState.phase) -ForegroundColor Cyan
    if ($phaseMessageId) {
        Write-Host ("Phase Transition Message: {0}" -f $phaseMessageId) -ForegroundColor Cyan
    }

    $bootstrapSucceeded = $true
    exit 0
}
catch {
    Show-Error -Message $_.Exception.Message -Details @{
        Script = "Start-CodexBootstrap"
        ConfigPath = if ($configPath) { $configPath } else { "(unresolved)" }
        StatePath = if ($statePath) { $statePath } else { "(unresolved)" }
    } -ThrowAfter $false
    exit 1
}
finally {
    if ($config -and -not $DryRun) {
        Invoke-LogRotation -Config $config
        Stop-SessionLog -Success:$bootstrapSucceeded
    }
}
