BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/MenuCommon.psm1") -Force
}

Describe "ConvertTo-MenuRecentToolFilter" {
    It "空文字列は空文字列を返す" {
        ConvertTo-MenuRecentToolFilter -ToolFilter '' | Should -Be ''
    }

    It "null/whitespace は空文字列を返す" {
        ConvertTo-MenuRecentToolFilter -ToolFilter '   ' | Should -Be ''
    }

    It "'all' は空文字列を返す（全ツール選択）" {
        ConvertTo-MenuRecentToolFilter -ToolFilter 'all' | Should -Be ''
    }

    It "'codex' はそのまま返す" {
        ConvertTo-MenuRecentToolFilter -ToolFilter 'codex' | Should -Be 'codex'
    }

    It "無効なツール名は空文字列を返す" {
        ConvertTo-MenuRecentToolFilter -ToolFilter 'invalidtool' | Should -Be ''
    }

    It "大文字混じりも PowerShell の case-insensitive -in で有効として扱う" {
        ConvertTo-MenuRecentToolFilter -ToolFilter 'Codex' | Should -Be 'Codex'
    }
}

Describe "ConvertTo-MenuRecentSortMode" {
    It "デフォルト（引数なし）は 'success' を返す" {
        ConvertTo-MenuRecentSortMode | Should -Be 'success'
    }

    It "'success' はそのまま返す" {
        ConvertTo-MenuRecentSortMode -SortMode 'success' | Should -Be 'success'
    }

    It "'timestamp' はそのまま返す" {
        ConvertTo-MenuRecentSortMode -SortMode 'timestamp' | Should -Be 'timestamp'
    }

    It "'elapsed' はそのまま返す" {
        ConvertTo-MenuRecentSortMode -SortMode 'elapsed' | Should -Be 'elapsed'
    }

    It "無効な値は 'success' を返す" {
        ConvertTo-MenuRecentSortMode -SortMode 'invalid' | Should -Be 'success'
    }

    It "空文字列は 'success' を返す" {
        ConvertTo-MenuRecentSortMode -SortMode '' | Should -Be 'success'
    }
}

Describe "Get-MenuRecentFilterSummary" {
    It "デフォルト引数でサマリーを返す" {
        $result = Get-MenuRecentFilterSummary
        $result.tool | Should -Be 'all'
        $result.search | Should -Be 'none'
        $result.sort | Should -Be 'success'
    }

    It "tool=codex のサマリーを返す" {
        $result = Get-MenuRecentFilterSummary -ToolFilter 'codex'
        $result.tool | Should -Be 'codex'
    }

    It "tool=invalid は tool='all' で返す（無効値正規化）" {
        $result = Get-MenuRecentFilterSummary -ToolFilter 'invalid'
        $result.tool | Should -Be 'all'
    }

    It "searchQuery が設定されると search フィールドに反映される" {
        $result = Get-MenuRecentFilterSummary -SearchQuery 'my-project'
        $result.search | Should -Be 'my-project'
    }

    It "空の searchQuery は 'none' を返す" {
        $result = Get-MenuRecentFilterSummary -SearchQuery ''
        $result.search | Should -Be 'none'
    }

    It "sort=timestamp が反映される" {
        $result = Get-MenuRecentFilterSummary -SortMode 'timestamp'
        $result.sort | Should -Be 'timestamp'
    }

    It "結果オブジェクトに必須プロパティが含まれる" {
        $result = Get-MenuRecentFilterSummary
        $result.PSObject.Properties.Name | Should -Contain "tool"
        $result.PSObject.Properties.Name | Should -Contain "search"
        $result.PSObject.Properties.Name | Should -Contain "sort"
    }
}

Describe "Get-ValidToolNames / Get-ValidSortModes" {
    It "Get-ValidToolNames が有効なツール名リストを返す" {
        $tools = Get-ValidToolNames
        $tools | Should -Contain 'codex'
        $tools | Should -Not -Contain 'claude'
        $tools | Should -Not -Contain 'copilot'
    }

    It "Get-ValidSortModes が有効なソートモードリストを返す" {
        $modes = Get-ValidSortModes
        $modes | Should -Contain 'success'
        $modes | Should -Contain 'timestamp'
        $modes | Should -Contain 'elapsed'
    }
}
