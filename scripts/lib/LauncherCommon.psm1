Set-StrictMode -Version Latest

function Get-StartupRoot {
    param(
        [Parameter(Mandatory)]
        [string]$PSScriptRootPath
    )

    return (Split-Path -Parent (Split-Path -Parent $PSScriptRootPath))
}

function Get-StartupConfigPath {
    param(
        [Parameter(Mandatory)]
        [string]$StartupRoot
    )

    if ($env:AI_STARTUP_CONFIG_PATH) {
        return $env:AI_STARTUP_CONFIG_PATH
    }

    return (Join-Path $StartupRoot "config/config.json")
}

function Import-LauncherConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "設定ファイルが見つかりません: $ConfigPath"
    }

    return (Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Find-AvailableDriveLetter {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string[]]$PreferredLetters = @("P", "Q", "R", "S", "T", "U", "V", "W", "Y"),
        [string[]]$ExcludeLetters = @()
    )

    $usedLetters = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)

    foreach ($letter in $PreferredLetters) {
        if ($letter -notin $usedLetters -and $letter -notin $ExcludeLetters) {
            return $letter
        }
    }

    for ($code = [int][char]"Z"; $code -ge [int][char]"D"; $code--) {
        $letter = [char]$code
        if ("$letter" -notin $usedLetters -and "$letter" -notin $ExcludeLetters) {
            return "$letter"
        }
    }

    return $null
}

function Get-LauncherModeName {
    return "local"
}

function Get-LauncherShell {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        return "pwsh"
    }

    return "pwsh"
}

Export-ModuleMember -Function @(
    "Get-StartupRoot",
    "Get-StartupConfigPath",
    "Import-LauncherConfig",
    "Find-AvailableDriveLetter",
    "Get-LauncherModeName",
    "Get-LauncherShell"
)
