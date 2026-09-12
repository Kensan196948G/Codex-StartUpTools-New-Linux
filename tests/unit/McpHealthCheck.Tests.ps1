$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot "scripts/lib/McpHealthCheck.psm1") -Force

InModuleScope McpHealthCheck {
    Describe "Invoke-McpProcessWithTimeout 実プロセス回帰" {
        It "TEMP 未設定でも成功する" {
            $previousTemp = $env:TEMP
            try {
                Remove-Item Env:TEMP -ErrorAction SilentlyContinue
                $result = Invoke-McpProcessWithTimeout -Command /usr/bin/true
                $result.TimedOut | Should -BeFalse
                $result.ExitCode | Should -Be 0
                $result.Output | Should -Be ""
            }
            finally { $env:TEMP = $previousTemp }
        }

        It "失敗の終了コードと両出力を返す" {
            $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @("-c", "printf out; printf err >&2; exit 7")
            $result.TimedOut | Should -BeFalse
            $result.ExitCode | Should -Be 7
            $result.Output | Should -Be "outerr"
        }

        It "空白・空文字・引用符・末尾バックスラッシュの引数を保持する" {
            $result = Invoke-McpProcessWithTimeout -Command /usr/bin/printf -Arguments @('<%s>', 'two words', '', 'say "hi"', 'path with space\', 'plain\', '$literal')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Be '<two words><><say "hi"><path with space\><plain\><$literal>'
        }

        It "stdout と stderr がパイプ容量を超えても完了する" {
            $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @("-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2")
            $result.TimedOut | Should -BeFalse
            $result.ExitCode | Should -Be 0
            $result.Output.Length | Should -Be 524288
        }

        It "タイムアウト時に子プロセスも終了する（親終了=<ParentExits>）" -ForEach @(
            @{ ParentExits = $false; ParentAction = 'wait' },
            @{ ParentExits = $true; ParentAction = 'exit 0' }
        ) {
            $pidFile = Join-Path $TestDrive "child.pid"
            $childId = $null
            $unrelated = Start-Process /usr/bin/sleep -ArgumentList 30 -PassThru
            try {
                $command = 'sleep 30 & child=$!; printf "%s" "$child" > "$1"; ' + $ParentAction
                $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @('-c', $command, 'health-check', $pidFile) -TimeoutSec 1
                $result.TimedOut | Should -BeTrue
                $result.ExitCode | Should -Be -1
                $result.Output | Should -Be "health command timed out after 1s"
                $unrelated.HasExited | Should -BeFalse
                $childId = [int](Get-Content -LiteralPath $pidFile -Raw)
                # Linux は終了済みの子を一時的に zombie として保持する場合がある。
                $statPath = "/proc/$childId/stat"
                if (Test-Path -LiteralPath $statPath) {
                    (Get-Content -LiteralPath $statPath -Raw) | Should -Match '^\d+ \(.*\) [ZX] '
                }
                else {
                    Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                }
            }
            finally {
                if ($childId) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
                if (-not $unrelated.HasExited) { $unrelated.Kill() }
                $unrelated.Dispose()
            }
        }

        It "<Dependency> 欠落時は検査コマンドを実行しない" -ForEach @(
            @{ Dependency = 'setsid' }, @{ Dependency = 'sh' }, @{ Dependency = 'kill' }
        ) {
            $script:MissingDependency = $Dependency
            Mock Get-Command { throw 'required OS command not found' } -ParameterFilter { $Name -eq $script:MissingDependency }
            $marker = Join-Path $TestDrive "not-created-$Dependency"
            { Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) } | Should -Throw '*required OS command not found*'
            Test-Path $marker | Should -BeFalse
        }

        It "プロセスグループの所有を確認できなければ検査コマンドを実行しない" {
            Mock Test-McpProcessGroupOwnership { $false }
            $marker = Join-Path $TestDrive "not-created-unowned"
            { Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) } | Should -Throw '*ownership could not be verified*'
            Test-Path $marker | Should -BeFalse
        }

        It "初期応答待ちもタイムアウトに含め検査コマンドを実行しない" {
            $script:SilentSessionCommand = Join-Path $TestDrive "silent-setsid"
            @'
#!/bin/sh
sleep 30
'@ | Set-Content -LiteralPath $script:SilentSessionCommand -Encoding utf8NoBOM
            & chmod +x $script:SilentSessionCommand
            Mock Get-Command { [pscustomobject]@{ Source = $script:SilentSessionCommand } } -ParameterFilter { $Name -eq 'setsid' }
            $marker = Join-Path $TestDrive "not-created-timeout"
            $timer = [System.Diagnostics.Stopwatch]::StartNew()

            $result = Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) -TimeoutSec 1

            $result.TimedOut | Should -BeTrue
            $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
            Test-Path $marker | Should -BeFalse
        }
    }

    Describe "ConvertTo-McpProcessArgumentString" {
        It "空配列なら空文字を返す" {
            ConvertTo-McpProcessArgumentString -Arguments @() | Should -Be ""
        }

        It "単一引数はそのまま返す" {
            ConvertTo-McpProcessArgumentString -Arguments @("node") | Should -Be "node"
        }

        It "スペースを含む引数はクォートする" {
            ConvertTo-McpProcessArgumentString -Arguments @("my server") | Should -Be '"my server"'
        }

        It "ダブルクォートをエスケープする" {
            ConvertTo-McpProcessArgumentString -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
        }

        It "複数引数をスペース区切りで連結する" {
            ConvertTo-McpProcessArgumentString -Arguments @("node", "server.js", "--port", "3000") | Should -Be "node server.js --port 3000"
        }

        It "単純引数とスペース入り引数を混在処理できる" {
            ConvertTo-McpProcessArgumentString -Arguments @("node", "my server.js") | Should -Be 'node "my server.js"'
        }
    }
}
