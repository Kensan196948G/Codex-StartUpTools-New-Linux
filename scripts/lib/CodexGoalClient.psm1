Set-StrictMode -Version Latest

# ============================================================
# CodexGoalClient.psm1 — Codex ネイティブ Goal の非対話クライアント
#
# 役割:
#   `codex exec` には `--goal` フラグが存在しない (0.154.0 実測)。
#   非対話・cron・CI から Codex ネイティブ Goal (永続 + 自動継続) を使うため、
#   `codex app-server` の JSON-RPC (stdio) を叩く唯一の正規路をここへ集約する。
#
# 検証済みメソッド (codex-cli 0.153.4 / 0.154.0 で往復確認):
#     initialize         ハンドシェイク
#     thread/start       スレッド作成        -> thread.id
#     thread/resume      既存スレッド読込     (既存スレッドへ Goal を張る前に必要)
#     thread/goal/set    Goal 設定          -> goal
#     thread/goal/get    Goal 取得          -> goal
#     thread/goal/clear  Goal 削除          -> { cleared: true }
#   通知: thread/goal/updated, thread/goal/cleared
#
# 重要 (実測で判明した設計制約):
#   スレッドは app-server **プロセス**が所有する。プロセスを跨いで
#   「thread/start した直後に別プロセスの thread/goal/set」をすると
#   `thread not found` になる。したがって
#     - 新規作成 + Goal 設定は 1 プロセス内で完結させる (Start-CodexGoalRun)
#     - 既存スレッドへ設定する場合は先に thread/resume する (Set-CodexThreadGoal)
#   このためトランスポートは「1 接続 = 1 セッション」モデルにしている。
#
# 設計:
#   - 純粋関数 (検証 / テンプレ抽出 / JSON-RPC フレーム生成・解析) と
#     セッション入出力 (New/Invoke/Close-CodexGoalSession) を分離する。
#     高レベル関数はセッション関数をモジュール内関数として呼ぶため、Pester では
#     `Mock Invoke-CodexGoalSessionRpc` でプロセス無しに検証できる。
#   - objective の上限は Codex 仕様の 4,000 文字。判定は「文字数」であり
#     UTF-8 バイト数ではない (日本語は 1 文字 3 バイトのため取り違えやすい)。
#   - 失敗時は例外を投げ、呼び出し側 (Launcher / cron) が fail-safe で
#     Goal 無し起動へ降格できるようにする。
# ============================================================

$script:GoalObjectiveMaxLength = 4000
$script:DefaultRpcTimeoutSec = 60
$script:DefaultCodexCommand = "codex"
$script:RpcClientName = "codex-startup-goal"

function Get-CodexGoalObjectiveMaxLength {
    <#
    .SYNOPSIS
        Codex Goal objective の最大文字数 (Codex 仕様)。
    #>
    return $script:GoalObjectiveMaxLength
}

function Test-CodexPropertyExists {
    <#
    .SYNOPSIS
        オブジェクトが指定プロパティ/キーを持つか判定する (内部ヘルパ)。
    .DESCRIPTION
        ConvertFrom-Json の結果は PSCustomObject、テストのモックは Hashtable になり得る。
        `$obj.PSObject.Properties.Name` は Hashtable ではキーを返さないため、
        IDictionary を先に見てから PSObject を見る。
    #>
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return [bool]($InputObject.PSObject.Properties.Name -contains $Name)
}

