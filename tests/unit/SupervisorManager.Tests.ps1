BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/SupervisorManager.psm1") -Force

    function New-TestSupervisorConfig {
        param([string]$Root)
        [pscustomobject]@{
            projectsDir        = $Root
            registeredProjects = [pscustomobject]@{
                enabled       = $true
                roots         = @($Root)
                include       = @()
                exclude       = @("SkipMe")
                maxCandidates = 10
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

Describe "Get-RegisteredProjectCandidate" {
    It "登録 root 直下の候補を返し exclude を除外する" {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Alpha") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "SkipMe") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive ".hidden") | Out-Null

        $result = @(Get-RegisteredProjectCandidate -Config (New-TestSupervisorConfig -Root $TestDrive))
        $result.name | Should -Contain "Alpha"
        $result.name | Should -Not -Contain "SkipMe"
        $result.name | Should -Not -Contain ".hidden"
    }
}

Describe "Set-SupervisorForProject" {
    It "PreviewOnly ではファイルを書き込まない" {
        $project = Join-Path $TestDrive "PreviewProject"
        New-Item -ItemType Directory -Path $project | Out-Null

        $result = Set-SupervisorForProject -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive) -PreviewOnly
        $result.applied | Should -BeFalse
        Test-Path $result.target | Should -BeFalse
    }

    It ".codex/supervisor.json を作成する" {
        $project = Join-Path $TestDrive "ManagedProject"
        New-Item -ItemType Directory -Path $project | Out-Null

        $result = Set-SupervisorForProject -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive)
        $result.applied | Should -BeTrue
        Test-Path $result.target | Should -BeTrue

        $manifest = Get-Content $result.target -Raw | ConvertFrom-Json
        $manifest.project | Should -Be "ManagedProject"
        $manifest.managedBy | Should -Be "Codex-StartUpTools-New-Linux"
        $manifest.codexOnly | Should -BeTrue
        $manifest.sshEnabled | Should -BeFalse
        $manifest.humanDecisionRequired | Should -Contain "merge"
    }

    It "PreviewOnly で既存 manifest との差分を返す" {
        $project = Join-Path $TestDrive "ForeignProject"
        $codexDir = Join-Path $project ".codex"
        New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        @{
            managedBy   = "OtherTool"
            mode        = "external"
            codexOnly   = $false
            sshEnabled  = $true
        } | ConvertTo-Json | Set-Content -Path (Join-Path $codexDir "supervisor.json") -Encoding UTF8

        $result = Set-SupervisorForProject -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive) -PreviewOnly

        $result.applied | Should -BeFalse
        $result.action | Should -Be "Update"
        $result.changeCount | Should -BeGreaterThan 0
        ($result.changes | Where-Object property -eq "managedBy").desired | Should -Be "Codex-StartUpTools-New-Linux"
        ($result.changes | Where-Object property -eq "sshEnabled").desired | Should -Be "false"
    }
}

Describe "Set-SupervisorForRegisteredProjects" {
    It "ProjectNames 指定時は選択した候補だけに適用する" {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Alpha") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Beta") | Out-Null

        $results = @(Set-SupervisorForRegisteredProjects -Config (New-TestSupervisorConfig -Root $TestDrive) -ProjectNames @("Beta"))

        $results.project | Should -Contain "Beta"
        $results.project | Should -Not -Contain "Alpha"
        Test-Path (Join-Path $TestDrive "Beta/.codex/supervisor.json") | Should -BeTrue
        Test-Path (Join-Path $TestDrive "Alpha/.codex/supervisor.json") | Should -BeFalse
    }
}

