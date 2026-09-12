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
                logDir          = (Join-Path $script:CaseRoot "logs")
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
                humanDecisionRequired     = @("final-choice", "high-risk-merge", "release", "publish")
            }
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
    }
}

Describe "Start-CodexBootstrap" {
    BeforeEach {
        $script:CaseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CaseRoot | Out-Null
        $script:ConfigPath = Join-Path $script:CaseRoot "config.json"
        $script:StatePath = Join-Path $script:CaseRoot "state.json"
        New-TestConfigFile -Path $script:ConfigPath
    }

    It "DryRun では state.json を作成せず成功する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:BootstrapScript -DryRun -NonInteractive 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
        ($output -join "`n") | Should -Match "Bootstrap Summary"
        ($output -join "`n") | Should -Match "Preflight Checks"
        ($output -join "`n") | Should -Match "Readiness: READY"
    }

    It "初回 DryRun は template を検証し config と state と logs を作成しない" {
        $templatePath = Join-Path $script:CaseRoot "config.json.template"
        Move-Item $script:ConfigPath $templatePath
        $templateHash = (Get-FileHash $templatePath).Hash
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:BootstrapScript -DryRun -NonInteractive 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match "Readiness: READY"
        (Test-Path $script:ConfigPath) | Should -BeFalse
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
        (Get-FileHash $templatePath).Hash | Should -Be $templateHash
    }

    It "DryRun は既存 config と state と期限切れログを変更しない" {
        Copy-Item (Join-Path $script:RepoRoot "state.json.example") $script:StatePath
        $logDir = Join-Path $script:CaseRoot "logs"
        New-Item -ItemType Directory $logDir -Force | Out-Null
        $logPath = Join-Path $logDir "test-startup-old-SUCCESS.log"
        Set-Content $logPath "preserve"
        (Get-Item $logPath).LastWriteTime = (Get-Date).AddDays(-100)
        $before = @(Get-ChildItem $script:CaseRoot -File -Recurse | Sort-Object FullName | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json)
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        & pwsh -NoProfile -File $script:BootstrapScript -DryRun -NonInteractive | Out-Null

        $LASTEXITCODE | Should -Be 0
        $after = @(Get-ChildItem $script:CaseRoot -File -Recurse | Sort-Object FullName | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json)
        $after | Should -Be $before
    }

    It "初回 DryRun は不正 template を拒否しファイルを作成しない" {
        Move-Item $script:ConfigPath (Join-Path $script:CaseRoot "config.json.template")
        Set-Content (Join-Path $script:CaseRoot "config.json.template") '{}'
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:BootstrapScript -DryRun -NonInteractive 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match "必須フィールド"
        (Test-Path $script:ConfigPath) | Should -BeFalse
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
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
        @(Get-ChildItem -Path (Join-Path $script:CaseRoot "logs") -Filter "test-startup-*-SUCCESS.log" -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0
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
