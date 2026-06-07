BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BootstrapScript = Join-Path $script:RepoRoot "scripts/main/Start-CodexBootstrap.ps1"

    function New-TestConfigFile {
        param(
            [string]$Path,
            [bool]$CodexEnabled = $true,
            [string]$Command = "pwsh"
        )

        $config = [ordered]@{
            version            = "1.0.0"
            projectsDir        = "/home/kensan/Projects"
            registeredProjects = [ordered]@{
                enabled       = $true
                roots         = @("/home/kensan/Projects")
                include       = @()
                exclude       = @()
                maxCandidates = 80
            }
            logging            = [ordered]@{
                enabled         = $true
                logDir          = (Join-Path $TestDrive "logs")
                logPrefix       = "test-startup"
                successKeepDays = 30
                failureKeepDays = 90
            }
            tools              = [ordered]@{
                defaultTool = "codex"
                codex       = [ordered]@{
                    enabled        = $CodexEnabled
                    command        = $Command
                    args           = @("--version")
                    installCommand = "npm install -g @openai/codex"
                    env            = [ordered]@{}
                    apiKeyEnvVar   = "OPENAI_API_KEY"
                }
            }
            supervisor         = [ordered]@{
                enabled                   = $true
                applyToRegisteredProjects = $true
                mode                      = "cto-autonomous"
                humanDecisionRequired     = @("final-choice", "merge", "release")
            }
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
    }
}

Describe "Start-CodexBootstrap" {
    BeforeEach {
        $script:ConfigPath = Join-Path $TestDrive "config.json"
        $script:StatePath = Join-Path $TestDrive "state.json"
        New-TestConfigFile -Path $script:ConfigPath
    }

    It "DryRun では state.json を作成せず成功する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:BootstrapScript -DryRun -NonInteractive 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        (Test-Path $script:StatePath) | Should -BeFalse
        ($output -join "`n") | Should -Match "Bootstrap Summary"
        ($output -join "`n") | Should -Match "Preflight Checks"
        ($output -join "`n") | Should -Match "Readiness: READY"
    }

    It "通常実行では state.json を初期化する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        & pwsh -NoProfile -File $script:BootstrapScript -NonInteractive | Out-Null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        (Test-Path $script:StatePath) | Should -BeTrue
        $state = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        $state.goal.title | Should -Be "Linux Codex startup execution"
        $state.execution.phase | Should -Be "Monitor"
        $state.execution.start_time | Should -Not -BeNullOrEmpty
        @($state.message_bus."phase.transition").Count | Should -Be 1
        $state.message_bus."phase.transition"[0].payload.to | Should -Be "Monitor"
        @(Get-ChildItem -Path (Join-Path $TestDrive "logs") -Filter "test-startup-*-SUCCESS.log" -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0
        (& pwsh -NoProfile -File $script:BootstrapScript -NonInteractive 2>&1 | Out-String) | Should -Match "Readiness: READY"
    }

    It "codex 無効設定を拒否する" {
        New-TestConfigFile -Path $script:ConfigPath -CodexEnabled $false
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:BootstrapScript -NonInteractive 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        ($output -join "`n") | Should -Match "tools.codex.enabled"
        ($output -join "`n") | Should -Match "Error Category: CONFIG_INVALID"
    }

    AfterEach {
        Remove-Item Env:AI_STARTUP_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:AI_STARTUP_STATE_PATH -ErrorAction SilentlyContinue
    }
}
