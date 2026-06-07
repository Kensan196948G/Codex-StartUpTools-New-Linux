BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/ArchitectureCheck.psm1") -Force
}

Describe "Invoke-ArchitectureCheck" {
    It "空ディレクトリでは Passed=true" {
        $dir = Join-Path $TestDrive "empty"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $result = Invoke-ArchitectureCheck -Path $dir
        $result.CheckedFiles | Should -Be 0
        $result.Passed | Should -BeTrue
    }

    It "ハードコード秘密情報を検出する" {
        $dir = Join-Path $TestDrive "secret"
        New-Item -ItemType Directory -Path $dir | Out-Null
        '$password = "SuperSecret1234"' | Set-Content -Path (Join-Path $dir "bad.ps1") -Encoding UTF8
        $result = Invoke-ArchitectureCheck -Path $dir
        $result.Violations.RuleId | Should -Contain "HARDCODED_SECRET"
        $result.Passed | Should -BeFalse
    }

    It "StrictMode 欠如を WARNING として検出する" {
        $dir = Join-Path $TestDrive "nostrict"
        New-Item -ItemType Directory -Path $dir | Out-Null
        'function Foo { }' | Set-Content -Path (Join-Path $dir "mod.psm1") -Encoding UTF8
        $result = Invoke-ArchitectureCheck -Path $dir
        $result.Violations.RuleId | Should -Contain "MISSING_STRICT_MODE"
        $result.Passed | Should -BeTrue
    }

    It "StrictMode が設定済みの場合は MISSING_STRICT_MODE を検出しない" {
        $dir = Join-Path $TestDrive "withstrict"
        New-Item -ItemType Directory -Path $dir | Out-Null
        "Set-StrictMode -Version Latest`nfunction Foo { }" | Set-Content -Path (Join-Path $dir "mod.psm1") -Encoding UTF8
        $result = Invoke-ArchitectureCheck -Path $dir
        ($result.Violations | Where-Object { $_.RuleId -eq "MISSING_STRICT_MODE" }).Count | Should -Be 0
    }

    It "結果オブジェクトに必須プロパティが含まれる" {
        $dir = Join-Path $TestDrive "props"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $result = Invoke-ArchitectureCheck -Path $dir
        $result.PSObject.Properties.Name | Should -Contain "CheckedFiles"
        $result.PSObject.Properties.Name | Should -Contain "TotalViolations"
        $result.PSObject.Properties.Name | Should -Contain "CriticalCount"
        $result.PSObject.Properties.Name | Should -Contain "WarningCount"
        $result.PSObject.Properties.Name | Should -Contain "Violations"
        $result.PSObject.Properties.Name | Should -Contain "Passed"
        $result.PSObject.Properties.Name | Should -Contain "Timestamp"
    }
}

Describe "Get-ArchitectureViolation" {
    It "Severity=CRITICAL で WARNING を返さない" {
        $dir = Join-Path $TestDrive "filter"
        New-Item -ItemType Directory -Path $dir | Out-Null
        '$secret = "hardcoded-password-123"' | Set-Content -Path (Join-Path $dir "mixed.psm1") -Encoding UTF8
        $result = @(Get-ArchitectureViolation -Path $dir -Severity "CRITICAL")
        @($result | Where-Object { $_.Severity -eq "WARNING" }).Count | Should -Be 0
    }

    It "Severity=WARNING で CRITICAL を返さない" {
        $dir = Join-Path $TestDrive "warnonly"
        New-Item -ItemType Directory -Path $dir | Out-Null
        'function Foo { }' | Set-Content -Path (Join-Path $dir "nowarn.psm1") -Encoding UTF8
        $result = @(Get-ArchitectureViolation -Path $dir -Severity "WARNING")
        @($result | Where-Object { $_.Severity -eq "CRITICAL" }).Count | Should -Be 0
    }

    It "Severity=ALL で全種別を返す" {
        $dir = Join-Path $TestDrive "allsev"
        New-Item -ItemType Directory -Path $dir | Out-Null
        '$secret = "hardcoded-password-123"' | Set-Content -Path (Join-Path $dir "all.psm1") -Encoding UTF8
        $result = @(Get-ArchitectureViolation -Path $dir -Severity "ALL")
        $result.Count | Should -BeGreaterThan 0
    }
}

