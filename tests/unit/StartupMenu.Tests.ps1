BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/LauncherCommon.psm1") -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/Config.psm1")         -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/StartupMenu.psm1")    -Force

    function New-TestConfig {
        param(
            [bool]$CodexEnabled = $true,
            [bool]$RecentEnabled = $true,
            [bool]$SupervisorEnabled = $true,
            [string]$ProjectsDir = "/home/kensan/Projects"
        )
        return [pscustomobject]@{
            projectsDir        = $ProjectsDir
            registeredProjects = [pscustomobject]@{
                enabled       = $true
                roots         = @($ProjectsDir)
                include       = @()
                exclude       = @()
                categories    = [pscustomobject]@{}
                maxCandidates = 80
            }
            tools              = [pscustomobject]@{
                defaultTool = "codex"
                codex       = [pscustomobject]@{ enabled = $CodexEnabled; command = "codex" }
            }
            supervisor         = [pscustomobject]@{
                enabled                   = $SupervisorEnabled
                applyToRegisteredProjects = $true
                mode                      = "cto-autonomous"
                humanDecisionRequired     = @("final-choice", "merge", "release")
            }
            recentProjects     = [pscustomobject]@{
                enabled     = $RecentEnabled
                historyFile = "/home/kensan/.codex-startup/recent-projects.json"
            }
        }
    }
}

Describe "Get-MenuItems" {
    It "SSH セクションを生成しない" {
        $items = Get-MenuItems -Config (New-TestConfig)
        @($items | Where-Object { $_.Key -like 'S*' -or $_.Action -like '*ssh*' }).Count | Should -Be 0
    }

    It "Claude 起動項目を生成しない" {
        $items = Get-MenuItems -Config (New-TestConfig)
        @($items | Where-Object { $_.Action -like '*claude*' -or $_.Label -like '*Claude*' }).Count | Should -Be 0
    }

    It "ローカル Codex 起動項目が常に含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $l1 = $items | Where-Object { $_.Key -eq 'L1' }
        $l1 | Should -Not -BeNullOrEmpty
        $l1.Enabled | Should -BeTrue
        $l1.Action | Should -Be 'launch-local-codex'
    }

    It "登録 root が複数ある場合はローカル Codex 起動項目を root ごとに分ける" {
        $config = New-TestConfig
        $config.registeredProjects.roots = @(
            "/home/kensan/Projects/Mirai-Project",
            "/home/kensan/Projects/Mirai-DX-Project"
        )

        $items = Get-MenuItems -Config $config
        ($items | Where-Object { $_.Key -eq 'L1' }).Section | Should -Be "Linux registered projects (/home/kensan/Projects/Mirai-Project)"
        ($items | Where-Object { $_.Key -eq 'L2' }).Section | Should -Be "Linux registered projects (/home/kensan/Projects/Mirai-DX-Project)"
        ($items | Where-Object { $_.Key -eq 'L2' }).LaunchRoot | Should -Be "/home/kensan/Projects/Mirai-DX-Project"
    }

    It "Supervisor 適用項目が含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $supervisor = $items | Where-Object { $_.Action -eq 'apply-supervisor' }
        $supervisor | Should -Not -BeNullOrEmpty
        $supervisor.Enabled | Should -BeTrue
    }

    It "supervisor.enabled=false の場合 apply-supervisor が Enabled=false" {
        $items = Get-MenuItems -Config (New-TestConfig -SupervisorEnabled:$false)
        ($items | Where-Object { $_.Action -eq 'apply-supervisor' }).Enabled | Should -BeFalse
    }

    It "終了項目 (Key=0) が常に含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $exit = $items | Where-Object { $_.Key -eq '0' }
        $exit | Should -Not -BeNullOrEmpty
        $exit.Action | Should -Be 'exit'
    }

    It "全項目に Key・Label・Action プロパティが含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        foreach ($item in $items) {
            $item.Key    | Should -Not -BeNullOrEmpty
            $item.Label  | Should -Not -BeNullOrEmpty
            $item.Action | Should -Not -BeNullOrEmpty
        }
    }

    It "診断・管理セクション項目（1〜13）が全て含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        @('1','2','3','4','5','6','7','8','9','10','11','12','13') | ForEach-Object {
            $key = $_
            ($items | Where-Object { $_.Key -eq $key }) | Should -Not -BeNullOrEmpty -Because "Key=$key が見つからない"
        }
    }

    It "recentProjects.enabled=false の場合 Key=7 が Enabled=false" {
        $items = Get-MenuItems -Config (New-TestConfig -RecentEnabled:$false)
        ($items | Where-Object { $_.Key -eq '7' }).Enabled | Should -BeFalse
    }

    It "Supervisor レポート項目が含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $report = $items | Where-Object { $_.Action -eq 'supervisor-report' }
        $report | Should -Not -BeNullOrEmpty
        $report.Key | Should -Be '9'
        $report.Enabled | Should -BeTrue
    }

    It "supervisor.enabled=false の場合 supervisor-report が Enabled=false" {
        $items = Get-MenuItems -Config (New-TestConfig -SupervisorEnabled:$false)
        ($items | Where-Object { $_.Action -eq 'supervisor-report' }).Enabled | Should -BeFalse
    }

    It "プロジェクト候補管理項目が含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $manager = $items | Where-Object { $_.Action -eq 'project-candidates' }
        $manager | Should -Not -BeNullOrEmpty
        $manager.Key | Should -Be '11'
        $manager.Enabled | Should -BeTrue
    }

    It "リリース前チェック項目が含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $releaseCheck = $items | Where-Object { $_.Action -eq 'release-check' }
        $releaseCheck | Should -Not -BeNullOrEmpty
        $releaseCheck.Key | Should -Be '12'
        $releaseCheck.Enabled | Should -BeTrue
    }

    It "GitHub PR 確認項目が含まれる" {
        $items = Get-MenuItems -Config (New-TestConfig)
        $githubPr = $items | Where-Object { $_.Action -eq 'github-pr-flow' }
        $githubPr | Should -Not -BeNullOrEmpty
        $githubPr.Key | Should -Be '13'
        $githubPr.Enabled | Should -BeTrue
    }
}

