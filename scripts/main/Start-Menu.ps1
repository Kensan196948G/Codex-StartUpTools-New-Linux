Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/LauncherCommon.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $script:StartupRoot "scripts/lib/Config.psm1")         -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/StartupMenu.psm1")    -Force

try {
    $configPath = Get-StartupConfigPath -StartupRoot $script:StartupRoot
    $config     = Import-LauncherConfig -ConfigPath $configPath

    $statePath = if ($env:AI_STARTUP_STATE_PATH) {
        $env:AI_STARTUP_STATE_PATH
    } else {
        Join-Path $script:StartupRoot "state.json"
    }

    Start-InteractiveMenu `
        -Config      $config `
        -ProjectRoot $script:StartupRoot `
        -StatePath   $statePath `
        -ConfigPath  $configPath
}
catch {
    Write-Host ""
    Write-Host "  [ERROR] メニュー起動に失敗しました:" -ForegroundColor Red
    Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ""
    exit 1
}
