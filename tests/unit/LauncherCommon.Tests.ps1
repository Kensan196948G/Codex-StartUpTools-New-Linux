BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/lib/LauncherCommon.psm1" -Force -DisableNameChecking
}

Describe "Find-AvailableDriveLetter" {
    It "使用中のドライブレターを返さない" {
        $usedLetters = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)
        $result = Find-AvailableDriveLetter
        if ($result) {
            $result | Should -Not -BeIn $usedLetters
        }
    }

    It "PreferredLetters の優先順で返す" {
        $usedLetters = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)
        $preferred = @("P", "Q", "R")
        $result = Find-AvailableDriveLetter -PreferredLetters $preferred
        if ($result) {
            $expectedFirst = $preferred | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
            $result | Should -Be $expectedFirst
        }
    }

    It "ExcludeLetters で除外できる" {
        $result = Find-AvailableDriveLetter -PreferredLetters @("P", "Q") -ExcludeLetters @("P")
        if ($result) {
            $result | Should -Not -Be "P"
        }
    }
}

Describe "Get-LauncherModeName" {
    It "常に local を返す" {
        Get-LauncherModeName | Should -Be "local"
    }
}
