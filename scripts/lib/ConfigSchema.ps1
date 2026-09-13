Set-StrictMode -Version Latest

$script:RequiredFields = @("version", "projectsDir", "tools")
$script:TemplateRequiredFields = @("version", "projectsDir", "registeredProjects", "tools", "supervisor")
$script:TemplateToolRequiredFields = @{
    codex = @("enabled", "command", "args", "installCommand", "env", "apiKeyEnvVar")
}
$script:AllowedDefaultTools = @("codex")

function Test-IntegerValueInRange {
    param(
        [object]$Value,
        [int]$Minimum,
        [int]$Maximum = [int]::MaxValue
    )

    if ($null -eq $Value) {
        return $false
    }

    try {
        $number = [int64]$Value
    }
    catch {
        return $false
    }

    return ($number -ge $Minimum -and $number -le $Maximum)
}

function Add-SchemaError {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Errors.Add($Message)
}

function Test-StartupConfigSchema {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ($Config -is [System.Collections.Hashtable]) {
        $Config = $Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($field in $script:TemplateRequiredFields) {
        $value = $Config.PSObject.Properties[$field]?.Value
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            Add-SchemaError -Errors $errors -Message "必須フィールドが不足しています: $field"
        }
    }

    $configTools = $Config.PSObject.Properties["tools"]?.Value
    if ($null -eq $configTools) {
        Add-SchemaError -Errors $errors -Message "必須フィールドが不足しています: tools"
        return @($errors)
    }

    $defaultTool = $configTools.PSObject.Properties["defaultTool"]?.Value
    if ([string]::IsNullOrWhiteSpace($defaultTool)) {
        Add-SchemaError -Errors $errors -Message "必須フィールドが不足しています: tools.defaultTool"
    }
    elseif ($defaultTool -notin $script:AllowedDefaultTools) {
        Add-SchemaError -Errors $errors -Message "tools.defaultTool は codex である必要があります"
    }

    foreach ($pathField in @("projectsDir")) {
        $value = $Config.PSObject.Properties[$pathField]?.Value
        if ($null -ne $value -and $value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "$pathField は文字列である必要があります"
        }
    }

    foreach ($toolName in $script:TemplateToolRequiredFields.Keys) {
        $toolConfig = $configTools.PSObject.Properties[$toolName]?.Value
        if ($null -eq $toolConfig) {
            Add-SchemaError -Errors $errors -Message "必須フィールドが不足しています: tools.$toolName"
            continue
        }

        foreach ($field in $script:TemplateToolRequiredFields[$toolName]) {
            $value = $toolConfig.PSObject.Properties[$field]?.Value
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                Add-SchemaError -Errors $errors -Message "必須フィールドが不足しています: tools.$toolName.$field"
            }
        }

        $tcEnabled = $toolConfig.PSObject.Properties["enabled"]?.Value
        $tcCommand = $toolConfig.PSObject.Properties["command"]?.Value
        $tcArgs = $toolConfig.PSObject.Properties["args"]?.Value
        $tcInstallCommand = $toolConfig.PSObject.Properties["installCommand"]?.Value
        $tcEnv = $toolConfig.PSObject.Properties["env"]?.Value
        $tcApiKeyEnvVar = $toolConfig.PSObject.Properties["apiKeyEnvVar"]?.Value

        if ($tcEnabled -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.enabled は boolean である必要があります"
        }
        if ($tcCommand -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.command は文字列である必要があります"
        }
        if ($tcArgs -isnot [System.Array]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.args は配列である必要があります"
        }
        if ($tcInstallCommand -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.installCommand は文字列である必要があります"
        }
        if ($null -eq $tcEnv -or $tcEnv -is [string] -or $tcEnv -is [System.Array]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.env はオブジェクトである必要があります"
        }
        if ($tcApiKeyEnvVar -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "tools.$toolName.apiKeyEnvVar は文字列である必要があります"
        }
    }

    $registeredProjects = $Config.PSObject.Properties["registeredProjects"]?.Value
    if ($null -ne $registeredProjects) {
        if ($registeredProjects.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "registeredProjects.enabled は boolean である必要があります"
        }
        $roots = $registeredProjects.PSObject.Properties["roots"]?.Value
        if ($null -eq $roots -or $roots -isnot [System.Array] -or @($roots).Count -eq 0) {
            Add-SchemaError -Errors $errors -Message "registeredProjects.roots は 1 件以上の配列である必要があります"
        }
        if ($null -ne $registeredProjects.PSObject.Properties["include"]?.Value -and $registeredProjects.PSObject.Properties["include"]?.Value -isnot [System.Array]) {
            Add-SchemaError -Errors $errors -Message "registeredProjects.include は配列である必要があります"
        }
        if ($null -ne $registeredProjects.PSObject.Properties["exclude"]?.Value -and $registeredProjects.PSObject.Properties["exclude"]?.Value -isnot [System.Array]) {
            Add-SchemaError -Errors $errors -Message "registeredProjects.exclude は配列である必要があります"
        }
        if ($null -ne $registeredProjects.PSObject.Properties["categories"]?.Value) {
            $categories = $registeredProjects.PSObject.Properties["categories"].Value
            if ($categories -isnot [pscustomobject]) {
                Add-SchemaError -Errors $errors -Message "registeredProjects.categories はオブジェクトである必要があります"
            }
            else {
                foreach ($category in @($categories.PSObject.Properties)) {
                    if ($category.Value -isnot [System.Array]) {
                        Add-SchemaError -Errors $errors -Message "registeredProjects.categories.$($category.Name) は配列である必要があります"
                    }
                }
            }
        }
        if ($null -ne $registeredProjects.PSObject.Properties["maxCandidates"]?.Value -and -not (Test-IntegerValueInRange -Value $registeredProjects.PSObject.Properties["maxCandidates"]?.Value -Minimum 1 -Maximum 1000)) {
            Add-SchemaError -Errors $errors -Message "registeredProjects.maxCandidates は 1 から 1000 の整数である必要があります"
        }
    }

    $supervisor = $Config.PSObject.Properties["supervisor"]?.Value
    if ($null -ne $supervisor) {
        if ($supervisor.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "supervisor.enabled は boolean である必要があります"
        }
        if ($supervisor.PSObject.Properties["applyToRegisteredProjects"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "supervisor.applyToRegisteredProjects は boolean である必要があります"
        }
        if ($null -ne $supervisor.PSObject.Properties["mode"]?.Value -and $supervisor.PSObject.Properties["mode"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "supervisor.mode は文字列である必要があります"
        }
        if ($null -ne $supervisor.PSObject.Properties["humanDecisionRequired"]?.Value -and $supervisor.PSObject.Properties["humanDecisionRequired"]?.Value -isnot [System.Array]) {
            Add-SchemaError -Errors $errors -Message "supervisor.humanDecisionRequired は配列である必要があります"
        }
    }

    $recentProjects = $Config.PSObject.Properties["recentProjects"]?.Value
    if ($null -ne $recentProjects) {
        if ($recentProjects.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "recentProjects.enabled は boolean である必要があります"
        }
        if (-not (Test-IntegerValueInRange -Value $recentProjects.PSObject.Properties["maxHistory"]?.Value -Minimum 1)) {
            Add-SchemaError -Errors $errors -Message "recentProjects.maxHistory は 1 以上の整数である必要があります"
        }
        if ($recentProjects.PSObject.Properties["historyFile"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "recentProjects.historyFile は文字列である必要があります"
        }
    }

    $logging = $Config.PSObject.Properties["logging"]?.Value
    if ($null -ne $logging) {
        if ($logging.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "logging.enabled は boolean である必要があります"
        }
        if ($null -ne $logging.PSObject.Properties["logDir"]?.Value -and $logging.PSObject.Properties["logDir"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "logging.logDir は文字列である必要があります"
        }
        if ($null -ne $logging.PSObject.Properties["logPrefix"]?.Value -and $logging.PSObject.Properties["logPrefix"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "logging.logPrefix は文字列である必要があります"
        }
        if ($null -ne $logging.PSObject.Properties["successKeepDays"]?.Value -and -not (Test-IntegerValueInRange -Value $logging.PSObject.Properties["successKeepDays"]?.Value -Minimum 1 -Maximum 3650)) {
            Add-SchemaError -Errors $errors -Message "logging.successKeepDays は 1 から 3650 の整数である必要があります"
        }
        if ($null -ne $logging.PSObject.Properties["failureKeepDays"]?.Value -and -not (Test-IntegerValueInRange -Value $logging.PSObject.Properties["failureKeepDays"]?.Value -Minimum 1 -Maximum 3650)) {
            Add-SchemaError -Errors $errors -Message "logging.failureKeepDays は 1 から 3650 の整数である必要があります"
        }
    }

    $backupConfig = $Config.PSObject.Properties["backupConfig"]?.Value
    if ($null -ne $backupConfig) {
        if ($null -ne $backupConfig.PSObject.Properties["enabled"]?.Value -and $backupConfig.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "backupConfig.enabled は boolean である必要があります"
        }
        if ($null -ne $backupConfig.PSObject.Properties["backupDir"]?.Value -and $backupConfig.PSObject.Properties["backupDir"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "backupConfig.backupDir は文字列である必要があります"
        }
        if ($null -ne $backupConfig.PSObject.Properties["maxBackups"]?.Value -and -not (Test-IntegerValueInRange -Value $backupConfig.PSObject.Properties["maxBackups"]?.Value -Minimum 1 -Maximum 1000)) {
            Add-SchemaError -Errors $errors -Message "backupConfig.maxBackups は 1 から 1000 の整数である必要があります"
        }
        if ($null -ne $backupConfig.PSObject.Properties["maskSensitive"]?.Value -and $backupConfig.PSObject.Properties["maskSensitive"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "backupConfig.maskSensitive は boolean である必要があります"
        }
        if ($null -ne $backupConfig.PSObject.Properties["sensitiveKeys"]?.Value -and $backupConfig.PSObject.Properties["sensitiveKeys"]?.Value -isnot [System.Array]) {
            Add-SchemaError -Errors $errors -Message "backupConfig.sensitiveKeys は配列である必要があります"
        }
    }

    $orchestration = $Config.PSObject.Properties["orchestration"]?.Value
    if ($null -ne $orchestration) {
        if ($orchestration.PSObject.Properties["enabled"]?.Value -isnot [bool]) {
            Add-SchemaError -Errors $errors -Message "orchestration.enabled は boolean である必要があります"
        }
        if ($null -ne $orchestration.PSObject.Properties["connectionEnvVar"]?.Value -and $orchestration.PSObject.Properties["connectionEnvVar"]?.Value -isnot [string]) {
            Add-SchemaError -Errors $errors -Message "orchestration.connectionEnvVar は文字列である必要があります"
        }
        $fallback = $orchestration.PSObject.Properties["fallback"]?.Value
        if ($null -ne $fallback) {
            if ($null -ne $fallback.PSObject.Properties["mode"]?.Value -and $fallback.PSObject.Properties["mode"]?.Value -isnot [string]) {
                Add-SchemaError -Errors $errors -Message "orchestration.fallback.mode は文字列である必要があります"
            }
            if ($null -ne $fallback.PSObject.Properties["dir"]?.Value -and $fallback.PSObject.Properties["dir"]?.Value -isnot [string]) {
                Add-SchemaError -Errors $errors -Message "orchestration.fallback.dir は文字列である必要があります"
            }
        }
    }

    return @($errors)
}

function Assert-StartupConfigSchema {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
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
    }
    catch {
        throw "config.jsonのJSONパースに失敗しました: $_"
    }

    $errors = @(Test-StartupConfigSchema -Config $config)
    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    return $true
}
