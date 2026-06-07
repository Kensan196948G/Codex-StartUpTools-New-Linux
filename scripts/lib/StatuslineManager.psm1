Set-StrictMode -Version Latest

function Get-GlobalStatusLineConfig {
    param([string]$SettingsPath = "")

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $homePath = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
        $SettingsPath = Join-Path $homePath ".codex/settings.json"
    }

    if (-not (Test-Path $SettingsPath)) {
        return [pscustomobject]@{
            found      = $false
            path       = $SettingsPath
            statusLine = $null
            raw        = $null
        }
    }

    try {
        $content = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $statusLine = if ($content.PSObject.Properties.Name -contains "statusLine") { $content.statusLine } else { $null }
        return [pscustomobject]@{
            found      = $true
            path       = $SettingsPath
            statusLine = $statusLine
            raw        = $content
        }
    }
    catch {
        throw "設定ファイルの解析に失敗しました: $SettingsPath ($($_.Exception.Message))"
    }
}

Export-ModuleMember -Function Get-GlobalStatusLineConfig
