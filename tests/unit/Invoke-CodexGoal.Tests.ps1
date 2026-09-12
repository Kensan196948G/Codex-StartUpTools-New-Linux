Describe "Invoke-CodexGoal.ps1 (validate: RPC を呼ばない経路)" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:CliPath = Join-Path $repoRoot "scripts/main/Invoke-CodexGoal.ps1"

        function Invoke-GoalCli {
            param([string[]]$Arguments)

            $output = & pwsh -NoProfile -File $script:CliPath @Arguments 2>&1
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = ($output -join "`n")
            }
        }
    }

    It "上限内の objective は exit 0 で OK を返す" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Objective", "CI を緑にして PR を作成する")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "OK objective length="
    }

    It "4,000 字ちょうどは exit 0" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Objective", ("a" * 4000))
        $r.ExitCode | Should -Be 0
    }

    It "4,001 字は exit 2 (objective-too-long)" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Objective", ("a" * 4001))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match "objective-too-long"
    }

    It "空の objective は exit 2 (objective-empty)" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Objective", "")
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match "objective-empty"
    }

    It "テンプレートから /goal ブロックを抽出して検証する" {
        $template = Join-Path $TestDrive "goal.md"
        @('# Goal', '/goal "', '■ Goal', 'テストを通す。', '"') | Set-Content -LiteralPath $template -Encoding UTF8

        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Template", $template)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "OK objective length="
    }

    It "存在しないテンプレートは exit 1" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate", "-Template", (Join-Path $TestDrive "missing.md"))
        $r.ExitCode | Should -Be 1
    }

    It "Objective も Template も無ければ exit 1" {
        $r = Invoke-GoalCli -Arguments @("-Action", "validate")
        $r.ExitCode | Should -Be 1
    }

    It "-DryRun の start は RPC を呼ばず exit 0" {
        $r = Invoke-GoalCli -Arguments @("-Action", "start", "-Objective", "dry run objective", "-DryRun")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "\[dry-run\] start goal"
    }

    It "-DryRun の clear は RPC を呼ばず exit 0" {
        $r = Invoke-GoalCli -Arguments @("-Action", "clear", "-ThreadId", "t1", "-DryRun")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "\[dry-run\] clear goal"
    }

    It "get は ThreadId 必須 (無ければ exit 1)" {
        $r = Invoke-GoalCli -Arguments @("-Action", "get")
        $r.ExitCode | Should -Be 1
    }
}
