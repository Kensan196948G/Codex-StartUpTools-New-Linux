BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/OrchestrationCommon.psm1") -Force
}

Describe "New-OrchestrationId" {
    It "GUID形式の文字列を返す" {
        $id = New-OrchestrationId
        { [guid]::Parse($id) } | Should -Not -Throw
    }

    It "呼び出すたびに異なる値を返す" {
        (New-OrchestrationId) | Should -Not -Be (New-OrchestrationId)
    }
}

Describe "ConvertTo-PostgreSqlLiteral" {
    It "シングルクォートをエスケープする" {
        ConvertTo-PostgreSqlLiteral -Value "O'Brien" | Should -Be "'O''Brien'"
    }

    It "空文字も安全に扱う" {
        ConvertTo-PostgreSqlLiteral -Value "" | Should -Be "''"
    }
}

Describe "ConvertTo-PostgreSqlJsonLiteral" {
    It "hashtableをjsonbリテラルへ変換する" {
        $literal = ConvertTo-PostgreSqlJsonLiteral -InputObject @{ foo = "bar" }
        $literal | Should -Match "::jsonb$"
        $literal | Should -Match '"foo"\s*:\s*"bar"'
    }

    It "値中のシングルクォートをエスケープする" {
        $literal = ConvertTo-PostgreSqlJsonLiteral -InputObject @{ note = "it's ok" }
        $literal | Should -Match "it''s ok"
    }
}

Describe "Orchestration File Fallback" {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ".git") -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "レコードを追記し、全件取得できる" {
        Add-OrchestrationFallbackRecord -Kind "tasks" -Record @{ id = "abc"; status = "pending" } -ProjectRoot $script:TempRoot
        Add-OrchestrationFallbackRecord -Kind "tasks" -Record @{ id = "def"; status = "done" } -ProjectRoot $script:TempRoot

        $records = @(Get-OrchestrationFallbackRecord -Kind "tasks" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 2
    }

    It "Idを指定すると一致するレコードのみ返す" {
        Add-OrchestrationFallbackRecord -Kind "tasks" -Record @{ id = "abc"; status = "pending" } -ProjectRoot $script:TempRoot
        Add-OrchestrationFallbackRecord -Kind "tasks" -Record @{ id = "def"; status = "done" } -ProjectRoot $script:TempRoot

        $records = @(Get-OrchestrationFallbackRecord -Kind "tasks" -Id "def" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 1
        $records[0].status | Should -Be "done"
    }

    It "ファイルが存在しない場合は空配列を返す" {
        $records = @(Get-OrchestrationFallbackRecord -Kind "runs" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 0
    }
}
