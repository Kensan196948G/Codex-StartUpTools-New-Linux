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
