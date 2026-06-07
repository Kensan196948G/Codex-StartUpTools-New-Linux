Set-StrictMode -Version Latest

enum ErrorCategory {
    CONFIG_INVALID
    DEPENDENCY_MISSING
    TOOL_NOT_FOUND
    API_KEY_MISSING
    DRIVE_ACCESS
    PERMISSION_DENIED
    NETWORK_TIMEOUT
    FILE_SYSTEM
    PROCESS_MANAGEMENT
    CONFIG_MISMATCH
    LOG_OPERATION
    UNKNOWN
}

$script:CategoryEmoji = @{
    CONFIG_INVALID     = "CFG"
    DEPENDENCY_MISSING = "DEP"
    TOOL_NOT_FOUND     = "TOOL"
    API_KEY_MISSING    = "KEY"
    DRIVE_ACCESS       = "DRV"
    PERMISSION_DENIED  = "DENY"
    NETWORK_TIMEOUT    = "TIME"
    FILE_SYSTEM        = "FILE"
    PROCESS_MANAGEMENT = "PROC"
    CONFIG_MISMATCH    = "DIFF"
    LOG_OPERATION      = "LOG"
    UNKNOWN            = "ERR"
}

$script:CategorySolutions = @{
    CONFIG_INVALID = @(
        "1. config.json の JSON 構文を確認",
        "2. 必須フィールド version, projectsDir, tools を確認",
        "3. config.json.template と比較して不足項目を確認"
    )
    DEPENDENCY_MISSING = @(
        "1. 不足コマンドをインストール",
        "2. Node.js と PowerShell 実行環境を確認",
        "3. 診断スクリプトまたは単体テストで再確認"
    )
    TOOL_NOT_FOUND = @(
        "1. codex をインストール: npm install -g @openai/codex",
        "2. PATH と実行可能コマンドを確認"
    )
    API_KEY_MISSING = @(
        "1. 必要な API キーを取得",
        "2. 環境変数へ設定",
        "3. config と実行環境の参照先が一致しているか確認"
    )
    DRIVE_ACCESS = @(
        "1. 対象ドライブに到達できるか確認",
        "2. config の projectsDir / registeredProjects.roots を確認",
        "3. ネットワーク共有の権限を確認"
    )
    PERMISSION_DENIED = @(
        "1. PowerShell 権限を確認",
        "2. ファイル / ディレクトリ ACL を確認",
        "3. セキュリティソフトのブロック有無を確認"
    )
    NETWORK_TIMEOUT = @(
        "1. ネットワーク接続を確認",
        "2. ファイアウォールとポート設定を確認",
        "3. タイムアウト設定を見直す"
    )
    FILE_SYSTEM = @(
        "1. ファイル / ディレクトリの存在確認",
        "2. ディスク容量を確認",
        "3. 他プロセスによるロック有無を確認"
    )
    PROCESS_MANAGEMENT = @(
        "1. プロセス状態を確認: Get-Process",
        "2. 実行権限を確認",
        "3. 必要なら手動停止後に再実行"
    )
    CONFIG_MISMATCH = @(
        "1. config と実際の環境差分を確認",
        "2. config.json.template と比較",
        "3. 必要なら設定を再生成"
    )
    LOG_OPERATION = @(
        "1. ログディレクトリの書き込み権限を確認",
        "2. ディスク容量を確認",
        "3. 一時的に logging.enabled = false で切り分け"
    )
    UNKNOWN = @(
        "1. エラーメッセージ全文を確認",
        "2. 関連ログと直前の操作を確認",
        "3. 再現条件を絞り込む"
    )
}

function Show-CategorizedError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ErrorCategory]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [hashtable]$Details = @{},
        [bool]$ThrowAfter = $true
    )

    $emoji = $script:CategoryEmoji[$Category]
    $solutions = $script:CategorySolutions[$Category]

    Write-Host "`n==============================" -ForegroundColor Red
    Write-Host "$emoji Error Category: $Category" -ForegroundColor Yellow
    Write-Host "==============================`n" -ForegroundColor Red
    Write-Host "ERROR: $Message`n" -ForegroundColor Red

    if ($Details.Count -gt 0) {
        Write-Host "Details:" -ForegroundColor Yellow
        foreach ($key in $Details.Keys) {
            Write-Host "  $key : $($Details[$key])" -ForegroundColor White
        }
        Write-Host ""
    }

    Write-Host "Suggested Actions:" -ForegroundColor Cyan
    foreach ($solution in $solutions) {
        Write-Host "  $solution" -ForegroundColor White
    }
    Write-Host ""

    if ($ThrowAfter) {
        throw $Message
    }
}

function Get-ErrorCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    $message = $ErrorMessage.ToLower()

    if ($message -match "config\.json|invalid json|parse error|schema") {
        return [ErrorCategory]::CONFIG_INVALID
    }
    elseif ($message -match "api.?key|apikey|api_key") {
        return [ErrorCategory]::API_KEY_MISSING
    }
    elseif ($message -match "command not found|not installed|not recognized|jq|curl|npx|node") {
        return [ErrorCategory]::DEPENDENCY_MISSING
    }
    elseif ($message -match "codex.*not found|tool.*not found|which.*codex") {
        return [ErrorCategory]::TOOL_NOT_FOUND
    }
    elseif ($message -match "drive|unc path|network|x:\\|z:\\") {
        return [ErrorCategory]::DRIVE_ACCESS
    }
    elseif ($message -match "permission|access.*denied|unauthorized|forbidden") {
        return [ErrorCategory]::PERMISSION_DENIED
    }
    elseif ($message -match "timeout|timed out|unreachable") {
        return [ErrorCategory]::NETWORK_TIMEOUT
    }
    elseif ($message -match "\bfile\b|\bdirectory\b|\bfolder\b|write.*fail|read.*fail|\bpath\b.*not|見つかりません|存在しません|ファイル|ディレクトリ|パス") {
        return [ErrorCategory]::FILE_SYSTEM
    }
    elseif ($message -match "\bprocess\b|\bkill\b|stop-process|start-process|\bpid\b") {
        return [ErrorCategory]::PROCESS_MANAGEMENT
    }
    elseif ($message -match "mismatch|inconsistent|out of sync") {
        return [ErrorCategory]::CONFIG_MISMATCH
    }
    elseif ($message -match "\blog\b|\btranscript\b|\brotation\b|archive.*\blog\b") {
        return [ErrorCategory]::LOG_OPERATION
    }

    return [ErrorCategory]::UNKNOWN
}

function Show-Error {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [hashtable]$Details = @{},
        [bool]$ThrowAfter = $true
    )

    $category = Get-ErrorCategory -ErrorMessage $Message
    Show-CategorizedError -Category $category -Message $Message -Details $Details -ThrowAfter $ThrowAfter
}

Export-ModuleMember -Function @(
    "Show-CategorizedError",
    "Get-ErrorCategory",
    "Show-Error"
)
