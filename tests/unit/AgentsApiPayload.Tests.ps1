BeforeAll {
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot "scripts/lib/AgentsApiPayload.psm1") -Force

function New-ValidConfig {
    return [pscustomobject]@{
        enabled     = $true
        mode        = "dry-run"
        apiBaseUrl  = "https://api.openai.com"
        betaHeader  = "agents=v1"
        model       = "gpt-6-astra"
        instructions = "investigate"
        environment = [pscustomobject]@{
            type                    = "self_hosted"
            workspace_directory     = "/workspace"
            capability_directories  = @("/workspace/capabilities/skills")
        }
        tools       = @(
            [pscustomobject]@{ type = "programmatic_tool_calling" },
            [pscustomobject]@{
                type = "mcp"; server_label = "openai_docs"
                transport = [pscustomobject]@{ type = "http"; server_url = "https://developers.openai.com/mcp" }
            },
            [pscustomobject]@{ type = "web_search" }
        )
        multiAgent  = [pscustomobject]@{ enabled = $true; maxConcurrentSubagents = 4 }
        localCostGuard = [pscustomobject]@{ requireExplicitApproval = $true; approvalId = ""; maxEstimatedUsd = $null }
        dataResidency  = [pscustomobject]@{ region = "us"; zdr = $false; approved = $false }
    }
}

}

Describe "Get-AgentsApiConfigPath" {
    It "config/agents-api.json を指す" {
        (Get-AgentsApiConfigPath -RepoRoot "/repo") | Should -Match "config[/\\]agents-api\.json$"
    }

    It "create path と capability 上限は公式仕様値" {
        Get-AgentsApiSessionCreatePath | Should -Be "/v1/agents/sessions"
        Get-AgentsApiMaxCapabilityDirectories | Should -Be 32
    }
}