Describe "Show-Menu (非インタラクティブ検証)" {
    It "Show-Menu はエラーなく実行できる" {
        { Show-Menu -Config (New-TestConfig) -ProjectRoot $script:RepoRoot } | Should -Not -Throw
    }

    It "Show-Menu はメニューアイテムのリストを返す" {
        $result = Show-Menu -Config (New-TestConfig) -ProjectRoot $script:RepoRoot
        $result | Should -Not -BeNullOrEmpty
        @($result).Count | Should -BeGreaterThan 0
    }
}

Describe "Read-MenuChoice" {
    It "有効なキーを渡すと対応するアイテムを返す" {
        $items  = Get-MenuItems -Config (New-TestConfig)
        $found  = $items | Where-Object { $_.Key -eq 'L1' }
        $found | Should -Not -BeNullOrEmpty
        $found.Action | Should -Be 'launch-local-codex'
    }

    It "無効なキーの場合は該当アイテムが見つからない" {
        $items  = Get-MenuItems -Config (New-TestConfig)
        $found  = $items | Where-Object { $_.Key -eq 'ZZZ' -and $_.Enabled }
        $found | Should -BeNullOrEmpty
    }
}

Describe "Invoke-MenuAction (exit)" {
    It "exit アクションは false を返す" {
        $exitItem = [pscustomobject]@{ Key = '0'; Label = '終了'; Action = 'exit'; Enabled = $true; Note = ''; Section = $null }
        $result   = Invoke-MenuAction -Item $exitItem -Config (New-TestConfig) -ProjectRoot $script:RepoRoot
        $result | Should -BeFalse
    }

    It "有効なアクション（show-dashboard）は true を返す" {
        $dashItem = [pscustomobject]@{ Key = '1'; Label = 'DB'; Action = 'show-dashboard'; Enabled = $true; Note = ''; Section = $null }
        $result = Invoke-MenuAction -Item $dashItem -Config (New-TestConfig) `
            -ProjectRoot $script:RepoRoot `
            -StatePath   (Join-Path $script:RepoRoot "state.json")
        $result | Should -BeTrue
    }
}

