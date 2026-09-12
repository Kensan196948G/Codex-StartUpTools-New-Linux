BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/LogManager.psm1") -Force

    function script:New-TestLogConfig {
        param(
            [string]$LogDir,
            [string]$Prefix = "testlog",
            [int]$SuccessKeepDays = 30,
            [int]$FailureKeepDays = 90,
            [int]$LegacyKeepDays = 7,
            [int]$ArchiveAfterDays = 60
        )

        return [pscustomobject]@{
            logging = [pscustomobject]@{
                enabled          = $true
                logDir           = $LogDir
                logPrefix        = $Prefix
                successKeepDays  = $SuccessKeepDays
                failureKeepDays  = $FailureKeepDays
                legacyKeepDays   = $LegacyKeepDays
                archiveAfterDays = $ArchiveAfterDays
            }
        }
    }
}

Describe "Start-SessionLog" {
    It "TEMP 未設定でも利用できないログ先から一時ディレクトリへ退避する" {
        $originalTemp = $env:TEMP
        $unavailable = Join-Path $TestDrive "file-not-directory"
        "occupied" | Set-Content $unavailable
        Mock Start-Transcript -ModuleName LogManager { }
        Mock Stop-Transcript -ModuleName LogManager { }
        try {
            Remove-Item Env:TEMP -ErrorAction SilentlyContinue
            $result = Start-SessionLog -Config (New-TestLogConfig -LogDir $unavailable) -ProjectName "fallback"
            [System.IO.Path]::GetDirectoryName($result.LogPath) | Should -Be ([System.IO.Path]::GetTempPath().TrimEnd('/'))
            Should -Invoke Start-Transcript -ModuleName LogManager -Times 1
        }
        finally {
            Stop-SessionLog -Success $true
            $env:TEMP = $originalTemp
        }
    }
}

Describe "Get-LogSummary" {
    It "空ディレクトリでは 0 件を返す" {
        $logDir = Join-Path $TestDrive "empty-logs"
        New-Item -ItemType Directory -Path $logDir | Out-Null
        $summary = Get-LogSummary -Config (New-TestLogConfig -LogDir $logDir)
        $summary.TotalFiles | Should -Be 0
        $summary.SuccessCount | Should -Be 0
        $summary.FailureCount | Should -Be 0
    }

    It "SUCCESS / FAILURE / legacy を別々に数える" {
        $logDir = Join-Path $TestDrive "mixed-logs"
        New-Item -ItemType Directory -Path $logDir | Out-Null
        "x" | Set-Content (Join-Path $logDir "testlog-a-SUCCESS.log")
        "x" | Set-Content (Join-Path $logDir "testlog-b-FAILURE.log")
        "x" | Set-Content (Join-Path $logDir "testlog-c-legacy.log")

        $summary = Get-LogSummary -Config (New-TestLogConfig -LogDir $logDir)
        $summary.TotalFiles | Should -Be 3
        $summary.SuccessCount | Should -Be 1
        $summary.FailureCount | Should -Be 1
        $summary.LegacyCount | Should -Be 1
    }
}

Describe "Invoke-LogRotation" {
    It "古い SUCCESS ログを削除する" {
        $logDir = Join-Path $TestDrive "rotate-success"
        New-Item -ItemType Directory -Path $logDir | Out-Null
        $old = Join-Path $logDir "testlog-old-SUCCESS.log"
        $recent = Join-Path $logDir "testlog-recent-SUCCESS.log"
        "x" | Set-Content $old
        "x" | Set-Content $recent
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-31)
        (Get-Item $recent).LastWriteTime = (Get-Date).AddDays(-1)

        Invoke-LogRotation -Config (New-TestLogConfig -LogDir $logDir -SuccessKeepDays 30)
        (Test-Path $old) | Should -BeFalse
        (Test-Path $recent) | Should -BeTrue
    }

    It "古い legacy ログを削除する" {
        $logDir = Join-Path $TestDrive "rotate-legacy"
        New-Item -ItemType Directory -Path $logDir | Out-Null
        $old = Join-Path $logDir "testlog-old-legacy.log"
        $recent = Join-Path $logDir "testlog-recent-legacy.log"
        "x" | Set-Content $old
        "x" | Set-Content $recent
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-8)
        (Get-Item $recent).LastWriteTime = (Get-Date).AddDays(-1)

        Invoke-LogRotation -Config (New-TestLogConfig -LogDir $logDir -LegacyKeepDays 7)
        (Test-Path $old) | Should -BeFalse
        (Test-Path $recent) | Should -BeTrue
    }
}