Describe "Test-AgentsApiConfig" {
    It "妥当な設定は Valid" {
        (Test-AgentsApiConfig -Config (New-ValidConfig)).Valid | Should -BeTrue
    }

    It "mode が不正ならエラー" {
        $c = New-ValidConfig; $c.mode = "whenever"
        $r = Test-AgentsApiConfig -Config $c
        $r.Valid | Should -BeFalse
        ($r.Errors -join " ") | Should -Match "mode must be one of"
    }

    It "model 必須" {
        $c = New-ValidConfig; $c.model = ""
        (Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
    }

    It "environment.type は 3 種のみ" {
        $c = New-ValidConfig; $c.environment.type = "on_prem"
        ($r = Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
        ($r.Errors -join " ") | Should -Match "environment.type"
    }

    It "capability directory は絶対パス必須" {
        $c = New-ValidConfig; $c.environment.capability_directories = @("relative/skills")
        ($r = Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
        ($r.Errors -join " ") | Should -Match "absolute path"
    }

    It "capability directory に .. を許さない" {
        $c = New-ValidConfig; $c.environment.capability_directories = @("/workspace/../etc")
        (Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
    }

    It "capability directory は 32 件まで" {
        $c = New-ValidConfig
        $c.environment.capability_directories = @(1..33 | ForEach-Object { "/workspace/s$_" })
        ($r = Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
        ($r.Errors -join " ") | Should -Match "must be <= 32"
    }

    It "未知の tool type はエラー" {
        $c = New-ValidConfig; $c.tools = @([pscustomobject]@{ type = "telepathy" })
        (Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
    }

    It "mcp tool は server_label と transport.server_url が必須" {
        $c = New-ValidConfig
        $c.tools = @([pscustomobject]@{ type = "mcp"; server_label = ""; transport = [pscustomobject]@{ type = "http"; server_url = "" } })
        $r = Test-AgentsApiConfig -Config $c
        $r.Valid | Should -BeFalse
        ($r.Errors -join " ") | Should -Match "server_label"
        ($r.Errors -join " ") | Should -Match "server_url"
    }

    It "multiAgent.maxConcurrentSubagents は正の整数" {
        $c = New-ValidConfig; $c.multiAgent = [pscustomobject]@{ enabled = $true; maxConcurrentSubagents = 0 }
        (Test-AgentsApiConfig -Config $c).Valid | Should -BeFalse
    }

    It "mode=live で承認・データ所在が未整備なら警告を出す" {
        $c = New-ValidConfig; $c.mode = "live"
        $r = Test-AgentsApiConfig -Config $c
        $r.Valid | Should -BeTrue
        ($r.Warnings -join " ") | Should -Match "approvalId"
        ($r.Warnings -join " ") | Should -Match "dataResidency"
    }
}

Describe "New-AgentsApiSessionPayload" {
    It "公式docの実例と同じ構造を生成する" {
        $p = New-AgentsApiSessionPayload -Config (New-ValidConfig) -InputText "Investigate"
        $p.agent.model | Should -Be "gpt-6-astra"
        $p.agent.tools.Count | Should -Be 3
        $p.agent.multi_agent.enabled | Should -BeTrue
        $p.agent.multi_agent.max_concurrent_subagents | Should -Be 4
        $p.environment.type | Should -Be "self_hosted"
        $p.environment.workspace_directory | Should -Be "/workspace"
        $p.environment.capability_directories | Should -Contain "/workspace/capabilities/skills"
        $p.input[0].role | Should -Be "user"
        $p.input[0].content[0].type | Should -Be "input_text"
        $p.input[0].content[0].text | Should -Be "Investigate"
    }

    It "mcp tool は server_label と transport を snake_case で出す" {
        $p = New-AgentsApiSessionPayload -Config (New-ValidConfig) -InputText "x"
        $mcp = $p.agent.tools | Where-Object { $_.type -eq "mcp" }
        $mcp.server_label | Should -Be "openai_docs"
        $mcp.transport.type | Should -Be "http"
        $mcp.transport.server_url | Should -Be "https://developers.openai.com/mcp"
    }

    It "session budget フィールドは出力しない (公式docに存在しないため)" {
        $json = (New-AgentsApiSessionPayload -Config (New-ValidConfig) -InputText "x") | ConvertTo-Json -Depth 20
        $json | Should -Not -Match "budget"
        $json | Should -Not -Match "max_list_cost"
    }

    It "environment.type=none では workspace_directory を出さない" {
        $c = New-ValidConfig
        $c.environment = [pscustomobject]@{ type = "none" }
        $p = New-AgentsApiSessionPayload -Config $c -InputText "x"
        ($p.environment.PSObject.Properties.Name) | Should -Not -Contain "workspace_directory"
    }

    It "multiAgent 無効なら multi_agent を出さない" {
        $c = New-ValidConfig; $c.multiAgent = [pscustomobject]@{ enabled = $false }
        $p = New-AgentsApiSessionPayload -Config $c -InputText "x"
        ($p.agent.PSObject.Properties.Name) | Should -Not -Contain "multi_agent"
    }

    It "不正な設定では例外" {
        $c = New-ValidConfig; $c.mode = "bogus"
        { New-AgentsApiSessionPayload -Config $c -InputText "x" } | Should -Throw "*invalid agents-api config*"
    }

    It "空の入力は例外" {
        { New-AgentsApiSessionPayload -Config (New-ValidConfig) -InputText "" } | Should -Throw "*must not be empty*"
    }
}

Describe "Test-AgentsApiLiveAllowed" {
    It "enabled=false なら拒否" {
        $c = New-ValidConfig; $c.enabled = $false; $c.mode = "live"
        ($r = Test-AgentsApiLiveAllowed -Config $c).Allowed | Should -BeFalse
        $r.Reason | Should -Be "config-disabled"
    }

    It "mode=dry-run なら拒否" {
        $c = New-ValidConfig; $c.mode = "dry-run"
        ($r = Test-AgentsApiLiveAllowed -Config $c).Allowed | Should -BeFalse
        $r.Reason | Should -Match "mode-not-live"
    }

    It "承認が無ければ拒否" {
        $c = New-ValidConfig; $c.mode = "live"
        ($r = Test-AgentsApiLiveAllowed -Config $c).Allowed | Should -BeFalse
        $r.Reason | Should -Be "cost-approval-missing"
    }

    It "データ所在が未承認なら拒否" {
        $c = New-ValidConfig; $c.mode = "live"
        $c.localCostGuard = [pscustomobject]@{ requireExplicitApproval = $true; approvalId = "AP-1" }
        ($r = Test-AgentsApiLiveAllowed -Config $c).Allowed | Should -BeFalse
        $r.Reason | Should -Match "data-residency-not-approved"
    }

    It "全て揃えば許可" {
        $c = New-ValidConfig; $c.mode = "live"
        $c.localCostGuard = [pscustomobject]@{ requireExplicitApproval = $true; approvalId = "AP-1" }
        $c.dataResidency = [pscustomobject]@{ region = "us"; zdr = $false; approved = $true }
        ($r = Test-AgentsApiLiveAllowed -Config $c).Allowed | Should -BeTrue
        $r.Reason | Should -Be "ok"
    }

    It "既定 (テンプレート) は live 不可" {
        $template = Join-Path $script:RepoRoot "config/agents-api.json.template"
        $cfg = Get-Content -LiteralPath $template -Raw -Encoding UTF8 | ConvertFrom-Json
        (Test-AgentsApiLiveAllowed -Config $cfg).Allowed | Should -BeFalse
    }
}

Describe "ConvertTo-AgentsApiCurlCommand" {
    It "エンドポイントとベータヘッダを含む" {
        $c = New-ValidConfig
        $p = New-AgentsApiSessionPayload -Config $c -InputText "x"
        $curl = ConvertTo-AgentsApiCurlCommand -Config $c -Payload $p
        $curl | Should -Match "https://api\.openai\.com/v1/agents/sessions"
        $curl | Should -Match "OpenAI-Beta: agents=v1"
    }

    It "API キーの値を埋め込まず環境変数参照にする" {
        $c = New-ValidConfig
        $p = New-AgentsApiSessionPayload -Config $c -InputText "x"
        $curl = ConvertTo-AgentsApiCurlCommand -Config $c -Payload $p
        $curl | Should -Match '\$OPENAI_API_KEY'
        $curl | Should -Not -Match 'sk-'
    }
}

Describe "Invoke-AgentsApiDryRun" {
    It "設定が無ければ Available=false" {
        $root = Join-Path $TestDrive "noconfig"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Invoke-AgentsApiDryRun -RepoRoot $root -InputText "x"
        $r.Available | Should -BeFalse
        $r.Reason | Should -Match "config-not-found"
    }

    It "壊れた JSON でも例外にしない" {
        $root = Join-Path $TestDrive "badconfig"
        New-Item -ItemType Directory -Path (Join-Path $root "config") -Force | Out-Null
        "{oops" | Set-Content -LiteralPath (Join-Path $root "config/agents-api.json") -Encoding UTF8
        $r = Invoke-AgentsApiDryRun -RepoRoot $root -InputText "x"
        $r.Available | Should -BeFalse
        $r.Reason | Should -Match "config-parse-error"
    }

    It "テンプレートを置けば payload と curl を生成し、live は拒否する" {
        $root = Join-Path $TestDrive "okconfig"
        New-Item -ItemType Directory -Path (Join-Path $root "config") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "config/agents-api.json.template") `
            -Destination (Join-Path $root "config/agents-api.json")

        $r = Invoke-AgentsApiDryRun -RepoRoot $root -InputText "Investigate the incident"
        $r.Available | Should -BeTrue
        $r.Valid | Should -BeTrue
        $r.Payload.agent.model | Should -Be "gpt-6-astra"
        $r.Curl | Should -Match "/v1/agents/sessions"
        $r.LiveAllowed | Should -BeFalse
        $r.LiveReason | Should -Be "config-disabled"
    }
}

Describe "実テンプレートの整合" {
    It "config/agents-api.json.template が契約を満たす" {
        $template = Join-Path $script:RepoRoot "config/agents-api.json.template"
        Test-Path -LiteralPath $template | Should -BeTrue
        $cfg = Get-Content -LiteralPath $template -Raw -Encoding UTF8 | ConvertFrom-Json
        $r = Test-AgentsApiConfig -Config $cfg
        $r.Valid | Should -BeTrue -Because ($r.Errors -join "; ")
    }

    It "テンプレートは既定で disabled (誤って live にならない)" {
        $template = Join-Path $script:RepoRoot "config/agents-api.json.template"
        $cfg = Get-Content -LiteralPath $template -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg.enabled | Should -BeFalse
        $cfg.mode | Should -Be "disabled"
        $cfg.dataResidency.approved | Should -BeFalse
    }
}