Describe "プロジェクト構造整合性チェック" {
    It "scripts/lib/ の全 psm1 ファイルに対応するテストファイルが存在する" {
        $libPath = Join-Path $script:RepoRoot "scripts/lib"
        $testPath = Join-Path $script:RepoRoot "tests/unit"

        $modules = Get-ChildItem -Path $libPath -Filter "*.psm1" -ErrorAction SilentlyContinue
        $missing = @()

        foreach ($module in $modules) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($module.Name)
            $testFile = Join-Path $testPath "$baseName.Tests.ps1"
            if (-not (Test-Path $testFile)) {
                $missing += $baseName
            }
        }

        $missing | Should -BeNullOrEmpty -Because "scripts/lib/ の全 psm1 は対応するテストファイルが必要です。未対応: $($missing -join ', ')"
    }

    It "tests/unit/ の Tests.ps1 は全て scripts/ 内に対応する実装ファイルまたは設定ファイルが存在する" {
        $scriptsPath = Join-Path $script:RepoRoot "scripts"
        $testPath    = Join-Path $script:RepoRoot "tests/unit"

        # StateSchema はスキーマ JSON ファイルをテストするため PS スクリプトは不要
        $knownNonScriptTests = @("StateSchema")

        $testFiles = Get-ChildItem -Path $testPath -Filter "*.Tests.ps1" -ErrorAction SilentlyContinue
        $orphans = @()

        foreach ($testFile in $testFiles) {
            $baseName = $testFile.Name -replace '\.Tests\.ps1$', ''

            if ($baseName -in $knownNonScriptTests) {
                continue
            }

            # 命名正規化: ハイフンなし camelCase と hyphen-case を同一視 (例: StartCodex == Start-Codex)
            $normalizedBase = $baseName -replace '-', ''

            $found = Get-ChildItem -Path $scriptsPath -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $normalizedImpl = ($_.BaseName -replace '-', '')
                    $normalizedImpl -eq $normalizedBase
                }
            if (-not $found) {
                $orphans += $testFile.Name
            }
        }

        $orphans | Should -BeNullOrEmpty -Because "対応する実装ファイルのないテストファイルは孤立しています: $($orphans -join ', ')"
    }

    It "scripts/lib/ の独立 ps1 ファイルに対応するテストが存在する（dot-source 経由を除く）" {
        $libPath  = Join-Path $script:RepoRoot "scripts/lib"
        $testPath = Join-Path $script:RepoRoot "tests/unit"

        # Config.psm1 が dot-source で取り込む ps1 は Config.Tests.ps1 でカバー済み
        $dotSourcedByConfig = @("ConfigLoader", "ConfigSchema", "RecentProjects")

        $scripts = Get-ChildItem -Path $libPath -Filter "*.ps1" -ErrorAction SilentlyContinue
        $missing = @()

        foreach ($script in $scripts) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script.Name)

            if ($baseName -in $dotSourcedByConfig) {
                continue
            }

            $testFile = Join-Path $testPath "$baseName.Tests.ps1"
            if (-not (Test-Path $testFile)) {
                $missing += $baseName
            }
        }

        $missing | Should -BeNullOrEmpty -Because "scripts/lib/ の独立 ps1 は対応するテストファイルが必要です。未対応: $($missing -join ', ')"
    }
}

Describe "Show-ArchitectureCheckReport" {
    It "レポートを出力して結果オブジェクトを返す" {
        $dir = Join-Path $TestDrive "report"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $result = Show-ArchitectureCheckReport -Path $dir
        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties.Name | Should -Contain "Passed"
    }
}
