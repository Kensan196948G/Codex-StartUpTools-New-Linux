Set-StrictMode -Version Latest

function Import-StartupConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "設定ファイルが見つかりません: $ConfigPath"
    }

    try {
        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $config = $content | ConvertFrom-Json
        Write-Host "[INFO]  設定ファイル読み込み: $ConfigPath" -ForegroundColor Cyan
    }
    catch {
        throw "config.jsonのJSONパースに失敗しました: $_"
    }

    foreach ($field in $script:RequiredFields) {
        $value = $config.PSObject.Properties[$field]?.Value
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "config.jsonに必須フィールドがありません: '$field'"
        }
    }

    Write-Host "[ OK ]  必須フィールド検証OK" -ForegroundColor Green

    foreach ($toolName in @("codex")) {
        $toolConfig = if ($null -ne $config.tools) {
            $config.tools.PSObject.Properties[$toolName]?.Value
        }
        else {
            $null
        }

        if ($null -ne $toolConfig) {
            if ($null -eq $toolConfig.PSObject.Properties["enabled"]?.Value) {
                Write-Warning "tools.$toolName.enabled が未設定です"
            }

            if ($null -eq $toolConfig.PSObject.Properties["command"]?.Value) {
                Write-Warning "tools.$toolName.command が未設定です"
            }
        }
    }

    Write-Host "[ OK ]  Codex 設定検証OK" -ForegroundColor Green
    return $config
}

function Import-DevToolsConfig {
    param([string]$ConfigPath)

    Import-StartupConfig -ConfigPath $ConfigPath
}

function Backup-ConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [int]$MaxBackups = 10,
        [bool]$MaskSensitive = $true,
        [string[]]$SensitiveKeys = @()
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "バックアップ元ファイルが見つかりません: $ConfigPath"
        return
    }

    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $extension = [System.IO.Path]::GetExtension($ConfigPath)
    $backupFile = Join-Path $BackupDir "${baseName}_${timestamp}${extension}"

    try {
        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8

        if ($MaskSensitive -and $SensitiveKeys.Count -gt 0) {
            try {
                $json = $content | ConvertFrom-Json

                foreach ($keyPath in $SensitiveKeys) {
                    $parts = $keyPath -split "\."
                    $object = $json

                    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                        $propertyValue = $object.PSObject.Properties[$parts[$i]]?.Value
                        if ($null -ne $propertyValue) {
                            $object = $propertyValue
                        }
                    }

                    $lastKey = $parts[-1]
                    $lastProperty = $object.PSObject.Properties[$lastKey]
                    if ($null -ne $object -and $null -ne $lastProperty -and $lastProperty.Value -ne "") {
                        $object.$lastKey = "***MASKED***"
                    }
                }

                $content = $json | ConvertTo-Json -Depth 10
            }
            catch {
                Write-Warning "機密情報マスキング中にエラー（マスクなしでバックアップ）: $_"
            }
        }

        Set-Content -Path $backupFile -Value $content -Encoding UTF8
        Write-Host "[INFO]  設定バックアップ作成: $backupFile" -ForegroundColor Cyan

        $pattern = "${baseName}_*${extension}"
        $backups = @(Get-ChildItem -Path $BackupDir -Filter $pattern | Sort-Object LastWriteTime -Descending)
        if ($backups.Count -gt $MaxBackups) {
            $toDelete = $backups | Select-Object -Skip $MaxBackups
            foreach ($oldBackup in $toDelete) {
                Remove-Item -Path $oldBackup.FullName -Force
                Write-Host "[INFO]  古いバックアップ削除: $($oldBackup.Name)" -ForegroundColor Cyan
            }
        }
    }
    catch {
        Write-Warning "バックアップ作成中にエラーが発生しました: $_"
    }
}
