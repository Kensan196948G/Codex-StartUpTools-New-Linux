$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot "scripts/lib/McpHealthCheck.psm1") -Force

InModuleScope McpHealthCheck {
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