Describe "Get-SupervisorReport" {
    It "Managed / Missing / Foreign / Invalid を集計する" {
        foreach ($name in @("ManagedProject", "MissingProject", "ForeignProject", "InvalidProject")) {
            New-Item -ItemType Directory -Path (Join-Path $TestDrive $name) -Force | Out-Null
        }

        Set-SupervisorForProject -ProjectPath (Join-Path $TestDrive "ManagedProject") -Config (New-TestSupervisorConfig -Root $TestDrive) | Out-Null

        $foreignDir = Join-Path $TestDrive "ForeignProject/.codex"
        New-Item -ItemType Directory -Path $foreignDir -Force | Out-Null
        @{
            managedBy   = "OtherTool"
            mode        = "external"
            codexOnly   = $false
            sshEnabled  = $true
        } | ConvertTo-Json | Set-Content -Path (Join-Path $foreignDir "supervisor.json") -Encoding UTF8

        $invalidDir = Join-Path $TestDrive "InvalidProject/.codex"
        New-Item -ItemType Directory -Path $invalidDir -Force | Out-Null
        "{ invalid json" | Set-Content -Path (Join-Path $invalidDir "supervisor.json") -Encoding UTF8

        $report = Get-SupervisorReport -Config (New-TestSupervisorConfig -Root $TestDrive)

        $report.total | Should -Be 4
        $report.managed | Should -Be 1
        $report.missing | Should -Be 1
        $report.foreign | Should -Be 1
        $report.invalid | Should -Be 1
        ($report.entries | Where-Object project -eq "ManagedProject").status | Should -Be "Managed"
        ($report.entries | Where-Object project -eq "MissingProject").status | Should -Be "Missing"
        ($report.entries | Where-Object project -eq "ForeignProject").status | Should -Be "Foreign"
        ($report.entries | Where-Object project -eq "InvalidProject").status | Should -Be "Invalid"
    }
}

Describe "Get-SupervisorManifestDiff" {
    It "未適用プロジェクトは Create として返す" {
        $project = Join-Path $TestDrive "NewProject"
        New-Item -ItemType Directory -Path $project -Force | Out-Null

        $diff = Get-SupervisorManifestDiff -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive)

        $diff.action | Should -Be "Create"
        $diff.exists | Should -BeFalse
        $diff.changeCount | Should -Be 0
    }

    It "同一ポリシーの managed manifest は timestamp refresh として返す" {
        $project = Join-Path $TestDrive "ManagedProject"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-SupervisorForProject -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive) | Out-Null

        $diff = Get-SupervisorManifestDiff -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive)

        $diff.action | Should -Be "RefreshTimestamp"
        $diff.changeCount | Should -Be 0
        $diff.timestampWillRefresh | Should -BeTrue
    }

    It "外部管理 manifest は変更差分を返す" {
        $project = Join-Path $TestDrive "ForeignProject"
        $codexDir = Join-Path $project ".codex"
        New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        @{
            managedBy   = "OtherTool"
            mode        = "external"
            codexOnly   = $false
            sshEnabled  = $true
        } | ConvertTo-Json | Set-Content -Path (Join-Path $codexDir "supervisor.json") -Encoding UTF8

        $diff = Get-SupervisorManifestDiff -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive)

        $diff.action | Should -Be "Update"
        ($diff.changes | Where-Object property -eq "managedBy").current | Should -Be "OtherTool"
        ($diff.changes | Where-Object property -eq "managedBy").desired | Should -Be "Codex-StartUpTools-New-Linux"
        ($diff.changes | Where-Object property -eq "codexOnly").current | Should -Be "false"
        ($diff.changes | Where-Object property -eq "codexOnly").desired | Should -Be "true"
    }

    It "不正JSONは ReplaceInvalid として返す" {
        $project = Join-Path $TestDrive "InvalidProject"
        $codexDir = Join-Path $project ".codex"
        New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        "{ invalid json" | Set-Content -Path (Join-Path $codexDir "supervisor.json") -Encoding UTF8

        $diff = Get-SupervisorManifestDiff -ProjectPath $project -Config (New-TestSupervisorConfig -Root $TestDrive)

        $diff.action | Should -Be "ReplaceInvalid"
        $diff.parseError | Should -Not -BeNullOrEmpty
        $diff.changeCount | Should -Be 0
    }
}
