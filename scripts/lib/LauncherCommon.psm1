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

function Get-RegisteredProjectRoots {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    if ($null -ne $registered -and $registered.PSObject.Properties["roots"]?.Value) {
        $roots = @($registered.roots | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
        if ($roots.Count -gt 0) {
            return $roots
        }
    }

    $projectsDir = $Config.PSObject.Properties["projectsDir"]?.Value
    if (-not [string]::IsNullOrWhiteSpace($projectsDir)) {
        return @("$projectsDir")
    }

    return @()
}

function Resolve-ProjectPath {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        return ""
    }

    foreach ($root in @(Get-RegisteredProjectRoots -Config $Config)) {
        $candidate = Join-Path $root $ProjectName
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $projectsDir = $Config.PSObject.Properties["projectsDir"]?.Value
    if (-not [string]::IsNullOrWhiteSpace($projectsDir)) {
        return (Join-Path $projectsDir $ProjectName)
    }

    return ""
}

function Resolve-CodexLaunchArguments {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [AllowNull()]
        [string[]]$Arguments
    )

    $resolved = @()
    foreach ($arg in @($Arguments)) {
        switch ($arg) {
            "--full-auto" {
                $resolved += "--dangerously-bypass-approvals-and-sandbox"
            }
            "--yolo" {
                $resolved += "--dangerously-bypass-approvals-and-sandbox"
            }
            default {
                $resolved += "$arg"
            }
        }
    }

    return @($resolved)
}

function ConvertTo-PosixShellArgument {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Start-NativeProcessWithArgumentList {
    [CmdletBinding()]
    [OutputType([System.Int32])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [AllowNull()]
        [string[]]$Arguments,

        [AllowNull()]
        [string]$WorkingDirectory = ""
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($arg in @($Arguments)) {
        [void]$startInfo.ArgumentList.Add($arg)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return [int]$process.ExitCode
}

function Invoke-InteractiveNativeCommand {
    [CmdletBinding()]
    [OutputType([System.Int32])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [AllowNull()]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    if (-not (Test-Path $WorkingDirectory)) {
        throw "作業ディレクトリが見つかりません: $WorkingDirectory"
    }

    $commandInfo = Get-Command $FilePath -ErrorAction Stop
    $commandPath = if ($commandInfo.PSObject.Properties.Name -contains "Source" -and $commandInfo.Source) {
        "$($commandInfo.Source)"
    }
    else {
        $FilePath
    }

    $scriptCommand = Get-Command "script" -ErrorAction SilentlyContinue
    if ([Console]::IsOutputRedirected -and $scriptCommand) {
        $parts = @(
            "cd",
            "--",
            (ConvertTo-PosixShellArgument -Value $WorkingDirectory),
            "&&",
            "exec",
            (ConvertTo-PosixShellArgument -Value $commandPath)
        )
        foreach ($arg in @($Arguments)) {
            $parts += (ConvertTo-PosixShellArgument -Value $arg)
        }

        return (Start-NativeProcessWithArgumentList `
            -FilePath $scriptCommand.Source `
            -Arguments @("-q", "-e", "-c", ($parts -join " "), "/dev/null"))
    }

    return (Start-NativeProcessWithArgumentList `
        -FilePath $commandPath `
        -Arguments @($Arguments) `
        -WorkingDirectory $WorkingDirectory)
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
    "Get-RegisteredProjectRoots",
    "Resolve-ProjectPath",
    "Resolve-CodexLaunchArguments",
    "ConvertTo-PosixShellArgument",
    "Invoke-InteractiveNativeCommand",
    "Find-AvailableDriveLetter",
    "Get-LauncherModeName",
    "Get-LauncherShell"
)
