Set-StrictMode -Version Latest

$script:CurrentLogPath = $null
$script:LoggingActive = $false

function Start-SessionLog {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [string]$ToolName = "ai-tool"
    )

    if (-not $Config.PSObject.Properties["logging"] -or -not $Config.logging.enabled) {
        $script:LoggingActive = $false
        return @{ LogPath = $null }
    }

    $logging = $Config.logging
    $prefix = if ($logging.logPrefix) { $logging.logPrefix } else { "codex-startup" }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $processSuffix = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $fileName = "$prefix-$ProjectName-$ToolName-$timestamp-$processSuffix.log"

    $logDir = $logging.logDir
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $testFile = Join-Path $logDir ".write-test-$([guid]::NewGuid().ToString('N'))"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force
    }
    catch {
        Write-Warning "ログディレクトリにアクセスできません: $logDir → OS の一時ディレクトリにフォールバック"
        $logDir = [System.IO.Path]::GetTempPath()
    }

    $logPath = Join-Path $logDir $fileName

    try {
        Start-Transcript -Path $logPath -Append -ErrorAction Stop | Out-Null
        $script:CurrentLogPath = $logPath
        $script:LoggingActive = $true
    }
    catch {
        Write-Warning "Start-Transcript 失敗: $_"
        $script:LoggingActive = $false
        return @{ LogPath = $null }
    }

    return @{ LogPath = $logPath }
}

function Stop-SessionLog {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Success
    )

    if (-not $script:LoggingActive -or $null -eq $script:CurrentLogPath) {
        return
    }

    try {
        Stop-Transcript -ErrorAction SilentlyContinue
    }
    catch {
        Write-Debug "Stop-Transcript skipped (no active transcript): $_"
    }

    $script:LoggingActive = $false

    if (Test-Path $script:CurrentLogPath) {
        $suffix = if ($Success) { "SUCCESS" } else { "FAILURE" }
        $directory = [System.IO.Path]::GetDirectoryName($script:CurrentLogPath)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentLogPath)
        $extension = [System.IO.Path]::GetExtension($script:CurrentLogPath)
        $newName = "${baseName}-${suffix}${extension}"
        $newPath = Join-Path $directory $newName

        try {
            Rename-Item -Path $script:CurrentLogPath -NewName $newName -Force
            Write-Host "Log closed: $newPath" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "ログファイルのリネームに失敗しました: $_"
        }
    }

    $script:CurrentLogPath = $null
}

function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    if ($null -eq $Config.logging -or $Config.logging.enabled -ne $true) {
        return
    }

    $logConfig = $Config.logging
    $logDir = $logConfig.logDir
    if (-not (Test-Path $logDir)) {
        return
    }

    $now = Get-Date
    $prefix = if ($logConfig.logPrefix) { $logConfig.logPrefix } else { "codex-startup" }
    $legacyKeepDays = if ($null -ne $logConfig.PSObject.Properties["legacyKeepDays"]?.Value) { $logConfig.legacyKeepDays } else { 7 }
    $defaultKeepDays = 7

    Get-ChildItem -Path $logDir -Filter "${prefix}-*.log" -File | ForEach-Object {
        $age = ($now - $_.LastWriteTime).Days
        $name = $_.Name

        if ($name -match "-SUCCESS\.log$") {
            if ($age -gt $logConfig.successKeepDays) {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "ログ削除失敗: $name - $_"
                }
            }
        }
        elseif ($name -match "-FAILURE\.log$") {
            if ($age -gt $logConfig.failureKeepDays) {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "ログ削除失敗: $name - $_"
                }
            }
        }
        else {
            if ($age -gt $legacyKeepDays) {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "ログ削除失敗: $name - $_"
                }
            }
        }
    }

    foreach ($pattern in @("menu-error-*.log", "menu-launch-*.log", "launch-metadata-*.jsonl")) {
        Get-ChildItem -Path $logDir -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            $age = ($now - $_.LastWriteTime).Days
            if ($age -gt $defaultKeepDays) {
                try {
                    Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                }
                catch {
                    Write-Warning "ログ削除失敗: $($_.Name) - $_"
                }
            }
        }
    }
}

function Invoke-LogArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    if ($null -eq $Config.logging -or $Config.logging.enabled -ne $true) {
        return
    }

    $logConfig = $Config.logging
    $logDir = $logConfig.logDir
    if (-not (Test-Path $logDir)) {
        return
    }

    $archiveAfterDays = if ($null -ne $logConfig.PSObject.Properties["archiveAfterDays"]?.Value) { $logConfig.archiveAfterDays } else { 60 }
    $now = Get-Date
    $prefix = if ($logConfig.logPrefix) { $logConfig.logPrefix } else { "codex-startup" }
    $archiveDir = Join-Path $logDir "archive"

    $toArchive = @(Get-ChildItem -Path $logDir -Filter "${prefix}-*.log" -File | Where-Object {
        ($now - $_.LastWriteTime).Days -gt $archiveAfterDays
    })

    if ($toArchive.Count -eq 0) {
        return
    }

    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    $monthGroups = $toArchive | Group-Object { $_.LastWriteTime.ToString("yyyy-MM") }
    foreach ($group in $monthGroups) {
        $zipName = "$($group.Name).zip"
        $zipPath = Join-Path $archiveDir $zipName

        try {
            Compress-Archive -Path ($group.Group | Select-Object -ExpandProperty FullName) -DestinationPath $zipPath -Update -ErrorAction Stop
            foreach ($file in $group.Group) {
                Remove-Item -Path $file.FullName -Force
            }
        }
        catch {
            Write-Warning "ログアーカイブに失敗しました ($zipName): $_"
        }
    }
}

function Get-LogSummary {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config
    )

    $result = @{
        TotalFiles     = 0
        SuccessCount   = 0
        FailureCount   = 0
        LegacyCount    = 0
        TotalSizeBytes = 0
        OldestLog      = $null
        NewestLog      = $null
    }

    if ($null -eq $Config.logging) {
        return $result
    }

    $logDir = $Config.logging.logDir
    if (-not $logDir -or -not (Test-Path $logDir)) {
        return $result
    }

    $prefix = if ($Config.logging.logPrefix) { $Config.logging.logPrefix } else { "codex-startup" }
    $files = @(Get-ChildItem -Path $logDir -Filter "${prefix}-*.log" -File)
    if ($files.Count -eq 0) {
        return $result
    }

    $result.TotalFiles = $files.Count
    $result.TotalSizeBytes = ($files | Measure-Object -Property Length -Sum).Sum

    foreach ($file in $files) {
        if ($file.Name -match "-SUCCESS\.log$") {
            $result.SuccessCount++
        }
        elseif ($file.Name -match "-FAILURE\.log$") {
            $result.FailureCount++
        }
        else {
            $result.LegacyCount++
        }
    }

    $sorted = $files | Sort-Object LastWriteTime
    $result.OldestLog = $sorted[0].Name
    $result.NewestLog = $sorted[-1].Name

    return $result
}

Export-ModuleMember -Function @(
    "Start-SessionLog",
    "Stop-SessionLog",
    "Invoke-LogRotation",
    "Invoke-LogArchive",
    "Get-LogSummary"
)
