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

        It "出力合計が上限ちょうどなら切り捨てず成功する" {
            $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @('-c', 'head -c 524288 /dev/zero; head -c 524288 /dev/zero >&2')
            $result.ExitCode | Should -Be 0
            $result.OutputLimitExceeded | Should -BeFalse
            $result.Output.Length | Should -Be 1048576
        }

        It "<Label> の出力超過はタイムアウトではなく失敗として返す" -ForEach @(
            @{ Label = 'stdout'; Script = 'head -c 1048577 /dev/zero' },
            @{ Label = 'stderr'; Script = 'head -c 1048577 /dev/zero >&2' },
            @{ Label = '合計'; Script = 'head -c 524288 /dev/zero; head -c 524289 /dev/zero >&2' }
        ) {
            $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @('-c', $Script)
            $result.ExitCode | Should -Be -1
            $result.TimedOut | Should -BeFalse
            $result.OutputLimitExceeded | Should -BeTrue
            $result.Output | Should -Be 'health command output exceeded 1048576 characters'
        }

        It "出力超過時は専用グループの子を回収し無関係なプロセスを残す" {
            $pidFile = Join-Path $TestDrive 'overflow-child.pid'
            $childId = $null
            $unrelated = Start-Process /usr/bin/sleep -ArgumentList 30 -PassThru
            try {
                $command = 'sleep 30 & printf "%s" "$!" > "$1"; head -c 1048577 /dev/zero; wait'
                $result = Invoke-McpProcessWithTimeout -Command /bin/sh -Arguments @('-c', $command, 'health-check', $pidFile)
                $result.OutputLimitExceeded | Should -BeTrue
                $unrelated.HasExited | Should -BeFalse
                $childId = [int](Get-Content -LiteralPath $pidFile -Raw)
                $statPath = "/proc/$childId/stat"
                if (Test-Path -LiteralPath $statPath) {
                    (Get-Content -LiteralPath $statPath -Raw) | Should -Match '^\d+ \(.*\) [ZX] '
                }
                else { Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
            }
            finally {
                if ($childId) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
                if (-not $unrelated.HasExited) { $unrelated.Kill() }
                $unrelated.Dispose()
            }
        }

        It "出力超過をヘルス結果では unhealthy とし出力を保存しない" {
            $definition = [pscustomobject]@{
                command = '/bin/sh'
                healthCommand = @('/bin/sh', '-c', 'head -c 1048577 /dev/zero')
            }
            $result = Get-McpServerHealth -Name 'overflow' -Definition $definition
            $result.healthStatus | Should -Be 'unhealthy'
            $result.healthOutput | Should -Be 'health command output exceeded 1048576 characters'
        }

        It "改行なしの長い初期応答を拒否し検査コマンドを実行しない" {
            $bin = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'invalid-handshake-bin')
            $sessionCommand = Join-Path $bin.FullName 'setsid'
            @'
#!/bin/sh
exec /usr/bin/head -c 65536 /dev/zero
'@ | Set-Content -LiteralPath $sessionCommand -Encoding utf8NoBOM
            & chmod +x $sessionCommand
            $marker = Join-Path $TestDrive 'not-created-invalid-handshake'
            $previousPath = $env:PATH
            try {
                $env:PATH = $bin.FullName + [System.IO.Path]::PathSeparator + $previousPath
                { Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) } | Should -Throw '*ownership could not be verified*'
            }
            finally { $env:PATH = $previousPath }
            Test-Path $marker | Should -BeFalse
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
            $bin = New-Item -ItemType Directory -Path (Join-Path $TestDrive "bin-$Dependency")
            foreach ($name in @('setsid', 'sh', 'kill') | Where-Object { $_ -ne $Dependency }) {
                $source = (Get-Command $name -CommandType Application | Select-Object -First 1).Source
                New-Item -ItemType SymbolicLink -Path (Join-Path $bin.FullName $name) -Target $source | Out-Null
            }
            $marker = Join-Path $TestDrive "not-created-$Dependency"
            $previousPath = $env:PATH
            try {
                $env:PATH = $bin.FullName
                { Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) } | Should -Throw "*$Dependency*"
            }
            finally { $env:PATH = $previousPath }
            Test-Path $marker | Should -BeFalse
        }

        It "プロセスグループの所有を確認できなければ検査コマンドを実行しない" {
            Mock Test-McpProcessGroupOwnership { $false }
            $marker = Join-Path $TestDrive "not-created-unowned"
            { Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) } | Should -Throw '*ownership could not be verified*'
            Test-Path $marker | Should -BeFalse
        }

        It "初期応答待ちもタイムアウトに含め検査コマンドを実行しない" {
            $bin = New-Item -ItemType Directory -Path (Join-Path $TestDrive "silent-bin")
            $silentSessionCommand = Join-Path $bin.FullName "setsid"
            @'
#!/bin/sh
exec /usr/bin/sleep 30
'@ | Set-Content -LiteralPath $silentSessionCommand -Encoding utf8NoBOM
            & chmod +x $silentSessionCommand
            $marker = Join-Path $TestDrive "not-created-timeout"
            $timer = [System.Diagnostics.Stopwatch]::StartNew()

            $previousPath = $env:PATH
            try {
                $env:PATH = $bin.FullName + [System.IO.Path]::PathSeparator + $previousPath
                $result = Invoke-McpProcessWithTimeout -Command /usr/bin/touch -Arguments @($marker) -TimeoutSec 1
            }
            finally { $env:PATH = $previousPath }

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
