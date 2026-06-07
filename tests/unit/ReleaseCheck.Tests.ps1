BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/Config.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/ArchitectureCheck.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/ReleaseCheck.psm1") -Force
}

Describe "New-ReleaseCheckResult" {
    It "結果オブジェクトを返す" {
        $result = New-ReleaseCheckResult -Name "Demo" -Ok $true -Detail "ok" -Category "test"

        $result.Name | Should -Be "Demo"
        $result.Ok | Should -BeTrue
        $result.Detail | Should -Be "ok"
        $result.Category | Should -Be "test"
    }
}

Describe "Test-ReleaseIgnoredPath" {
    It "必須runtimeパスが .gitignore にあれば pass" {
        "config/config.json`nstate.json`nlogs/" | Set-Content -Path (Join-Path $TestDrive ".gitignore") -Encoding UTF8

        $result = Test-ReleaseIgnoredPath -ProjectRoot $TestDrive

        $result.Ok | Should -BeTrue
    }

    It "必須runtimeパスが不足していれば fail" {
        "state.json" | Set-Content -Path (Join-Path $TestDrive ".gitignore") -Encoding UTF8

        $result = Test-ReleaseIgnoredPath -ProjectRoot $TestDrive

        $result.Ok | Should -BeFalse
        $result.Detail | Should -Match "config/config.json"
        $result.Detail | Should -Match "logs/"
    }
}

Describe "Test-ReleaseReadmeRequirement" {
    It "README に必須語があれば pass" {
        "Supervisorレポート 更新差分表示 プロジェクト候補管理 リリース" | Set-Content -Path (Join-Path $TestDrive "README.md") -Encoding UTF8

        $result = Test-ReleaseReadmeRequirement -ProjectRoot $TestDrive

        $result.Ok | Should -BeTrue
    }

    It "README に必須語が不足していれば fail" {
        "Supervisorレポート" | Set-Content -Path (Join-Path $TestDrive "README.md") -Encoding UTF8

        $result = Test-ReleaseReadmeRequirement -ProjectRoot $TestDrive

        $result.Ok | Should -BeFalse
        $result.Detail | Should -Match "更新差分表示"
    }
}

Describe "Test-ReleaseConfigTemplate" {
    It "Linux既定の config template を pass とする" {
        $configDir = Join-Path $TestDrive "config"
        New-Item -ItemType Directory -Path $configDir | Out-Null
        Copy-Item -Path (Join-Path $script:RepoRoot "config/config.json.template") -Destination (Join-Path $configDir "config.json.template")

        $result = Test-ReleaseConfigTemplate -ProjectRoot $TestDrive

        $result.Ok | Should -BeTrue
        $result.Detail | Should -Match "/home/kensan/Projects"
    }
}

Describe "Test-ReleaseGitState" {
    It "clean worktree は pass" {
        $repo = Join-Path $TestDrive "clean-repo"
        New-Item -ItemType Directory -Path $repo | Out-Null
        git -C $repo init -q | Out-Null
        "demo" | Set-Content -Path (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add README.md | Out-Null
        git -C $repo -c user.email=test@example.com -c user.name=Test commit -m init | Out-Null

        $result = Test-ReleaseGitState -ProjectRoot $repo

        $result.Ok | Should -BeTrue
    }

    It "dirty worktree は通常 fail だが AllowDirty なら pass" {
        $repo = Join-Path $TestDrive "dirty-repo"
        New-Item -ItemType Directory -Path $repo | Out-Null
        git -C $repo init -q | Out-Null
        "demo" | Set-Content -Path (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add README.md | Out-Null
        git -C $repo -c user.email=test@example.com -c user.name=Test commit -m init | Out-Null
        "dirty" | Set-Content -Path (Join-Path $repo "dirty.txt") -Encoding UTF8

        (Test-ReleaseGitState -ProjectRoot $repo).Ok | Should -BeFalse
        (Test-ReleaseGitState -ProjectRoot $repo -AllowDirty).Ok | Should -BeTrue
    }
}

Describe "Invoke-ReleaseCheck" {
    It "軽量チェックの集約結果を返す" {
        "config/config.json`nstate.json`nlogs/" | Set-Content -Path (Join-Path $TestDrive ".gitignore") -Encoding UTF8
        "Supervisorレポート 更新差分表示 プロジェクト候補管理 リリース" | Set-Content -Path (Join-Path $TestDrive "README.md") -Encoding UTF8
        $configDir = Join-Path $TestDrive "config"
        New-Item -ItemType Directory -Path $configDir | Out-Null
        Copy-Item -Path (Join-Path $script:RepoRoot "config/config.json.template") -Destination (Join-Path $configDir "config.json.template")
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "scripts") | Out-Null

        git -C $TestDrive init -q | Out-Null
        git -C $TestDrive add . | Out-Null
        git -C $TestDrive -c user.email=test@example.com -c user.name=Test commit -m init | Out-Null

        $report = Invoke-ReleaseCheck -ProjectRoot $TestDrive -SkipPester -SkipDryRun

        $report.passed | Should -BeTrue
        $report.total | Should -Be 5
        $report.failed | Should -Be 0
    }
}
