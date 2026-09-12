Set-StrictMode -Version Latest

# ============================================================
# AgentsApiPayload.psm1 — OpenAI Agents API (Managed Plane) の dry-run 契約
#
# 役割:
#   Agents API は OpenAI がホストする Codex ハーネスで、セッション・
#   オーケストレーション・context compaction・サブエージェント委譲を OpenAI 側が担う。
#   本モジュールはその POST /v1/agents/sessions ボディを「実際に呼ばずに」生成し、
#   契約の妥当性と live 実行の前提を検証する。
#
# 重要 (推測でフィールドを足さない):
#   使用するフィールドは 2026-09-12 取得の公式docに実例があるものだけ:
#     agent{model,instructions,tools,multi_agent}
#     environment{type,workspace_directory,capability_directories}
#     input[{role,content[{type,input_text,text}]}]
#     tools: programmatic_tool_calling / mcp{server_label,transport{type,server_url}} / web_search
#   Agents API には **session budget フィールドが存在しない**（Anthropic Managed Agents の
#   max_list_cost に相当するものが公式docに見当たらない）。したがって予算統制は
#   API へ渡すのではなく、本モジュールの localCostGuard（人間承認 + 見積上限）で行う。
#
# 設計:
#   - 純粋関数（config 検証 / payload 生成 / curl 生成 / live 前提判定）と
#     ファイル読み込みを分離し、Pester でネットワーク・ファイル無しに検証できる。
#   - live は既定で拒否する (fail-safe)。enabled / mode=live / 承認 / データ所在承認が
#     すべて揃わない限り Test-AgentsApiLiveAllowed は Allowed=$false を返す。
# ============================================================

$script:DefaultApiBaseUrl = "https://api.openai.com"
$script:DefaultBetaHeader = "agents=v1"
$script:AllowedEnvironmentTypes = @("none", "openai_hosted", "self_hosted")
$script:AllowedToolTypes = @("programmatic_tool_calling", "mcp", "web_search")
$script:AllowedModes = @("disabled", "dry-run", "live")
$script:MaxCapabilityDirectories = 32
$script:SessionCreatePath = "/v1/agents/sessions"

function Get-AgentsApiSessionCreatePath { return $script:SessionCreatePath }
function Get-AgentsApiMaxCapabilityDirectories { return $script:MaxCapabilityDirectories }

function Get-AgentsApiConfigPath {
    <#
    .SYNOPSIS
        Agents API 設定ファイルのパスを返す。
    #>
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return (Join-Path $RepoRoot "config/agents-api.json")
}

function Get-AgentsApiProperty {
    <#
    .SYNOPSIS
        入れ子オブジェクトから安全にプロパティを取り出す (内部ヘルパ)。
    #>
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    if (-not ($InputObject.PSObject.Properties.Name -contains $Name)) { return $null }
    return $InputObject.$Name
}