function Test-CodexGoalObjective {
    <#
    .SYNOPSIS
        objective が Codex の受理条件 (非空 / 4,000 文字以内) を満たすか判定する。
    .DESCRIPTION
        長さは .NET string の Length = UTF-16 コード単位 = 文字数で判定する。
        バイト数で判定すると日本語テンプレートを誤って超過扱いする。
    #>
    param(
        [AllowEmptyString()]
        [string]$Objective
    )

    $length = if ($null -eq $Objective) { 0 } else { $Objective.Length }

    if ([string]::IsNullOrWhiteSpace($Objective)) {
        return [pscustomobject]@{
            Valid  = $false
            Length = $length
            Reason = "objective-empty"
        }
    }

    if ($length -gt $script:GoalObjectiveMaxLength) {
        return [pscustomobject]@{
            Valid  = $false
            Length = $length
            Reason = "objective-too-long"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Length = $length
        Reason = "ok"
    }
}

function Get-CodexGoalObjectiveFromTemplate {
    <#
    .SYNOPSIS
        goals/*.md テンプレートから `/goal "` 〜 閉じ `"` ブロックの本文を抽出する。
    .DESCRIPTION
        ClaudeOS 由来テンプレートの規約 (開き `/goal "` 行、閉じは単独 `"` 行) を踏襲する。
        閉じ `"` が欠落した不完全ブロックは非破壊で失敗させ、呼び出し側を fallback に落とす。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "goal template not found: $Path"
    }

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $openIndex = -1
    $closeIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($openIndex -lt 0) {
            if ($lines[$i] -match '/goal[ \t]*"') {
                $openIndex = $i
            }
            continue
        }

        if ($lines[$i] -match '^[ \t]*"[ \t]*$') {
            $closeIndex = $i
            break
        }
    }

    if ($openIndex -lt 0) {
        throw "no /goal block found in: $Path"
    }
    if ($closeIndex -lt 0) {
        throw "unterminated /goal block (missing closing quote line) in: $Path"
    }

    $body = @()
    for ($i = $openIndex; $i -le $closeIndex; $i++) {
        $body += $lines[$i]
    }

    $text = ($body -join "`n")
    # 開き `/goal "` までと、末尾の閉じ `"` を除去して objective 本文だけにする。
    $text = $text -replace '(?s)^.*?/goal[ \t]*"', ''
    $text = $text -replace '(?s)"[ \t]*$', ''

    return $text.Trim()
}

function New-CodexGoalRpcRequest {
    <#
    .SYNOPSIS
        JSON-RPC 2.0 リクエストフレーム (改行終端 JSON) を生成する。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [hashtable]$Parameters
    )

    $frame = [ordered]@{
        jsonrpc = "2.0"
        id      = $Id
        method  = $Method
    }
    if ($PSBoundParameters.ContainsKey("Parameters")) {
        $frame["params"] = $Parameters
    }

    return ($frame | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertFrom-CodexGoalRpcResponse {
    <#
    .SYNOPSIS
        1 行の JSON を解析し、指定 id の応答なら返す (通知・不一致・解析不能は $null)。
    #>
    param(
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory = $true)]
        [int]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $parsed = $null
    try {
        $parsed = $Line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($null -eq $parsed) { return $null }
    if (-not (Test-CodexPropertyExists -InputObject $parsed -Name "id")) { return $null }
    if ($null -eq $parsed.id) { return $null }
    if ([int]$parsed.id -ne $Id) { return $null }

    return $parsed
}

function Get-CodexGoalRpcResult {
    <#
    .SYNOPSIS
        応答から result を取り出す。error 応答なら例外にする。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    if ((Test-CodexPropertyExists -InputObject $Response -Name "error") -and ($null -ne $Response.error)) {
        $code = $Response.error.code
        $message = $Response.error.message
        throw "codex app-server rpc error ($code): $message"
    }

    return $Response.result
}

# ------------------------------------------------------------
# セッション (1 接続 = 1 codex app-server プロセス)
# ------------------------------------------------------------

function New-CodexGoalSession {
    <#
    .SYNOPSIS
        `codex app-server` プロセスを起動し、RPC セッションを開く。
    .DESCRIPTION
        スレッドは app-server プロセスが所有するため、関連する RPC は
        同一セッション内で順に呼ぶ必要がある。
    #>
    param(
        [string]$CodexCommand = $script:DefaultCodexCommand,
        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $CodexCommand
    $startInfo.Arguments = "app-server"
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
    }
    catch {
        $process.Dispose()
        throw "failed to start '$CodexCommand app-server': $($_.Exception.Message)"
    }

    $session = [pscustomobject]@{
        Process          = $process
        NextId           = 0
        CodexCommand     = $CodexCommand
        WorkingDirectory = $WorkingDirectory
        Initialized      = $false
    }

    return $session
}

function Close-CodexGoalSession {
    <#
    .SYNOPSIS
        セッションを閉じ、app-server プロセスを終了する。
    #>
    param(
        [AllowNull()]
        [object]$Session
    )

    if ($null -eq $Session) { return }

    $process = $Session.Process
    if ($null -eq $process) { return }

    try {
        if (-not $process.HasExited) {
            # stdin を閉じて EOF を送り、app-server を正常終了させる。
            # 強制 Kill するとスレッドに "active writer" が残り、
            # 後続セッションが同じスレッドを開けなくなる (実測)。
            try { $process.StandardInput.Close() } catch { }

            if (-not $process.WaitForExit(3000)) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        }
    }
    catch {
        # 終了失敗は無視する (プロセスは OS が回収する)。
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-CodexGoalSessionRpc {
    <#
    .SYNOPSIS
        セッションへ 1 リクエストを送り、対応する result を返す。
    .DESCRIPTION
        通知行 (id 無し) は読み捨てる。error 応答は Get-CodexGoalRpcResult が例外化する。
        initialize はセッション初回のみ自動で送る。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [hashtable]$Parameters,

        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec
    )

    if (-not $Session.Initialized -and $Method -ne "initialize") {
        [void](Invoke-CodexGoalSessionRpc -Session $Session -Method "initialize" `
                -Parameters @{ clientInfo = @{ name = $script:RpcClientName; version = "1.0" } } -TimeoutSec $TimeoutSec)
    }

    $Session.NextId = [int]$Session.NextId + 1
    $id = [int]$Session.NextId
    $frame = New-CodexGoalRpcRequest -Id $id -Method $Method -Parameters $Parameters
    $Session.Process.StandardInput.WriteLine($frame)
    $Session.Process.StandardInput.Flush()

    if ($Method -eq "initialize") { $Session.Initialized = $true }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $task = $Session.Process.StandardOutput.ReadLineAsync()
        if (-not $task.Wait($TimeoutSec * 1000)) {
            throw "timeout waiting for codex app-server response (id=$id method=$Method)"
        }
        if ($null -eq $task.Result) {
            throw "codex app-server closed stdout before responding (id=$id method=$Method)"
        }

        $response = ConvertFrom-CodexGoalRpcResponse -Line $task.Result -Id $id
        if ($null -eq $response) { continue }   # 通知は読み捨て

        return Get-CodexGoalRpcResult -Response $response
    }

    throw "timeout waiting for codex app-server response (id=$id method=$Method)"
}

# ------------------------------------------------------------
# 高レベル操作
# ------------------------------------------------------------

function Start-CodexGoalRun {
    <#
    .SYNOPSIS
        新規スレッドを作成し、そのスレッドへ Goal を設定して返す。
    .DESCRIPTION
        非対話起動の入口。thread/start と thread/goal/set は
        スレッド所有権の都合で **同一セッション内** で実行する。
        失敗は例外で返し、呼び出し側が Goal 無し起動へ降格できるようにする。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Objective,

        [int64]$TokenBudget,

        [string]$WorkingDirectory,
        [string]$CodexCommand = $script:DefaultCodexCommand,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).Path
    }

    $check = Test-CodexGoalObjective -Objective $Objective
    if (-not $check.Valid) {
        throw "invalid goal objective ($($check.Reason), length=$($check.Length), max=$script:GoalObjectiveMaxLength)"
    }

    $session = $null
    try {
        $session = New-CodexGoalSession -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory

        $startResult = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/start" `
            -Parameters @{ cwd = $WorkingDirectory } -TimeoutSec $TimeoutSec

        $thread = if (Test-CodexPropertyExists -InputObject $startResult -Name "thread") { $startResult.thread } else { $null }
        if ($null -eq $thread -or -not $thread.id) {
            throw "thread/start did not return a thread id"
        }

        $goal = Set-CodexThreadGoalInternal -Session $session -ThreadId $thread.id -Objective $Objective `
            -Status "active" -TokenBudget $TokenBudget -HasTokenBudget:$PSBoundParameters.ContainsKey("TokenBudget") `
            -TimeoutSec $TimeoutSec

        return [pscustomobject]@{
            ThreadId  = $thread.id
            Objective = $Objective
            Goal      = $goal
        }
    }
    finally {
        Close-CodexGoalSession -Session $session
    }
}

function Set-CodexThreadGoalInternal {
    <#
    .SYNOPSIS
        開いているセッションに対し thread/goal/set を送る内部ヘルパ。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,

        [Parameter(Mandatory = $true)]
        [string]$ThreadId,

        [Parameter(Mandatory = $true)]
        [string]$Objective,

        [string]$Status = "active",

        [int64]$TokenBudget,

        [switch]$HasTokenBudget,

        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec
    )

    $parameters = @{
        threadId  = $ThreadId
        objective = $Objective
        status    = $Status
    }
    if ($HasTokenBudget) {
        $parameters["tokenBudget"] = $TokenBudget
    }

    $result = Invoke-CodexGoalSessionRpc -Session $Session -Method "thread/goal/set" `
        -Parameters $parameters -TimeoutSec $TimeoutSec

    if (Test-CodexPropertyExists -InputObject $result -Name "goal") { return $result.goal }

    return $result
}

function Set-CodexThreadGoal {
    <#
    .SYNOPSIS
        既存スレッドへ Goal を設定する (thread/resume -> thread/goal/set)。
    .DESCRIPTION
        スレッドは app-server プロセスの所有物なので、別プロセスから設定する場合は
        先に thread/resume でディスクから読み込む必要がある (実測で確認)。
    .PARAMETER Objective
        Goal 本文。非空かつ 4,000 文字以内。
    .PARAMETER TokenBudget
        省略可。指定するとトークン上限が設定される。
    .PARAMETER Status
        active / paused / blocked / usageLimited / budgetLimited / complete。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ThreadId,

        [Parameter(Mandatory = $true)]
        [string]$Objective,

        [int64]$TokenBudget,

        [ValidateSet("active", "paused", "blocked", "usageLimited", "budgetLimited", "complete")]
        [string]$Status = "active",

        [string]$CodexCommand = $script:DefaultCodexCommand,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec,
        [string]$WorkingDirectory
    )

    $check = Test-CodexGoalObjective -Objective $Objective
    if (-not $check.Valid) {
        throw "invalid goal objective ($($check.Reason), length=$($check.Length), max=$script:GoalObjectiveMaxLength)"
    }

    $session = $null
    try {
        $session = New-CodexGoalSession -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory
        [void](Invoke-CodexGoalSessionRpc -Session $session -Method "thread/resume" `
                -Parameters @{ threadId = $ThreadId } -TimeoutSec $TimeoutSec)

        return Set-CodexThreadGoalInternal -Session $session -ThreadId $ThreadId -Objective $Objective `
            -Status $Status -TokenBudget $TokenBudget -HasTokenBudget:$PSBoundParameters.ContainsKey("TokenBudget") `
            -TimeoutSec $TimeoutSec
    }
    finally {
        Close-CodexGoalSession -Session $session
    }
}

function Get-CodexThreadGoal {
    <#
    .SYNOPSIS
        スレッドの現在の Goal を取得する (thread/goal/get)。無ければ $null。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ThreadId,

        [string]$CodexCommand = $script:DefaultCodexCommand,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec,
        [string]$WorkingDirectory
    )

    $session = $null
    try {
        $session = New-CodexGoalSession -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory
        $result = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/goal/get" `
            -Parameters @{ threadId = $ThreadId } -TimeoutSec $TimeoutSec

        if ($null -eq $result) { return $null }
        if (Test-CodexPropertyExists -InputObject $result -Name "goal") { return $result.goal }

        return $result
    }
    finally {
        Close-CodexGoalSession -Session $session
    }
}

function Clear-CodexThreadGoal {
    <#
    .SYNOPSIS
        スレッドの Goal を削除する (thread/goal/clear)。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ThreadId,

        [string]$CodexCommand = $script:DefaultCodexCommand,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec,
        [string]$WorkingDirectory
    )

    $session = $null
    try {
        $session = New-CodexGoalSession -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory
        $result = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/goal/clear" `
            -Parameters @{ threadId = $ThreadId } -TimeoutSec $TimeoutSec

        if (Test-CodexPropertyExists -InputObject $result -Name "cleared") { return [bool]$result.cleared }

        return $false
    }
    finally {
        Close-CodexGoalSession -Session $session
    }
}

Export-ModuleMember -Function @(
    "Get-CodexGoalObjectiveMaxLength",
    "Test-CodexGoalObjective",
    "Get-CodexGoalObjectiveFromTemplate",
    "New-CodexGoalRpcRequest",
    "ConvertFrom-CodexGoalRpcResponse",
    "Get-CodexGoalRpcResult",
    "New-CodexGoalSession",
    "Close-CodexGoalSession",
    "Invoke-CodexGoalSessionRpc",
    "Start-CodexGoalRun",
    "Set-CodexThreadGoal",
    "Get-CodexThreadGoal",
    "Clear-CodexThreadGoal"
)