Describe "Get-LocalProjectList" {
    It "有効なディレクトリでサブフォルダ一覧を返す" {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "ProjectA") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "ProjectB") | Out-Null
        New-Item -ItemType File      -Path (Join-Path $TestDrive "readme.txt") | Out-Null

        $result = @(Get-LocalProjectList -BaseDir $TestDrive)
        $result | Should -Contain "ProjectA"
        $result | Should -Contain "ProjectB"
        $result | Should -Not -Contain "readme.txt"
    }

    It "存在しないディレクトリでは空配列を返す" {
        @(Get-LocalProjectList -BaseDir "/nonexistent/xyz/abc").Count | Should -Be 0
    }

    It "隠しディレクトリ（.dotdir）を除外する" {
        $dir = Join-Path $TestDrive "hidden_test"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir ".hidden") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir "Visible") | Out-Null

        $result = @(Get-LocalProjectList -BaseDir $dir)
        $result | Should -Not -Contain ".hidden"
        $result | Should -Contain "Visible"
    }

    It "MaxCount でリストを制限できる" {
        $dir = Join-Path $TestDrive "maxcount_test"
        New-Item -ItemType Directory -Path $dir | Out-Null
        1..10 | ForEach-Object {
            New-Item -ItemType Directory -Path (Join-Path $dir "Proj$_") | Out-Null
        }

        @(Get-LocalProjectList -BaseDir $dir -MaxCount 5).Count | Should -Be 5
    }

    It "返り値はソート済みである" {
        $dir = Join-Path $TestDrive "sort_test"
        New-Item -ItemType Directory -Path $dir | Out-Null
        @("Zebra", "Alpha", "Mango") | ForEach-Object {
            New-Item -ItemType Directory -Path (Join-Path $dir $_) | Out-Null
        }

        $result = @(Get-LocalProjectList -BaseDir $dir)
        $result[0] | Should -Be "Alpha"
        $result[1] | Should -Be "Mango"
        $result[2] | Should -Be "Zebra"
    }
}

Describe "Get-RecentProjectNames" {
    It "ヒストリファイルが存在しない場合は空配列を返す" {
        @(Get-RecentProjectNames -HistoryPath "/nonexistent/history.json").Count | Should -Be 0
    }

    It "ヒストリファイルが空文字列の場合は空配列を返す" {
        @(Get-RecentProjectNames -HistoryPath "").Count | Should -Be 0
    }
}

Describe "Recent project restart helpers" {
    BeforeEach {
        $script:RecentRoot = Join-Path $TestDrive "recent-projects-root"
        $script:RecentPath = Join-Path $TestDrive "recent-projects.json"
        New-Item -ItemType Directory -Path (Join-Path $script:RecentRoot "Alpha") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:RecentRoot "Beta") -Force | Out-Null

        $config = New-TestConfig -ProjectsDir $script:RecentRoot
        $config.recentProjects.historyFile = $script:RecentPath
        $script:RecentConfig = $config

        Update-RecentProject -ProjectName "Alpha" -Tool "codex" -Mode "local" -Result "success" -HistoryPath $script:RecentPath
        Update-RecentProject -ProjectName "Beta" -Tool "codex" -Mode "local" -Result "failure" -HistoryPath $script:RecentPath
        Update-RecentProject -ProjectName "MissingProject" -Tool "codex" -Mode "local" -Result "success" -HistoryPath $script:RecentPath
        Update-RecentProject -ProjectName "Alpha" -Tool "codex" -Mode "local" -Result "success" -HistoryPath $script:RecentPath
    }

    It "最近履歴を再起動候補へ変換し、存在有無を付与する" {
        $result = @(Get-RecentRestartCandidate -Config $script:RecentConfig -HistoryPath $script:RecentPath -Tool "codex" -Mode "local")

        @($result).Count | Should -Be 3
        $result[0].project | Should -Be "Alpha"
        $result[0].exists | Should -BeTrue
        ($result | Where-Object project -eq "MissingProject").exists | Should -BeFalse
    }

    It "登録 root が複数ある場合は各 root 配下のプロジェクトを解決する" {
        $internalRoot = Join-Path $TestDrive "mirai-internal"
        $externalRoot = Join-Path $TestDrive "mirai-external"
        New-Item -ItemType Directory -Path (Join-Path $internalRoot "Alpha") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $externalRoot "Beta") -Force | Out-Null

        $config = New-TestConfig -ProjectsDir $TestDrive
        $config.registeredProjects.roots = @($internalRoot, $externalRoot)
        $config.recentProjects.historyFile = $script:RecentPath

        $result = @(Get-RecentRestartCandidate -Config $config -HistoryPath $script:RecentPath -Tool "codex" -Mode "local")

        ($result | Where-Object project -eq "Alpha").path | Should -Be (Join-Path $internalRoot "Alpha")
        ($result | Where-Object project -eq "Alpha").exists | Should -BeTrue
        ($result | Where-Object project -eq "Beta").path | Should -Be (Join-Path $externalRoot "Beta")
        ($result | Where-Object project -eq "Beta").exists | Should -BeTrue
    }

    It "番号選択を再起動候補へ解決する" {
        $candidates = @(Get-RecentRestartCandidate -Config $script:RecentConfig -HistoryPath $script:RecentPath)
        $selected = Resolve-RecentRestartSelection -Candidates $candidates -InputText "2"

        $selected.project | Should -Be "MissingProject"
    }

    It "0 または不正入力は null を返す" {
        $candidates = @(Get-RecentRestartCandidate -Config $script:RecentConfig -HistoryPath $script:RecentPath)

        Resolve-RecentRestartSelection -Candidates $candidates -InputText "0" | Should -BeNullOrEmpty
        Resolve-RecentRestartSelection -Candidates $candidates -InputText "abc" | Should -BeNullOrEmpty
        Resolve-RecentRestartSelection -Candidates $candidates -InputText "99" | Should -BeNullOrEmpty
    }
}