function Test-AgentsApiConfig {
    <#
    .SYNOPSIS
        設定契約の妥当性を検証する。
    .OUTPUTS
        [pscustomobject] Valid / Errors / Warnings
    #>
    param([Parameter(Mandatory = $true)][object]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $mode = [string](Get-AgentsApiProperty -InputObject $Config -Name "mode")
    if ($mode -notin $script:AllowedModes) {
        $errors.Add("mode must be one of: $($script:AllowedModes -join ', ') (got '$mode')")
    }

    if (-not (Get-AgentsApiProperty -InputObject $Config -Name "model")) {
        $errors.Add("model is required")
    }

    $env = Get-AgentsApiProperty -InputObject $Config -Name "environment"
    if ($null -eq $env) {
        $errors.Add("environment is required")
    }
    else {
        $envType = [string](Get-AgentsApiProperty -InputObject $env -Name "type")
        if ($envType -notin $script:AllowedEnvironmentTypes) {
            $errors.Add("environment.type must be one of: $($script:AllowedEnvironmentTypes -join ', ') (got '$envType')")
        }

        $dirs = Get-AgentsApiProperty -InputObject $env -Name "capability_directories"
        if ($null -ne $dirs) {
            $list = @($dirs)
            if ($list.Count -gt $script:MaxCapabilityDirectories) {
                $errors.Add("environment.capability_directories must be <= $script:MaxCapabilityDirectories (got $($list.Count))")
            }
            foreach ($d in $list) {
                $s = [string]$d
                if (-not $s.StartsWith("/")) {
                    $errors.Add("capability directory must be an absolute path: '$s'")
                }
                if ($s -match '(^|/)\.\.?(/|$)') {
                    $errors.Add("capability directory must not contain '.' or '..' segments: '$s'")
                }
            }
        }
    }

    $tools = Get-AgentsApiProperty -InputObject $Config -Name "tools"
    if ($null -ne $tools) {
        foreach ($t in @($tools)) {
            $type = [string](Get-AgentsApiProperty -InputObject $t -Name "type")
            if ($type -notin $script:AllowedToolTypes) {
                $errors.Add("tool type must be one of: $($script:AllowedToolTypes -join ', ') (got '$type')")
            }
            if ($type -eq "mcp") {
                if (-not (Get-AgentsApiProperty -InputObject $t -Name "server_label")) {
                    $errors.Add("mcp tool requires server_label")
                }
                $transport = Get-AgentsApiProperty -InputObject $t -Name "transport"
                if ($null -eq $transport -or -not (Get-AgentsApiProperty -InputObject $transport -Name "server_url")) {
                    $errors.Add("mcp tool requires transport.server_url")
                }
            }
        }
    }

    $multi = Get-AgentsApiProperty -InputObject $Config -Name "multiAgent"
    if ($null -ne $multi -and (Get-AgentsApiProperty -InputObject $multi -Name "enabled")) {
        $max = Get-AgentsApiProperty -InputObject $multi -Name "maxConcurrentSubagents"
        if ($null -ne $max -and [int]$max -lt 1) {
            $errors.Add("multiAgent.maxConcurrentSubagents must be a positive integer")
        }
    }

    if ($mode -eq "live") {
        $guard = Get-AgentsApiProperty -InputObject $Config -Name "localCostGuard"
        if ($null -eq $guard -or -not (Get-AgentsApiProperty -InputObject $guard -Name "approvalId")) {
            $warnings.Add("mode=live but localCostGuard.approvalId is empty (live will be refused)")
        }
        $dr = Get-AgentsApiProperty -InputObject $Config -Name "dataResidency"
        if ($null -eq $dr -or -not (Get-AgentsApiProperty -InputObject $dr -Name "approved")) {
            $warnings.Add("mode=live but dataResidency.approved is false (US-only, no ZDR; live will be refused)")
        }
    }

    return [pscustomobject]@{
        Valid    = ($errors.Count -eq 0)
        Errors   = $errors.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function New-AgentsApiSessionPayload {
    <#
    .SYNOPSIS
        POST /v1/agents/sessions のボディを生成する (公式docの実例にあるフィールドのみ)。
    .PARAMETER InputText
        セッションへの初期入力。
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputText
    )

    $check = Test-AgentsApiConfig -Config $Config
    if (-not $check.Valid) {
        throw "invalid agents-api config: $($check.Errors -join '; ')"
    }
    if ([string]::IsNullOrWhiteSpace($InputText)) {
        throw "input text must not be empty"
    }

    $env = Get-AgentsApiProperty -InputObject $Config -Name "environment"
    $environment = [ordered]@{ type = [string](Get-AgentsApiProperty -InputObject $env -Name "type") }
    $workspace = Get-AgentsApiProperty -InputObject $env -Name "workspace_directory"
    if ($workspace) { $environment["workspace_directory"] = [string]$workspace }
    $dirs = Get-AgentsApiProperty -InputObject $env -Name "capability_directories"
    if ($null -ne $dirs) { $environment["capability_directories"] = @($dirs) }

    $agent = [ordered]@{
        model        = [string](Get-AgentsApiProperty -InputObject $Config -Name "model")
        instructions = [string](Get-AgentsApiProperty -InputObject $Config -Name "instructions")
    }

    $tools = Get-AgentsApiProperty -InputObject $Config -Name "tools"
    if ($null -ne $tools) {
        $toolList = @()
        foreach ($t in @($tools)) {
            $type = [string](Get-AgentsApiProperty -InputObject $t -Name "type")
            if ($type -eq "mcp") {
                $transport = Get-AgentsApiProperty -InputObject $t -Name "transport"
                $toolList += [ordered]@{
                    type         = "mcp"
                    server_label = [string](Get-AgentsApiProperty -InputObject $t -Name "server_label")
                    transport    = [ordered]@{
                        type       = [string](Get-AgentsApiProperty -InputObject $transport -Name "type")
                        server_url = [string](Get-AgentsApiProperty -InputObject $transport -Name "server_url")
                    }
                }
            }
            else {
                $toolList += [ordered]@{ type = $type }
            }
        }
        $agent["tools"] = $toolList
    }

    $multi = Get-AgentsApiProperty -InputObject $Config -Name "multiAgent"
    if ($null -ne $multi -and (Get-AgentsApiProperty -InputObject $multi -Name "enabled")) {
        $ma = [ordered]@{ enabled = $true }
        $max = Get-AgentsApiProperty -InputObject $multi -Name "maxConcurrentSubagents"
        if ($null -ne $max) { $ma["max_concurrent_subagents"] = [int]$max }
        $agent["multi_agent"] = $ma
    }

    $body = [ordered]@{
        agent       = $agent
        environment = $environment
        input       = @(
            [ordered]@{
                role    = "user"
                content = @(
                    [ordered]@{ type = "input_text"; text = $InputText }
                )
            }
        )
    }

    return $body
}

function Test-AgentsApiLiveAllowed {
    <#
    .SYNOPSIS
        live 実行の前提が揃っているか判定する (fail-safe: 既定は拒否)。
    .OUTPUTS
        [pscustomobject] Allowed / Reason
    #>
    param([Parameter(Mandatory = $true)][object]$Config)

    if (-not (Get-AgentsApiProperty -InputObject $Config -Name "enabled")) {
        return [pscustomobject]@{ Allowed = $false; Reason = "config-disabled" }
    }

    $mode = [string](Get-AgentsApiProperty -InputObject $Config -Name "mode")
    if ($mode -ne "live") {
        return [pscustomobject]@{ Allowed = $false; Reason = "mode-not-live (mode=$mode)" }
    }

    $check = Test-AgentsApiConfig -Config $Config
    if (-not $check.Valid) {
        return [pscustomobject]@{ Allowed = $false; Reason = "invalid-config: $($check.Errors -join '; ')" }
    }

    $guard = Get-AgentsApiProperty -InputObject $Config -Name "localCostGuard"
    $approval = [string](Get-AgentsApiProperty -InputObject $guard -Name "approvalId")
    if (-not $approval) {
        return [pscustomobject]@{ Allowed = $false; Reason = "cost-approval-missing" }
    }

    $dr = Get-AgentsApiProperty -InputObject $Config -Name "dataResidency"
    if (-not (Get-AgentsApiProperty -InputObject $dr -Name "approved")) {
        return [pscustomobject]@{ Allowed = $false; Reason = "data-residency-not-approved (US-only, no ZDR)" }
    }

    return [pscustomobject]@{ Allowed = $true; Reason = "ok" }
}

function ConvertTo-AgentsApiCurlCommand {
    <#
    .SYNOPSIS
        生成した payload を実行する curl コマンド文字列を作る (実行はしない)。
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Payload
    )

    $base = [string](Get-AgentsApiProperty -InputObject $Config -Name "apiBaseUrl")
    if (-not $base) { $base = $script:DefaultApiBaseUrl }
    $beta = [string](Get-AgentsApiProperty -InputObject $Config -Name "betaHeader")
    if (-not $beta) { $beta = $script:DefaultBetaHeader }

    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    # API キーは環境変数参照のままにする (値は文字列に埋め込まない)。
    return "curl -sS -X POST `"$base$script:SessionCreatePath`" -H `"OpenAI-Beta: $beta`" -H `"Authorization: Bearer `$OPENAI_API_KEY`" -H `"Content-Type: application/json`" -d '$json'"
}

function Invoke-AgentsApiDryRun {
    <#
    .SYNOPSIS
        設定を読み、payload と curl を生成して返す (ネットワークを一切使わない)。
    .OUTPUTS
        [pscustomobject] Available / Reason / Valid / Errors / LiveAllowed / LiveReason / Payload / Curl
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$InputText
    )

    $path = Get-AgentsApiConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false; Reason = "config-not-found ($path)"
            Valid = $false; Errors = @(); LiveAllowed = $false; LiveReason = "config-not-found"
            Payload = $null; Curl = $null
        }
    }

    try {
        $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Available = $false; Reason = "config-parse-error: $($_.Exception.Message)"
            Valid = $false; Errors = @(); LiveAllowed = $false; LiveReason = "config-parse-error"
            Payload = $null; Curl = $null
        }
    }

    $check = Test-AgentsApiConfig -Config $config
    $live = Test-AgentsApiLiveAllowed -Config $config

    $payload = $null
    $curl = $null
    if ($check.Valid) {
        $payload = New-AgentsApiSessionPayload -Config $config -InputText $InputText
        $curl = ConvertTo-AgentsApiCurlCommand -Config $config -Payload $payload
    }

    return [pscustomobject]@{
        Available   = $true
        Reason      = "ok"
        Valid       = $check.Valid
        Errors      = $check.Errors
        Warnings    = $check.Warnings
        LiveAllowed = $live.Allowed
        LiveReason  = $live.Reason
        Payload     = $payload
        Curl        = $curl
    }
}

Export-ModuleMember -Function @(
    "Get-AgentsApiSessionCreatePath",
    "Get-AgentsApiMaxCapabilityDirectories",
    "Get-AgentsApiConfigPath",
    "Test-AgentsApiConfig",
    "New-AgentsApiSessionPayload",
    "Test-AgentsApiLiveAllowed",
    "ConvertTo-AgentsApiCurlCommand",
    "Invoke-AgentsApiDryRun"
)
