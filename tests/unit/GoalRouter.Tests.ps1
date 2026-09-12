$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ModulePath = Join-Path $script:RepoRoot "scripts/lib/GoalRouter.psm1"
$script:ClientPath = Join-Path $script:RepoRoot "scripts/lib/CodexGoalClient.psm1"
Import-Module $script:ModulePath -Force

InModuleScope GoalRouter {
    Describe "分類ヘルパ" {
        It "Primary 5 分類を認識する" {
            foreach ($g in @("development", "mvp-release", "assessment", "deep-debug", "product-assurance")) {
                Test-GoalRouterIsPrimary -Goal $g | Should -BeTrue -Because "$g は Primary"
            }
        }

        It "Specialized 6 分類を認識する" {
            foreach ($g in @("production-release", "hotfix", "security-emergency", "refactoring", "safe-auto-merge", "pr-babysit")) {
                Test-GoalRouterIsSpecialized -Goal $g | Should -BeTrue -Because "$g は Specialized"
            }
        }

        It "未知の Goal はどちらでもない" {
            Test-GoalRouterIsPrimary -Goal "bogus" | Should -BeFalse
            Test-GoalRouterIsSpecialized -Goal "bogus" | Should -BeFalse
            Test-GoalRouterIsGoal -Goal "bogus" | Should -BeFalse
        }

        It "Specialized から既定 Primary を引ける" {
            Get-GoalRouterPrimaryFor -Specialized "hotfix" | Should -Be "deep-debug"
            Get-GoalRouterPrimaryFor -Specialized "refactoring" | Should -Be "development"
            Get-GoalRouterPrimaryFor -Specialized "production-release" | Should -Be "product-assurance"
            Get-GoalRouterPrimaryFor -Specialized "bogus" | Should -Be ""
        }

        It "Primary 配下で許可される Specialized だけ通す" {
            Test-GoalRouterAllows -Primary "deep-debug" -Specialized "hotfix" | Should -BeTrue
            Test-GoalRouterAllows -Primary "development" -Specialized "refactoring" | Should -BeTrue
            Test-GoalRouterAllows -Primary "development" -Specialized "production-release" | Should -BeFalse
            Test-GoalRouterAllows -Primary "mvp-release" -Specialized "" | Should -BeTrue
        }

        It "日本語ラベルを返す" {
            Get-GoalRouterLabelJa -Goal "deep-debug" | Should -Be "詳細デバッグ"
            Get-GoalRouterLabelJa -Goal "bogus" | Should -Be ""
        }

        It "旧 goal_type を primary/specialized へ写像する" {
            (ConvertFrom-GoalRouterLegacyGoalType -GoalType "development").Trim() | Should -Be "development"
            (ConvertFrom-GoalRouterLegacyGoalType -GoalType "hotfix").Trim() | Should -Be "deep-debug hotfix"
        }
    }

    Describe "Get-GoalRouterIntentClass" {
        It "空の意図は分類しない" {
            Get-GoalRouterIntentClass -Intent "" | Should -Be ""
            Get-GoalRouterIntentClass -Intent "よくわからない" | Should -Be ""
        }

        It "「直して」は deep-debug" {
            Get-GoalRouterIntentClass -Intent "CI が落ちているので直して" | Should -Be "deep-debug"
        }

        It "「MVP」は mvp-release" {
            Get-GoalRouterIntentClass -Intent "MVP を作りたい" | Should -Be "mvp-release"
        }

        It "「評価」は assessment" {
            Get-GoalRouterIntentClass -Intent "設計を評価してほしい" | Should -Be "assessment"
        }

        It "セキュリティ + デバッグは deep-debug security-emergency" {
            Get-GoalRouterIntentClass -Intent "脆弱性を修正して" | Should -Be "deep-debug security-emergency"
        }

        It "セキュリティ単独は assessment security-emergency" {
            Get-GoalRouterIntentClass -Intent "CVE の一覧を出して" | Should -Be "assessment security-emergency"
        }

        It "セキュリティ + 評価語は deep-debug security-emergency が優先される" {
            # 参照実装の優先順位: sec && (dbg || hot || asm) は deep-debug 側へ寄る
            Get-GoalRouterIntentClass -Intent "CVE の影響を評価したい" | Should -Be "deep-debug security-emergency"
        }

        It "緊急修正は hotfix を伴う" {
            Get-GoalRouterIntentClass -Intent "本番障害のhotfixを当てたい" | Should -Be "deep-debug hotfix"
        }

        It "自動マージは safe-auto-merge" {
            Get-GoalRouterIntentClass -Intent "PRを自動マージして" | Should -Be "product-assurance safe-auto-merge"
        }

        It "PR見守りは pr-babysit" {
            Get-GoalRouterIntentClass -Intent "PRをbabysitして" | Should -Be "product-assurance pr-babysit"
        }

        It "リファクタは refactoring を伴う" {
            Get-GoalRouterIntentClass -Intent "技術的負債をリファクタして" | Should -Be "development refactoring"
        }
    }

    Describe "Invoke-GoalRouterRoute — auto routing" {
        It "Evidence が乏しければ mvp-release (0.55)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "0" }
            $r.Primary | Should -Be "mvp-release"
            $r.Confidence | Should -Be "0.55"
            $r.Fallback | Should -BeFalse
        }

        It "Security Critical は deep-debug/security-emergency (0.95)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; security_critical = "2"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "deep-debug"
            $r.Specialized | Should -Be "security-emergency"
            $r.Confidence | Should -Be "0.95"
        }

        It "CI failure は deep-debug (0.85)、本番運用中は hotfix を伴う" {
            $a = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; ci = "failure"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $a.Primary | Should -Be "deep-debug"
            $a.Specialized | Should -Be ""

            $b = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; ci = "failure"; phase_mode = "released"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $b.Specialized | Should -Be "hotfix"
        }

        It "ci_success_rate < 0.5 は CI failure 相当" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; ci = "unknown"; ci_success_rate = "0.25"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "deep-debug"
        }

        It "runtime health down は CI 失敗より優先される (0.90)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; ci = "failure"; runtime_health = "down"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "deep-debug"
            $r.Confidence | Should -Be "0.90"
            $r.Reason | Should -Match "runtime-incident"
        }

        It "deploy.ready=true は product-assurance/production-release (0.80)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; deploy_ready = "true"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "product-assurance"
            $r.Specialized | Should -Be "production-release"
        }

        It "stable_achieved + development は product-assurance (0.70)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; stable_achieved = "true"; phase_mode = "development"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "product-assurance"
        }

        It "maintenance は development (0.70)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; phase_mode = "maintenance"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "development"
        }

        It "旧 goal_type は 0.60 で写像される" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; legacy_goal_type = "hotfix"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "deep-debug"
            $r.Specialized | Should -Be "hotfix"
            $r.Confidence | Should -Be "0.60"
        }

        It "既存 Project の既定は development (0.50)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "development"
            $r.Confidence | Should -Be "0.50"
        }

        It "runtime_errors が閾値以上なら deep-debug" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; runtime_errors = "9"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "deep-debug"
            $r.Confidence | Should -Be "0.75"
        }

        It "intent は状態より優先される (0.80)" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; intent = "MVPを作りたい"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            $r.Primary | Should -Be "mvp-release"
            $r.Confidence | Should -Be "0.80"
        }
    }

    Describe "Invoke-GoalRouterRoute — explicit" {
        It "Primary 明示は confidence 1.00" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1" } -Explicit "development"
            $r.Primary | Should -Be "development"
            $r.Confidence | Should -Be "1.00"
        }

        It "Specialized 明示は Primary を補完する" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1" } -Explicit "hotfix"
            $r.Primary | Should -Be "deep-debug"
            $r.Specialized | Should -Be "hotfix"
            $r.Effective | Should -Be "hotfix"
        }

        It "未知の明示は fail-safe で auto へ降格する" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; has_ci = "1"; has_tests = "1"; git_commits = "50" } -Explicit "bogus"
            $r.Primary | Should -Be "development"
            $r.Confidence | Should -Be "0.50"
            $r.EvidenceUsed | Should -Contain "explicit_unknown:bogus"
        }

        It "Security Critical は明示指定を上書きする" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; security_critical = "1" } -Explicit "assessment"
            $r.Specialized | Should -Be "security-emergency"
            $r.Reason | Should -Match "security-critical-override"
        }

        It "--goal auto は manual lock を解除する" {
            $ev = @{
                state_present = "1"; prev_mode = "manual"; prev_primary_goal = "assessment"
                prev_locked_by_user = "true"; prev_session_locked = "true"
                has_ci = "1"; has_tests = "1"; git_commits = "50"
            }
            $r = Invoke-GoalRouterRoute -Evidence $ev -Explicit "auto"
            $r.Mode | Should -Be "auto"
            $r.LockedByUser | Should -BeFalse
            $r.Transition | Should -Be "unlocked"
        }
    }

    Describe "Invoke-GoalRouterRoute — session lock と reroute" {
        BeforeEach {
            $script:locked = @{
                state_present           = "1"
                has_ci                  = "1"
                has_tests               = "1"
                git_commits             = "50"
                prev_primary_goal       = "assessment"
                prev_specialized_goal   = "null"
                prev_session_locked     = "true"
                prev_locked_by_user     = "false"
                prev_last_routed_at     = [datetimeoffset]::UtcNow.AddMinutes(-10).ToString("o")
                prev_snap_security_critical = "0"
                prev_snap_ci            = "success"
                prev_snap_phase_mode    = ""
                prev_snap_deploy_ready  = ""
                prev_snap_runtime_health = "ok"
            }
        }

        It "lock 期間内は前回の Goal を維持する (kept)" {
            $r = Invoke-GoalRouterRoute -Evidence $script:locked
            $r.Primary | Should -Be "assessment"
            $r.Transition | Should -Be "kept"
            ($r.EvidenceUsed -join ",") | Should -Match "session_lock:"
        }

        It "Security Critical の新規発生は reroute する" {
            $ev = $script:locked.Clone(); $ev["security_critical"] = "1"
            (Invoke-GoalRouterRoute -Evidence $ev).Transition | Should -Be "reroute"
        }

        It "CI failure の新規発生は reroute する" {
            $ev = $script:locked.Clone(); $ev["ci"] = "failure"
            (Invoke-GoalRouterRoute -Evidence $ev).Transition | Should -Be "reroute"
        }

        It "ユーザー新指示 (intent) は reroute する" {
            $ev = $script:locked.Clone(); $ev["intent"] = "MVPを作りたい"
            $r = Invoke-GoalRouterRoute -Evidence $ev
            $r.Transition | Should -Be "reroute"
            $r.Primary | Should -Be "mvp-release"
        }

        It "trigger=user は lock を無視する" {
            (Invoke-GoalRouterRoute -Evidence $script:locked -Trigger "user").Transition | Should -Be "reroute"
        }

        It "Trigger=goal-reached は reroute する" {
            (Invoke-GoalRouterRoute -Evidence $script:locked -Trigger "goal-reached").Transition | Should -Be "reroute"
        }

        It "ForceReroute は lock を無視して再判定する" {
            # lock を無視するので前回の assessment は維持されず、Evidence から再判定される
            $r = Invoke-GoalRouterRoute -Evidence $script:locked -ForceReroute $true
            $r.Primary | Should -Be "development"
            $r.Transition | Should -Be "routed"
        }

        It "lock 期限切れは lock-expired" {
            $ev = $script:locked.Clone()
            $ev["prev_last_routed_at"] = [datetimeoffset]::UtcNow.AddMinutes(-800).ToString("o")
            (Invoke-GoalRouterRoute -Evidence $ev -LockMinutes 720).Transition | Should -Be "lock-expired"
        }

        It "前回と同じ結果なら unchanged" {
            $ev = $script:locked.Clone()
            $ev["prev_session_locked"] = "false"
            $ev["prev_primary_goal"] = "development"
            $r = Invoke-GoalRouterRoute -Evidence $ev
            $r.Primary | Should -Be "development"
            $r.Transition | Should -Be "unchanged"
        }
    }

    Describe "Invoke-GoalRouterRoute — fail-safe" {
        It "Primary が決まらない場合は fallback する" {
            # legacy_goal_type が壊れていても必ず有効な Primary を返す
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; legacy_goal_type = "bogus" }
            (Test-GoalRouterIsPrimary -Goal $r.Primary) | Should -BeTrue
        }

        It "許可されない Specialized は除外される" {
            $r = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; execution_plane = "local" } -Explicit "development"
            Test-GoalRouterIsGoal -Goal $r.Effective | Should -BeTrue
        }

        It "execution_plane は不正値を local に落とす" {
            (Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; execution_plane = "weird" }).Plane | Should -Be "local"
        }

        It "空の Evidence でも必ず 1 つの Goal を返す" {
            $r = Invoke-GoalRouterRoute -Evidence @{}
            (Test-GoalRouterIsPrimary -Goal $r.Primary) | Should -BeTrue
            $r.Effective | Should -Not -BeNullOrEmpty
        }
    }

    Describe "Save-GoalRouterState" {
        It "goal_router ブロックを書き込み、他キーを保持する" {
            $statePath = Join-Path $TestDrive "state.json"
            @{ goal = @{ title = "t" }; execution = @{ phase = "Monitor" } } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8

            $route = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; phase_mode = "maintenance"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            Save-GoalRouterState -StatePath $statePath -Route $route | Should -BeTrue

            $written = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $written.goal_router.primary_goal | Should -Be "development"
            $written.goal_router.effective_goal_type | Should -Be "development"
            $written.goal_router.mode | Should -Be "auto"
            $written.goal_router.route_version | Should -Be 1
            $written.goal.title | Should -Be "t"
            $written.execution.phase | Should -Be "Monitor"
        }

        It "一時ファイルを残さない (原子的置換)" {
            $statePath = Join-Path $TestDrive "state2.json"
            '{"goal":{"title":"t"}}' | Set-Content -LiteralPath $statePath -Encoding UTF8
            $route = Invoke-GoalRouterRoute -Evidence @{ state_present = "0" }
            Save-GoalRouterState -StatePath $statePath -Route $route | Should -BeTrue
            @(Get-ChildItem -Path $TestDrive -Filter "state2.json.tmp-*").Count | Should -Be 0
        }

        It "state.json が無ければ false (起動を止めない)" {
            Save-GoalRouterState -StatePath (Join-Path $TestDrive "missing.json") `
                -Route (Invoke-GoalRouterRoute -Evidence @{}) | Should -BeFalse
        }

        It "壊れた state.json でも例外にせず false" {
            $bad = Join-Path $TestDrive "bad.json"
            "{not json" | Set-Content -LiteralPath $bad -Encoding UTF8
            Save-GoalRouterState -StatePath $bad -Route (Invoke-GoalRouterRoute -Evidence @{}) | Should -BeFalse
        }

        It "特殊化 Goal が無いときは specialized_goal が null になる" {
            $statePath = Join-Path $TestDrive "state3.json"
            '{"goal":{"title":"t"}}' | Set-Content -LiteralPath $statePath -Encoding UTF8
            $route = Invoke-GoalRouterRoute -Evidence @{ state_present = "1"; phase_mode = "maintenance"; has_ci = "1"; has_tests = "1"; git_commits = "50" }
            Save-GoalRouterState -StatePath $statePath -Route $route | Out-Null
            $written = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $written.goal_router.specialized_goal | Should -BeNullOrEmpty
        }
    }

    Describe "Get-GoalTemplatePath" {
        It "プロジェクトの config/goals を最優先で解決する" {
            $proj = Join-Path $TestDrive "proj"
            New-Item -ItemType Directory -Path (Join-Path $proj "config/goals") -Force | Out-Null
            "x" | Set-Content -LiteralPath (Join-Path $proj "config/goals/development.md") -Encoding UTF8
            Get-GoalTemplatePath -ProjectDir $proj -GoalType "development" | Should -Be (Join-Path $proj "config/goals/development.md")
        }

        It "対象が無ければ mvp-release へフォールバックする" {
            $proj = Join-Path $TestDrive "proj2"
            New-Item -ItemType Directory -Path (Join-Path $proj "config/goals") -Force | Out-Null
            "x" | Set-Content -LiteralPath (Join-Path $proj "config/goals/mvp-release.md") -Encoding UTF8
            Get-GoalTemplatePath -ProjectDir $proj -GoalType "no-such-goal" | Should -Match "mvp-release\.md$"
        }
    }
}

Describe "リポジトリ同梱の Goal テンプレート" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $repoRoot "scripts/lib/CodexGoalClient.psm1") -Force
        Import-Module (Join-Path $repoRoot "scripts/lib/GoalRouter.psm1") -Force
        $script:goalsDir = Join-Path $repoRoot "config/goals"
        $script:allGoals = @(Get-GoalRouterPrimaryGoals) + @(Get-GoalRouterSpecializedGoals)
    }

    It "Primary 5 + Specialized 6 の全 11 テンプレートが存在する" {
        foreach ($g in $script:allGoals) {
            Test-Path -LiteralPath (Join-Path $script:goalsDir "$g.md") | Should -BeTrue -Because "$g.md が必要"
        }
    }

    It "全テンプレートが Codex の 4,000 字以内で objective を抽出できる" {
        foreach ($g in $script:allGoals) {
            $path = Join-Path $script:goalsDir "$g.md"
            $objective = Get-CodexGoalObjectiveFromTemplate -Path $path
            $check = Test-CodexGoalObjective -Objective $objective
            $check.Valid | Should -BeTrue -Because "$g.md は有効な objective を持つ必要がある ($($check.Reason))"
        }
    }

    It "全テンプレートが /goal ブロックを持つ" {
        foreach ($g in $script:allGoals) {
            $raw = Get-Content -LiteralPath (Join-Path $script:goalsDir "$g.md") -Raw -Encoding UTF8
            $raw | Should -Match '/goal\s*"' -Because "$g.md に /goal ブロックが必要"
        }
    }
}