Describe "Read-SupervisorProjectSelection" {
    BeforeEach {
        $script:SupervisorCandidates = @(
            [pscustomobject]@{ name = "Alpha"; path = "/tmp/Alpha" },
            [pscustomobject]@{ name = "Beta"; path = "/tmp/Beta" },
            [pscustomobject]@{ name = "Gamma"; path = "/tmp/Gamma" }
        )
    }

    It "カンマ区切り番号をプロジェクト名に変換する" {
        $result = @(Read-SupervisorProjectSelection -Candidates $script:SupervisorCandidates -InputText "1,3")
        $result | Should -Be @("Alpha", "Gamma")
    }

    It "all を指定すると全候補を返す" {
        $result = @(Read-SupervisorProjectSelection -Candidates $script:SupervisorCandidates -InputText "all")
        $result | Should -Be @("Alpha", "Beta", "Gamma")
    }

    It "0 はキャンセルとして空配列を返す" {
        @(Read-SupervisorProjectSelection -Candidates $script:SupervisorCandidates -InputText "0").Count | Should -Be 0
    }
}

Describe "Read-ProjectCandidateManagementInput" {
    BeforeEach {
        $script:ProjectCandidates = @(
            [pscustomobject]@{ name = "Alpha"; path = "/tmp/Alpha" },
            [pscustomobject]@{ name = "Beta"; path = "/tmp/Beta" },
            [pscustomobject]@{ name = "Gamma"; path = "/tmp/Gamma" }
        )
    }

    It "+番号 を除外操作として解析する" {
        $result = Read-ProjectCandidateManagementInput -Candidates $script:ProjectCandidates -InputText "+1,3"
        $result.operation | Should -Be "exclude"
        $result.projectNames | Should -Be @("Alpha", "Gamma")
    }

    It "-番号 を復帰操作として解析する" {
        $result = Read-ProjectCandidateManagementInput -Candidates $script:ProjectCandidates -InputText "-2"
        $result.operation | Should -Be "restore"
        $result.projectNames | Should -Be @("Beta")
    }

    It "c番号:カテゴリ をカテゴリ操作として解析する" {
        $result = Read-ProjectCandidateManagementInput -Candidates $script:ProjectCandidates -InputText "c1,2:startup-tools"
        $result.operation | Should -Be "category"
        $result.projectNames | Should -Be @("Alpha", "Beta")
        $result.category | Should -Be "startup-tools"
    }

    It "0 は none を返す" {
        $result = Read-ProjectCandidateManagementInput -Candidates $script:ProjectCandidates -InputText "0"
        $result.operation | Should -Be "none"
    }
}
