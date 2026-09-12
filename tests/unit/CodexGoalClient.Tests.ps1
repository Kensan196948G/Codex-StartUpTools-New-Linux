$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot "scripts/lib/CodexGoalClient.psm1") -Force

InModuleScope CodexGoalClient {
    Describe "Get-CodexGoalObjectiveMaxLength" {
        It "Codex 仕様の 4000 文字を返す" {
            Get-CodexGoalObjectiveMaxLength | Should -Be 4000
        }
    }

    Describe "Test-CodexGoalObjective" {
        It "空文字は無効 (objective-empty)" {
            $r = Test-CodexGoalObjective -Objective ""
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Be "objective-empty"
            $r.Length | Should -Be 0
        }

        It "空白のみは無効" {
            (Test-CodexGoalObjective -Objective "   `n  ").Valid | Should -BeFalse
        }

        It "通常の objective は有効" {
            $r = Test-CodexGoalObjective -Objective "CI を緑にして PR を作成する"
            $r.Valid | Should -BeTrue
            $r.Reason | Should -Be "ok"
        }

        It "ちょうど 4000 文字は有効 (境界)" {
            (Test-CodexGoalObjective -Objective ("a" * 4000)).Valid | Should -BeTrue
        }

        It "4001 文字は無効 (objective-too-long)" {
            $r = Test-CodexGoalObjective -Objective ("a" * 4001)
            $r.Valid | Should -BeFalse
            $r.Reason | Should -Be "objective-too-long"
        }

        It "日本語 1500 文字 (UTF-8 で 4500 バイト) は文字数判定で有効" {
            $objective = "あ" * 1500
            [System.Text.Encoding]::UTF8.GetByteCount($objective) | Should -BeGreaterThan 4000
            (Test-CodexGoalObjective -Objective $objective).Valid | Should -BeTrue
        }
    }

    Describe "Get-CodexGoalObjectiveFromTemplate" {
        It '開き /goal 行から閉じ " 行までを objective として抽出する' {
            $path = Join-Path $TestDrive "goal-template.md"
            @(
                '# Goal: test'
                ''
                '/goal "'
                '■ Goal'
                'テストを通す。'
                '■ Stop Conditions'
                '- or stop after 12 turns'
                '"'
                '',
                '後書き'
            ) | Set-Content -LiteralPath $path -Encoding UTF8

            $objective = Get-CodexGoalObjectiveFromTemplate -Path $path
            $objective | Should -Match "■ Goal"
            $objective | Should -Match "テストを通す。"
            $objective | Should -Match "- or stop after 12 turns"
            $objective | Should -Not -Match '/goal'
            $objective | Should -Not -Match '後書き'
        }

        It "存在しないファイルは例外" {
            { Get-CodexGoalObjectiveFromTemplate -Path (Join-Path $TestDrive "missing.md") } | Should -Throw
        }

        It "/goal ブロックが無ければ例外" {
            $path = Join-Path $TestDrive "no-block.md"
            @('# Goal', '本文のみ') | Set-Content -LiteralPath $path -Encoding UTF8
            { Get-CodexGoalObjectiveFromTemplate -Path $path } | Should -Throw
        }

        It '閉じ " が欠落した不完全ブロックは例外 (非破壊フォールバック)' {
            $path = Join-Path $TestDrive "unterminated.md"
            @('/goal "', '■ Goal', '途中で終わる') | Set-Content -LiteralPath $path -Encoding UTF8
            { Get-CodexGoalObjectiveFromTemplate -Path $path } | Should -Throw
        }
    }

    Describe "New-CodexGoalRpcRequest" {
        It "JSON-RPC 2.0 フレームを組み立てる" {
            $frame = New-CodexGoalRpcRequest -Id 7 -Method "thread/goal/set" -Parameters @{ threadId = "t1" }
            $obj = $frame | ConvertFrom-Json
            $obj.jsonrpc | Should -Be "2.0"
            $obj.id | Should -Be 7
            $obj.method | Should -Be "thread/goal/set"
            $obj.params.threadId | Should -Be "t1"
        }

        It "Parameters 省略時は params を含めない" {
            (New-CodexGoalRpcRequest -Id 1 -Method "initialize") | Should -Not -Match '"params"'
        }

        It "1 行 JSON (改行を含まない)" {
            (New-CodexGoalRpcRequest -Id 1 -Method "initialize") | Should -Not -Match "`n"
        }
    }

    Describe "ConvertFrom-CodexGoalRpcResponse" {
        It "指定 id の応答を返す" {
            $r = ConvertFrom-CodexGoalRpcResponse -Line '{"jsonrpc":"2.0","id":2,"result":{"ok":true}}' -Id 2
            $r.result.ok | Should -BeTrue
        }

        It "通知 (id 無し) は無視する" {
            ConvertFrom-CodexGoalRpcResponse -Line '{"method":"thread/started","params":{}}' -Id 1 | Should -BeNullOrEmpty
        }

        It "解析不能行は無視する" {
            ConvertFrom-CodexGoalRpcResponse -Line 'not-json' -Id 3 | Should -BeNullOrEmpty
        }

        It "該当 id が無ければ null" {
            ConvertFrom-CodexGoalRpcResponse -Line '{"jsonrpc":"2.0","id":9,"result":{}}' -Id 1 | Should -BeNullOrEmpty
        }
    }

    Describe "Get-CodexGoalRpcResult" {
        It "result を返す" {
            $r = '{"jsonrpc":"2.0","id":1,"result":{"cleared":true}}' | ConvertFrom-Json
            (Get-CodexGoalRpcResult -Response $r).cleared | Should -BeTrue
        }

        It "error 応答は例外にする" {
            $r = '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"invalid thread id"}}' | ConvertFrom-Json
            { Get-CodexGoalRpcResult -Response $r } | Should -Throw "*invalid thread id*"
        }
    }

    Describe "Set-CodexThreadGoal (session mocked)" {
        BeforeEach {
            Mock New-CodexGoalSession -MockWith { [pscustomobject]@{ Process = $null; NextId = 0; Initialized = $true } }
            Mock Close-CodexGoalSession -MockWith { }
        }

        It "objective が上限超過ならセッションを開く前に例外" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { throw "should not be called" }
            { Set-CodexThreadGoal -ThreadId "t1" -Objective ("a" * 4001) } | Should -Throw "*objective-too-long*"
            Should -Invoke New-CodexGoalSession -Times 0
        }

        It "thread/resume してから thread/goal/set を送る" {
            $script:seen = @()
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                $script:seen += $Method
                if ($Method -eq "thread/goal/set") {
                    return [pscustomobject]@{ goal = [pscustomobject]@{ threadId = "t1"; status = "active"; objective = $Parameters.objective } }
                }
                return [pscustomobject]@{ thread = [pscustomobject]@{ id = "t1" } }
            }

            $goal = Set-CodexThreadGoal -ThreadId "t1" -Objective "テスト"
            $goal.threadId | Should -Be "t1"
            $goal.status | Should -Be "active"
            $script:seen | Should -Contain "thread/resume"
            $script:seen | Should -Contain "thread/goal/set"
        }

        It "TokenBudget 指定時のみ tokenBudget を載せる" {
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                if ($Method -eq "thread/goal/set") {
                    $tb = if ($Parameters.ContainsKey("tokenBudget")) { $Parameters["tokenBudget"] } else { $null }
                    return [pscustomobject]@{ goal = [pscustomobject]@{ tokenBudget = $tb } }
                }
                return [pscustomobject]@{ thread = [pscustomobject]@{ id = "t1" } }
            }

            (Set-CodexThreadGoal -ThreadId "t1" -Objective "o").tokenBudget | Should -BeNullOrEmpty
            (Set-CodexThreadGoal -ThreadId "t1" -Objective "o" -TokenBudget 500000).tokenBudget | Should -Be 500000
        }

        It "失敗しても必ずセッションを閉じる" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { throw "rpc boom" }
            { Set-CodexThreadGoal -ThreadId "t1" -Objective "o" } | Should -Throw "*rpc boom*"
            Should -Invoke Close-CodexGoalSession -Times 1
        }
    }

    Describe "Get-CodexThreadGoal / Clear-CodexThreadGoal (session mocked)" {
        BeforeEach {
            Mock New-CodexGoalSession -MockWith { [pscustomobject]@{ Process = $null; NextId = 0; Initialized = $true } }
            Mock Close-CodexGoalSession -MockWith { }
        }

        It "thread/goal/get の goal を返す" {
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                [pscustomobject]@{ goal = [pscustomobject]@{ threadId = "t1"; status = "blocked" } }
            }
            (Get-CodexThreadGoal -ThreadId "t1").status | Should -Be "blocked"
        }

        It "thread/goal/clear の cleared を返す" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { [pscustomobject]@{ cleared = $true } }
            Clear-CodexThreadGoal -ThreadId "t1" | Should -BeTrue
        }
    }

    Describe "Start-CodexGoalRun (session mocked)" {
        BeforeEach {
            Mock New-CodexGoalSession -MockWith { [pscustomobject]@{ Process = $null; NextId = 0; Initialized = $true } }
            Mock Close-CodexGoalSession -MockWith { }
        }

        It "同一セッション内で thread/start と thread/goal/set を行う" {
            $script:methods = @()
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                $script:methods += $Method
                if ($Method -eq "thread/start") {
                    return [pscustomobject]@{ thread = [pscustomobject]@{ id = "thread-abc" } }
                }
                return [pscustomobject]@{ goal = [pscustomobject]@{ threadId = "thread-abc"; status = "active" } }
            }

            $run = Start-CodexGoalRun -Objective "objective" -WorkingDirectory "/tmp"
            $run.ThreadId | Should -Be "thread-abc"
            $run.Goal.status | Should -Be "active"
            $script:methods | Should -Be @("thread/start", "thread/goal/set")
            Should -Invoke Close-CodexGoalSession -Times 1
        }

        It "thread id が返らなければ例外" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { [pscustomobject]@{ thread = $null } }
            { Start-CodexGoalRun -Objective "o" -WorkingDirectory "/tmp" } | Should -Throw "*thread id*"
        }

        It "objective が上限超過ならセッションを開く前に例外" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { throw "should not be called" }
            { Start-CodexGoalRun -Objective ("a" * 4001) } | Should -Throw "*objective-too-long*"
            Should -Invoke New-CodexGoalSession -Times 0
        }
    }

    Describe "End-to-end against the real codex binary" {
        # 実際に codex app-server を起動し thread と rollout を生成するため
        # 既定では実行しない。CODEX_STARTUP_E2E=1 を明示したときだけ動かす。
        It "goal を設定・取得・削除できる" -Skip:(-not $env:CODEX_STARTUP_E2E) {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "codex binary not found"
                return
            }

            $run = Start-CodexGoalRun -Objective "PROBE: Pester e2e goal" -WorkingDirectory ([System.IO.Path]::GetTempPath())
            try {
                $run.ThreadId | Should -Not -BeNullOrEmpty
                $goal = Get-CodexThreadGoal -ThreadId $run.ThreadId
                $goal.status | Should -Be "active"

                # 別プロセスから既存スレッドへ設定できること (thread/resume 経由)
                $again = Set-CodexThreadGoal -ThreadId $run.ThreadId -Objective "PROBE: Pester e2e goal (updated)"
                $again.objective | Should -Be "PROBE: Pester e2e goal (updated)"
            }
            finally {
                if ($run -and $run.ThreadId) { Clear-CodexThreadGoal -ThreadId $run.ThreadId | Out-Null }
            }
        }
    }

    Describe "Get-CodexGoalTerminalStatuses" {
        It "complete / blocked / usageLimited / budgetLimited を終端とする" {
            $t = Get-CodexGoalTerminalStatuses
            $t | Should -Contain "complete"
            $t | Should -Contain "blocked"
            $t | Should -Contain "usageLimited"
            $t | Should -Contain "budgetLimited"
        }

        It "active / paused は終端ではない" {
            $t = Get-CodexGoalTerminalStatuses
            $t | Should -Not -Contain "active"
            $t | Should -Not -Contain "paused"
        }
    }

    Describe "Get-CodexGoalContinuationPrompt" {
        It "objective を埋め込み、拡大解釈を防ぐタグで囲む" {
            $p = Get-CodexGoalContinuationPrompt -Objective "テストを通す"
            $p | Should -Match "<objective>"
            $p | Should -Match "テストを通す"
        }

        It "Codex ネイティブ継続と同じ規律を含む" {
            $p = Get-CodexGoalContinuationPrompt -Objective "o"
            $p | Should -Match "Keep the full objective intact"
            $p | Should -Match "Work from evidence"
            $p | Should -Match "update_goal"
            $p | Should -Match "three consecutive goal turns"
        }
    }

    Describe "Wait-CodexGoalTurnCompleted" {
        It "turn/completed で抜け、goal status を拾う" {
            $script:queue = @(
                '{"method":"turn/started","params":{}}'
                '{"method":"thread/goal/updated","params":{"goal":{"status":"active","tokensUsed":100}}}'
                '{"method":"turn/completed","params":{}}'
            )
            $script:idx = 0
            Mock Read-CodexGoalSessionLine -MockWith {
                if ($script:idx -ge $script:queue.Count) { return $null }
                $l = $script:queue[$script:idx]; $script:idx++; return $l
            }

            $r = Wait-CodexGoalTurnCompleted -Session ([pscustomobject]@{}) -TimeoutSec 5
            $r.TurnCompleted | Should -BeTrue
            $r.TimedOut | Should -BeFalse
            $r.GoalStatus | Should -Be "active"
            $r.Events | Should -Contain "turn/completed"
        }

        It "id 付き応答行 (通知でない) は無視する" {
            $script:queue = @(
                '{"jsonrpc":"2.0","id":9,"result":{}}'
                '{"method":"turn/completed","params":{}}'
            )
            $script:idx = 0
            Mock Read-CodexGoalSessionLine -MockWith {
                if ($script:idx -ge $script:queue.Count) { return $null }
                $l = $script:queue[$script:idx]; $script:idx++; return $l
            }

            (Wait-CodexGoalTurnCompleted -Session ([pscustomobject]@{}) -TimeoutSec 5).TurnCompleted | Should -BeTrue
        }

        It "turn/completed が来なければ TimedOut" {
            Mock Read-CodexGoalSessionLine -MockWith { return $null }
            $r = Wait-CodexGoalTurnCompleted -Session ([pscustomobject]@{}) -TimeoutSec 1
            $r.TurnCompleted | Should -BeFalse
            $r.TimedOut | Should -BeTrue
        }
    }

    Describe "Invoke-CodexGoalRun (session mocked)" {
        BeforeEach {
            Mock New-CodexGoalSession -MockWith {
                [pscustomobject]@{
                    Process = $null; NextId = 0; Initialized = $true
                    PendingEvents = (New-Object System.Collections.Generic.List[string])
                }
            }
            Mock Close-CodexGoalSession -MockWith { }
        }

        It "objective が不正ならセッションを開かない" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { throw "should not be called" }
            { Invoke-CodexGoalRun -Objective ("a" * 4001) } | Should -Throw "*objective-too-long*"
            Should -Invoke New-CodexGoalSession -Times 0
        }

        It "Goal が complete になったら 1 ターンで終了する" {
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                switch ($Method) {
                    "thread/start" { return [pscustomobject]@{ thread = [pscustomobject]@{ id = "th-1" } } }
                    "thread/goal/set" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "active" } } }
                    "turn/start" { return [pscustomobject]@{} }
                    "thread/goal/get" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "complete"; tokensUsed = 1234 } } }
                }
            }
            Mock Wait-CodexGoalTurnCompleted -MockWith { [pscustomobject]@{ TurnCompleted = $true; TimedOut = $false; GoalStatus = "active"; Goal = $null; Events = @() } }

            $r = Invoke-CodexGoalRun -Objective "テスト" -WorkingDirectory "/tmp"
            $r.ThreadId | Should -Be "th-1"
            $r.FinalStatus | Should -Be "complete"
            $r.StopReason | Should -Be "goal-complete"
            $r.Turns.Count | Should -Be 1
            Should -Invoke Close-CodexGoalSession -Times 1
        }

        It "2 ターン目は継続プロンプトを送る" {
            $script:turns = @()
            $script:goalGets = 0
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                switch ($Method) {
                    "thread/start" { return [pscustomobject]@{ thread = [pscustomobject]@{ id = "th-2" } } }
                    "thread/goal/set" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "active" } } }
                    "turn/start" { $script:turns += $Parameters.input[0].text; return [pscustomobject]@{} }
                    "thread/goal/get" {
                        $script:goalGets++
                        $st = if ($script:goalGets -ge 2) { "complete" } else { "active" }
                        return [pscustomobject]@{ goal = [pscustomobject]@{ status = $st } }
                    }
                }
            }
            Mock Wait-CodexGoalTurnCompleted -MockWith { [pscustomobject]@{ TurnCompleted = $true; TimedOut = $false; GoalStatus = "active"; Goal = $null; Events = @() } }

            $r = Invoke-CodexGoalRun -Objective "OBJECTIVE-X" -WorkingDirectory "/tmp" -MaxTurns 5
            $r.Turns.Count | Should -Be 2
            $script:turns[0] | Should -Be "OBJECTIVE-X"
            $script:turns[1] | Should -Match "Continue working toward the active thread goal"
        }

        It "MaxTurns に達したら max-turns で止まる" {
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                switch ($Method) {
                    "thread/start" { return [pscustomobject]@{ thread = [pscustomobject]@{ id = "th-3" } } }
                    "thread/goal/set" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "active" } } }
                    "turn/start" { return [pscustomobject]@{} }
                    "thread/goal/get" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "active" } } }
                }
            }
            Mock Wait-CodexGoalTurnCompleted -MockWith { [pscustomobject]@{ TurnCompleted = $true; TimedOut = $false; GoalStatus = "active"; Goal = $null; Events = @() } }

            $r = Invoke-CodexGoalRun -Objective "o" -WorkingDirectory "/tmp" -MaxTurns 3
            $r.Turns.Count | Should -Be 3
            $r.StopReason | Should -Be "max-turns"
            $r.FinalStatus | Should -Be "active"
        }

        It "blocked も終端として扱う" {
            Mock Invoke-CodexGoalSessionRpc -MockWith {
                param($Session, $Method, $Parameters, $TimeoutSec)
                switch ($Method) {
                    "thread/start" { return [pscustomobject]@{ thread = [pscustomobject]@{ id = "th-4" } } }
                    "thread/goal/set" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "active" } } }
                    "turn/start" { return [pscustomobject]@{} }
                    "thread/goal/get" { return [pscustomobject]@{ goal = [pscustomobject]@{ status = "blocked" } } }
                }
            }
            Mock Wait-CodexGoalTurnCompleted -MockWith { [pscustomobject]@{ TurnCompleted = $true; TimedOut = $false; GoalStatus = "blocked"; Goal = $null; Events = @() } }

            $r = Invoke-CodexGoalRun -Objective "o" -WorkingDirectory "/tmp"
            $r.FinalStatus | Should -Be "blocked"
            $r.StopReason | Should -Be "goal-blocked"
            $r.Turns.Count | Should -Be 1
        }

        It "例外が出てもセッションを必ず閉じる" {
            Mock Invoke-CodexGoalSessionRpc -MockWith { throw "rpc boom" }
            { Invoke-CodexGoalRun -Objective "o" -WorkingDirectory "/tmp" } | Should -Throw "*rpc boom*"
            Should -Invoke Close-CodexGoalSession -Times 1
        }
    }

    Describe "Read-CodexGoalSessionLine" {
        It "バッファがあればバッファを先に返す" {
            $session = [pscustomobject]@{
                Process       = $null
                PendingEvents = New-Object System.Collections.Generic.List[string]
            }
            $session.PendingEvents.Add('{"method":"buffered"}')
            (Read-CodexGoalSessionLine -Session $session -TimeoutSec 1) | Should -Be '{"method":"buffered"}'
            $session.PendingEvents.Count | Should -Be 0
        }
    }
}
