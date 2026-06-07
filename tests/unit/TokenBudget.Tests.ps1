BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/TokenBudget.psm1") -Force
}

Describe "New-TokenState" {
    It "creates a default budget state" {
        $state = New-TokenState
        $state.total_budget | Should -Be 100
        $state.used | Should -Be 0
        $state.remaining | Should -Be 100
        $state.dynamic_mode | Should -BeTrue
    }

    It "includes the default phase allocation" {
        $state = New-TokenState
        $state.allocation.monitor | Should -Be 10
        $state.allocation.development | Should -Be 35
        $state.allocation.verify | Should -Be 25
        $state.allocation.improvement | Should -Be 10
        $state.allocation.debug | Should -Be 20
    }
}

Describe "Get-TokenZone" {
    It "maps 0 to Green" {
        (Get-TokenZone -UsedPercent 0).Label | Should -Be "Green"
    }

    It "maps 60 to Yellow" {
        (Get-TokenZone -UsedPercent 60).Label | Should -Be "Yellow"
    }

    It "maps 75 to Orange" {
        (Get-TokenZone -UsedPercent 75).Label | Should -Be "Orange"
    }

    It "maps 90 to Red" {
        (Get-TokenZone -UsedPercent 90).Label | Should -Be "Red"
    }
}

Describe "Get-PhaseAllowance" {
    It "allows all phases in Green" {
        $allowance = Get-PhaseAllowance -Zone (Get-TokenZone -UsedPercent 30)
        $allowance.monitor | Should -BeTrue
        $allowance.development | Should -BeTrue
        $allowance.verify | Should -BeTrue
        $allowance.improvement | Should -BeTrue
        $allowance.debug | Should -BeTrue
    }

    It "blocks improvement in Yellow" {
        $allowance = Get-PhaseAllowance -Zone (Get-TokenZone -UsedPercent 65)
        $allowance.improvement | Should -BeFalse
        $allowance.development | Should -BeTrue
    }

    It "blocks development and improvement in Orange" {
        $allowance = Get-PhaseAllowance -Zone (Get-TokenZone -UsedPercent 80)
        $allowance.development | Should -BeFalse
        $allowance.improvement | Should -BeFalse
        $allowance.verify | Should -BeTrue
    }

    It "keeps only monitor and verify in Red" {
        $allowance = Get-PhaseAllowance -Zone (Get-TokenZone -UsedPercent 95)
        $allowance.monitor | Should -BeTrue
        $allowance.verify | Should -BeTrue
        $allowance.development | Should -BeFalse
        $allowance.improvement | Should -BeFalse
        $allowance.debug | Should -BeFalse
    }
}

Describe "State handling" {
    It "returns a default state when no file exists" {
        $state = Get-TokenState -StatePath (Join-Path $TestDrive "missing.json")
        $state.total_budget | Should -Be 100
        $state.used | Should -Be 0
    }

    It "reads token state from a JSON file" {
        $statePath = Join-Path $TestDrive "read.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 45
                remaining = 55
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 35
                current_phase_used = 12
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $state = Get-TokenState -StatePath $statePath
        $state.used | Should -Be 45
        $state.remaining | Should -Be 55
    }
}

Describe "Update-TokenUsage" {
    It "increments usage and remaining budget" {
        $statePath = Join-Path $TestDrive "update.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 30
                remaining = 70
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 35
                current_phase_used = 5
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $result = Update-TokenUsage -Phase development -Amount 10 -StatePath $statePath
        $result.used | Should -Be 40
        $result.remaining | Should -Be 60
    }

    It "caps usage at 100" {
        $statePath = Join-Path $TestDrive "cap.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 95
                remaining = 5
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $result = Update-TokenUsage -Phase verify -Amount 20 -StatePath $statePath
        $result.used | Should -Be 100
        $result.remaining | Should -Be 0
    }

    It "creates token state when the JSON file is empty" {
        $statePath = Join-Path $TestDrive "empty.json"
        Set-Content -Path $statePath -Value "{}" -Encoding UTF8

        $result = Update-TokenUsage -Phase monitor -Amount 5 -StatePath $statePath
        $result.used | Should -Be 5
        $result.remaining | Should -Be 95
        $result.current_phase | Should -Be "monitor"
    }
}

Describe "Get-TokenBudgetStatus" {
    It "returns expected status for the Green zone" {
        $statePath = Join-Path $TestDrive "status-green.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 25
                remaining = 75
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $status = Get-TokenBudgetStatus -StatePath $statePath
        $status.UsedPercent | Should -Be 25
        $status.Zone.Label | Should -Be "Green"
        $status.ShouldStop | Should -BeFalse
        $status.ShouldSkipImprovement | Should -BeFalse
        $status.ShouldVerifyOnly | Should -BeFalse
    }

    It "flags stop conditions in the Red zone" {
        $statePath = Join-Path $TestDrive "status-red.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 95
                remaining = 5
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $status = Get-TokenBudgetStatus -StatePath $statePath
        $status.Zone.Label | Should -Be "Red"
        $status.ShouldStop | Should -BeTrue
        $status.ShouldVerifyOnly | Should -BeTrue
    }
}

Describe "Invoke-DynamicReallocation" {
    It "shifts budget toward verify on ci_failure" {
        $statePath = Join-Path $TestDrive "realloc-ci.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 40
                remaining = 60
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $allocation = Invoke-DynamicReallocation -Condition ci_failure -StatePath $statePath
        $allocation.verify | Should -Be 45
        $allocation.development | Should -Be 15
    }

    It "shifts budget toward improvement when stable" {
        $statePath = Join-Path $TestDrive "realloc-stable.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 40
                remaining = 60
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $allocation = Invoke-DynamicReallocation -Condition stable -StatePath $statePath
        $allocation.improvement | Should -Be 20
        $allocation.development | Should -Be 25
    }

    It "removes improvement under time pressure" {
        $statePath = Join-Path $TestDrive "realloc-time.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 80
                remaining = 20
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $true
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $allocation = Invoke-DynamicReallocation -Condition time_pressure -StatePath $statePath
        $allocation.improvement | Should -Be 0
        $allocation.verify | Should -Be 15
        $allocation.development | Should -Be 45
    }

    It "returns null when dynamic mode is disabled" {
        $statePath = Join-Path $TestDrive "realloc-disabled.json"
        $payload = @{
            token = @{
                total_budget = 100
                used = 40
                remaining = 60
                allocation = @{ monitor = 10; development = 35; verify = 25; improvement = 10; debug = 20 }
                dynamic_mode = $false
                current_phase_budget = 0
                current_phase_used = 0
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $statePath -Value $payload -Encoding UTF8

        $result = Invoke-DynamicReallocation -Condition stable -StatePath $statePath
        $result | Should -BeNullOrEmpty
    }
}
