BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/lib/Config.psm1" -Force

    function New-CodexOnlyConfig {
        @{
            version            = "1.0.0"
            projectsDir        = "/home/kensan/Projects"
            registeredProjects = @{
                enabled       = $true
                roots         = @("/home/kensan/Projects")
                include       = @()
                exclude       = @()
                maxCandidates = 80
            }
            tools              = @{
                defaultTool = "codex"
                codex       = @{
                    enabled        = $true
                    command        = "codex"
                    args           = @("--full-auto")
                    installCommand = "install-codex"
                    env            = @{ OPENAI_API_KEY = "" }
                    apiKeyEnvVar   = "OPENAI_API_KEY"
                }
            }
            supervisor         = @{
                enabled                   = $true
                applyToRegisteredProjects = $true
                mode                      = "cto-autonomous"
                humanDecisionRequired     = @("final-choice", "merge", "release")
            }
        }
    }
}

Describe "Import-StartupConfig" {
    Context "有効な config.json を読み込む場合" {
        BeforeAll {
            $script:TempDir = Join-Path $TestDrive "config"
            New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
            $script:ValidConfigPath = Join-Path $script:TempDir "config.json"
            New-CodexOnlyConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ValidConfigPath -Encoding UTF8
        }

        It "読み込んだオブジェクトが null でないこと" {
            Import-StartupConfig -ConfigPath $script:ValidConfigPath | Should -Not -BeNullOrEmpty
        }

        It "projectsDir が正しく読み込まれること" {
            (Import-StartupConfig -ConfigPath $script:ValidConfigPath).projectsDir | Should -Be "/home/kensan/Projects"
        }

        It "tools.defaultTool が codex であること" {
            (Import-StartupConfig -ConfigPath $script:ValidConfigPath).tools.defaultTool | Should -Be "codex"
        }
    }

    Context "ファイルが存在しない場合" {
        It "例外をスローすること" {
            { Import-StartupConfig -ConfigPath "/nonexistent/config.json" } | Should -Throw
        }
    }
}

Describe "Backup-ConfigFile" {
    It "バックアップファイルが作成されること" {
        $tempDir = Join-Path $TestDrive "backup-test"
        $sourcePath = Join-Path $tempDir "config.json"
        $backupDir = Join-Path $tempDir "backups"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        New-CodexOnlyConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $sourcePath -Encoding UTF8

        Backup-ConfigFile -ConfigPath $sourcePath -BackupDir $backupDir
        @(Get-ChildItem $backupDir -Filter "*.json").Count | Should -BeGreaterThan 0
    }
}

Describe "Schema orchestration" {
    It "Test-StartupConfigSchema が template 相当の設定を受け入れること" {
        Test-StartupConfigSchema -Config (New-CodexOnlyConfig) | Should -BeNullOrEmpty
    }

    It "Assert-StartupConfigSchema が有効ファイルを通すこと" {
        $configPath = Join-Path $TestDrive "template-config.json"
        New-CodexOnlyConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8

        { Assert-StartupConfigSchema -ConfigPath $configPath } | Should -Not -Throw
    }

    It "Get-RecentProject が空配列を返すこと" {
        Get-RecentProject -HistoryPath (Join-Path $TestDrive "missing-recent.json") | Should -BeNullOrEmpty
    }

    It "Update-RecentProject が履歴を保存すること" {
        $historyPath = Join-Path $TestDrive "recent.json"
        Update-RecentProject -ProjectName "TestProject" -Tool "codex" -Mode "local" -Result "success" -ElapsedMs 42 -HistoryPath $historyPath
        $result = Get-RecentProject -HistoryPath $historyPath
        $result[0].project | Should -Be "TestProject"
        $result[0].tool | Should -Be "codex"
        $result[0].mode | Should -Be "local"
        $result[0].result | Should -Be "success"
        $result[0].elapsedMs | Should -Be 42
    }
}
