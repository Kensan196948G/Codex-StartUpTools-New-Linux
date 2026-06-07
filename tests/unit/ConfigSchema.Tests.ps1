BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot "scripts/lib/ConfigSchema.ps1")

    function Get-ValidConfig {
        [pscustomobject]@{
            version            = "1.0.0"
            projectsDir        = "/home/kensan/Projects"
            registeredProjects = [pscustomobject]@{
                enabled       = $true
                roots         = @("/home/kensan/Projects")
                include       = @()
                exclude       = @()
                maxCandidates = 80
            }
            tools              = [pscustomobject]@{
                defaultTool = "codex"
                codex       = [pscustomobject]@{
                    enabled        = $true
                    command        = "codex"
                    args           = @("--full-auto")
                    installCommand = "npm install -g @openai/codex"
                    env            = [pscustomobject]@{}
                    apiKeyEnvVar   = "OPENAI_API_KEY"
                }
            }
            supervisor         = [pscustomobject]@{
                enabled                   = $true
                applyToRegisteredProjects = $true
                mode                      = "cto-autonomous"
                humanDecisionRequired     = @("final-choice", "merge", "release")
            }
        }
    }
}

Describe "Test-IntegerValueInRange" {
    It "null は false" { Test-IntegerValueInRange -Value $null -Minimum 1 | Should -BeFalse }
    It "範囲内は true" { Test-IntegerValueInRange -Value 10 -Minimum 1 -Maximum 100 | Should -BeTrue }
    It "範囲外は false" { Test-IntegerValueInRange -Value 0 -Minimum 1 | Should -BeFalse }
}

Describe "Test-StartupConfigSchema" {
    It "有効設定でエラーを返さない" {
        @(Test-StartupConfigSchema -Config (Get-ValidConfig)).Count | Should -Be 0
    }

    It "defaultTool 不正値を拒否する" {
        $config = Get-ValidConfig
        $config.tools.defaultTool = "claude"
        (Test-StartupConfigSchema -Config $config) | Should -Contain "tools.defaultTool は codex である必要があります"
    }

    It "registeredProjects.roots の空配列を拒否する" {
        $config = Get-ValidConfig
        $config.registeredProjects.roots = @()
        (Test-StartupConfigSchema -Config $config) | Should -Contain "registeredProjects.roots は 1 件以上の配列である必要があります"
    }

    It "supervisor.humanDecisionRequired が配列でない場合を拒否する" {
        $config = Get-ValidConfig
        $config.supervisor.humanDecisionRequired = "merge"
        (Test-StartupConfigSchema -Config $config) | Should -Contain "supervisor.humanDecisionRequired は配列である必要があります"
    }

    It "backupConfig.sensitiveKeys が配列でない場合を拒否する" {
        $config = Get-ValidConfig
        $config | Add-Member -NotePropertyName "backupConfig" -NotePropertyValue ([pscustomobject]@{
            sensitiveKeys = "single-key"
        }) -Force
        (Test-StartupConfigSchema -Config $config) | Should -Contain "backupConfig.sensitiveKeys は配列である必要があります"
    }
}

Describe "Assert-StartupConfigSchema" {
    It "存在しないファイルを拒否する" {
        { Assert-StartupConfigSchema -ConfigPath "/nonexistent/config.json" } | Should -Throw
    }

    It "有効ファイルで true を返す" {
        $path = Join-Path $TestDrive "valid-config.json"
        Get-ValidConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Assert-StartupConfigSchema -ConfigPath $path | Should -BeTrue
    }
}
