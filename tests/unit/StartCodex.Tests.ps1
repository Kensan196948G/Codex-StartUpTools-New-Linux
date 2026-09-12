BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:StartScript = Join-Path $script:RepoRoot "scripts/main/Start-Codex.ps1"

    function New-TestConfigFile {
        param(
            [string]$Path,
            [string]$ProjectsDir,
            [string]$Command = "pwsh"
        )

        $config = [ordered]@{
            version            = "1.0.0"
            projectsDir        = $ProjectsDir
            registeredProjects = [ordered]@{
                enabled       = $true
                roots         = @($ProjectsDir)
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
                    enabled        = $true
                    command        = $Command
                    args           = @("-NoProfile", "-Command", "exit 0")
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
            recentProjects = [ordered]@{
                enabled     = $true
                maxHistory  = 10
                historyFile = (Join-Path $script:CaseRoot "recent-projects.json")
            }
        }

        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
    }
}

Describe "Start-Codex" {
    BeforeEach {
        $script:CaseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CaseRoot | Out-Null
        $script:ProjectRoot = Join-Path $script:CaseRoot "projects"
        $script:ProjectPath = Join-Path $script:ProjectRoot "DemoProject"
        $script:ConfigPath = Join-Path $script:CaseRoot "config.json"
        $script:StatePath = Join-Path $script:CaseRoot "state.json"

        New-Item -ItemType Directory -Path $script:ProjectPath -Force | Out-Null
        New-TestConfigFile -Path $script:ConfigPath -ProjectsDir $script:ProjectRoot
    }

    It "DryRun で起動計画を表示する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:StartScript -Project "DemoProject" -NonInteractive -DryRun 2>&1
        $exitCode = $LASTEXITCODE
        $pathPattern = [regex]::Escape($script:ProjectPath)

        $exitCode | Should -Be 0
        ($output -join "`n") | Should -Match "Codex Launch Plan"
        ($output -join "`n") | Should -Match $pathPattern
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "recent-projects.json")) | Should -BeFalse
    }

    It "初回 DryRun は template から起動計画を表示し runtime ファイルを作成しない" {
        $templatePath = Join-Path $script:CaseRoot "config.json.template"
        Move-Item $script:ConfigPath $templatePath
        $templateHash = (Get-FileHash $templatePath).Hash
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:StartScript -Project "DemoProject" -NonInteractive -DryRun 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match "Codex Launch Plan"
        ($output -join "`n") | Should -Match ([regex]::Escape($script:ProjectPath))
        (Test-Path $script:ConfigPath) | Should -BeFalse
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "recent-projects.json")) | Should -BeFalse
        (Get-FileHash $templatePath).Hash | Should -Be $templateHash
    }

    It "DryRun は既存 config と state と履歴と期限切れログを変更しない" {
        Copy-Item (Join-Path $script:RepoRoot "state.json.example") $script:StatePath
        Set-Content (Join-Path $script:CaseRoot "recent-projects.json") '{"projects":[]}'
        $logDir = Join-Path $script:CaseRoot "logs"
        New-Item -ItemType Directory $logDir -Force | Out-Null
        $logPath = Join-Path $logDir "test-startup-old-SUCCESS.log"
        Set-Content $logPath "preserve"
        (Get-Item $logPath).LastWriteTime = (Get-Date).AddDays(-100)
        $before = @(Get-ChildItem $script:CaseRoot -File -Recurse | Sort-Object FullName | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json)
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        & pwsh -NoProfile -File $script:StartScript -Project "DemoProject" -NonInteractive -DryRun | Out-Null

        $LASTEXITCODE | Should -Be 0
        $after = @(Get-ChildItem $script:CaseRoot -File -Recurse | Sort-Object FullName | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json)
        $after | Should -Be $before
    }

    It "初回 DryRun は不正 template を拒否し起動計画と runtime ファイルを生成しない" {
        Move-Item $script:ConfigPath (Join-Path $script:CaseRoot "config.json.template")
        Set-Content (Join-Path $script:CaseRoot "config.json.template") '{}'
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:StartScript -Project "DemoProject" -NonInteractive -DryRun 2>&1

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match "必須フィールド"
        ($output -join "`n") | Should -Not -Match "Codex Launch Plan"
        (Test-Path $script:ConfigPath) | Should -BeFalse
        (Test-Path $script:StatePath) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "logs")) | Should -BeFalse
        (Test-Path (Join-Path $script:CaseRoot "recent-projects.json")) | Should -BeFalse
    }

    It "存在しない project を拒否する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        $output = & pwsh -NoProfile -File $script:StartScript -Project "MissingProject" -NonInteractive -DryRun 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        ($output -join "`n") | Should -Match "作業ディレクトリが見つかりません"
        ($output -join "`n") | Should -Match "Error Category: FILE_SYSTEM"
    }

    It "実行成功時に recent-projects を更新する" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath

        & pwsh -NoProfile -File $script:StartScript -Project "DemoProject" -NonInteractive | Out-Null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $recent = Get-Content -Path (Join-Path $script:CaseRoot "recent-projects.json") -Raw | ConvertFrom-Json
        @($recent.projects).Count | Should -Be 1
        $recent.projects[0].project | Should -Be $script:ProjectPath
        $recent.projects[0].tool | Should -Be "codex"
        $state = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        $state.execution.phase | Should -Be "Development"
        $state.execution.current_project | Should -Be "DemoProject"
        @($state.message_bus."phase.transition").Count | Should -Be 2
        $state.message_bus."phase.transition"[-1].payload.to | Should -Be "Development"
        $state.message_bus."phase.transition"[-1].payload.project | Should -Be "DemoProject"
        @(Get-ChildItem -Path (Join-Path $script:CaseRoot "logs") -Filter "test-startup-*-SUCCESS.log" -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0
    }

    It "リポジトリ外から絶対パスで起動し履歴とログを保持できる" {
        $env:AI_STARTUP_CONFIG_PATH = $script:ConfigPath
        $env:AI_STARTUP_STATE_PATH = $script:StatePath
        Push-Location $script:CaseRoot
        try {
            & pwsh -NoProfile -File $script:StartScript -Project $script:ProjectPath -NonInteractive | Out-Null
            $LASTEXITCODE | Should -Be 0
            $recent = Get-Content (Join-Path $script:CaseRoot "recent-projects.json") -Raw | ConvertFrom-Json
            $recent.projects[0].project | Should -Be $script:ProjectPath
            $logs = @(Get-ChildItem (Join-Path $script:CaseRoot "logs") -File -Filter "test-startup-DemoProject-codex-*-SUCCESS.log")
            $logs.Count | Should -Be 1
            $state = Get-Content $script:StatePath -Raw | ConvertFrom-Json
            $state.execution.current_project | Should -Be "DemoProject"
        }
        finally { Pop-Location }
    }

    AfterEach {
        Remove-Item Env:AI_STARTUP_CONFIG_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:AI_STARTUP_STATE_PATH -ErrorAction SilentlyContinue
    }
}
