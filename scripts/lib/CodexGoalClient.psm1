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
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
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
        PendingEvents    = New-Object System.Collections.Generic.List[string]
        PendingRead      = $null
        StderrDrain      = $stderrDrain
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

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    if (-not $Session.Initialized -and $Method -ne "initialize") {
        [void](Invoke-CodexGoalSessionRpc -Session $Session -Method "initialize" `
                -Parameters @{ clientInfo = @{ name = $script:RpcClientName; version = "1.0" } } -TimeoutSec $TimeoutSec)
    }

    if ((Get-Date) -ge $deadline) {
        throw "timeout waiting for codex app-server response (method=$Method)"
    }
    $Session.NextId = [int]$Session.NextId + 1
    $id = [int]$Session.NextId
    $frame = New-CodexGoalRpcRequest -Id $id -Method $Method -Parameters $Parameters
    $Session.Process.StandardInput.WriteLine($frame)
    $Session.Process.StandardInput.Flush()

    if ($Method -eq "initialize") { $Session.Initialized = $true }

    while ((Get-Date) -lt $deadline) {
        $remaining = [int][math]::Max(1, ($deadline - (Get-Date)).TotalSeconds)
        $line = Read-CodexGoalSessionStdoutLine -Session $Session -TimeoutSec $remaining
        if ($null -eq $line) {
            throw "timeout waiting for codex app-server response (id=$id method=$Method)"
        }

        $response = ConvertFrom-CodexGoalRpcResponse -Line $line -Id $id
        if ($null -eq $response) {
            # 通知は後段のイベント待ち (Wait-CodexGoalTurnCompleted) が読めるよう退避する。
            $Session.PendingEvents.Add($line)
            continue
        }

        return Get-CodexGoalRpcResult -Response $response
    }

    throw "timeout waiting for codex app-server response (id=$id method=$Method)"
}

function Read-CodexGoalSessionStdoutLine {
    <#
    .SYNOPSIS
        セッションの stdout から次の 1 行を直接読む (バッファを見ない)。timeout なら $null。
    .DESCRIPTION
        RPC 応答待ちは必ずこちらを使う。バッファ (PendingEvents) を経由させると、
        応答でない通知を再びバッファへ戻す循環が生じて stdout を読まなくなり、
        応答が永久に来なくなる (実測で発生)。
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec
    )

    if (-not (Test-CodexPropertyExists -InputObject $Session -Name "PendingRead")) {
        $Session | Add-Member -NotePropertyName PendingRead -NotePropertyValue $null
    }
    # タイムアウト後も同じ読み取りを保持し、並行読み取りと通知の消失を防ぐ。
    if ($null -eq $Session.PendingRead) {
        $Session.PendingRead = $Session.Process.StandardOutput.ReadLineAsync()
    }
    $task = $Session.PendingRead
    if (-not $task.Wait([math]::Max(1, $TimeoutSec) * 1000)) { return $null }
    $Session.PendingRead = $null
    return $task.Result
}

function Read-CodexGoalSessionLine {
    <#
    .SYNOPSIS
        通知バッファを優先して次の 1 行を返す (イベント待ち用)。timeout なら $null。
    .DESCRIPTION
        RPC 応答待ちの間に届いた通知を取りこぼさないための読み取り口。
        RPC 応答そのものを待つ用途には使わない (Read-CodexGoalSessionStdoutLine を使う)。
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [int]$TimeoutSec = $script:DefaultRpcTimeoutSec
    )

    if ($Session.PendingEvents.Count -gt 0) {
        $buffered = $Session.PendingEvents[0]
        $Session.PendingEvents.RemoveAt(0)
        return $buffered
    }

    return Read-CodexGoalSessionStdoutLine -Session $Session -TimeoutSec $TimeoutSec
}

function Get-CodexGoalPropertySafe {
    <#
    .SYNOPSIS
        入れ子オブジェクトから安全にプロパティを取り出す (内部ヘルパ)。
    #>
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if (-not (Test-CodexPropertyExists -InputObject $InputObject -Name $Name)) { return $null }
    return $InputObject.$Name
}

function Wait-CodexGoalTurnCompleted {
    <#
    .SYNOPSIS
        次に turn/completed が届くまで通知を読み続ける。
    .DESCRIPTION
        実測 (0.154.0): app-server は turn 完了後に Goal を自動継続しない。
        turn/completed 後も goal.status は active のままで、次の turn/started は来ない。
        したがって継続は呼び出し側 (Invoke-CodexGoalRun) が駆動する必要がある。
    .OUTPUTS
        [pscustomobject] TurnCompleted / GoalStatus / Goal / TimedOut / Events
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Session,
        [int]$TimeoutSec = 1800
    )

    $events = New-Object System.Collections.Generic.List[string]
    $goalStatus = $null
    $goal = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $remaining = [int][math]::Max(1, ($deadline - (Get-Date)).TotalSeconds)
        $line = Read-CodexGoalSessionLine -Session $Session -TimeoutSec ([math]::Min($remaining, 30))
        if ($null -eq $line) { continue }   # 無音は継続 (timeout ではない)

        $parsed = $null
        try { $parsed = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $parsed) { continue }
        if (-not (Test-CodexPropertyExists -InputObject $parsed -Name "method")) { continue }

        $method = [string]$parsed.method
        $events.Add($method)

        if ($method -eq "thread/goal/updated") {
            $g = Get-CodexGoalPropertySafe -InputObject $parsed.params -Name "goal"
            if ($null -ne $g) {
                $goal = $g
                $goalStatus = [string](Get-CodexGoalPropertySafe -InputObject $g -Name "status")
            }
        }

        if ($method -eq "turn/completed") {
            return [pscustomobject]@{
                TurnCompleted = $true
                GoalStatus    = $goalStatus
                Goal          = $goal
                TimedOut      = $false
                Events        = @($events)
            }
        }
    }

    return [pscustomobject]@{
        TurnCompleted = $false
        GoalStatus    = $goalStatus
        Goal          = $goal
        TimedOut      = $true
        Events        = @($events)
    }
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

function Get-CodexGoalTerminalStatuses {
    <#
    .SYNOPSIS
        Goal がそれ以上継続しない終端 status の一覧。
    #>
    return @("complete", "blocked", "usageLimited", "budgetLimited")
}

function Get-CodexGoalContinuationPrompt {
    <#
    .SYNOPSIS
        外部駆動で継続ターンを送るときの既定プロンプト。
    .DESCRIPTION
        Codex ネイティブの継続プロンプトと同じ規律 (目的を縮小しない / 証拠で判断 /
        progress と verified wait の区別 / 3 ターン連続の同一ブロッカーで blocked)
        を外部から与える。app-server は自動継続しないため、この文面が継続の実体になる。
    #>
    param([Parameter(Mandatory = $true)][string]$Objective)

    return @"
Continue working toward the active thread goal. The objective is:

<objective>
$Objective
</objective>

Continuation behavior:
- Keep the full objective intact. Do not shrink it to what fits in this turn.
- If it cannot be finished now, make concrete progress toward the real end state and leave the goal active.
- Temporary rough edges are acceptable while work moves in the right direction.

Work from evidence:
- Treat the current worktree and external state as authoritative. Inspect them before relying on prior context.
- Re-read files and re-run commands rather than assuming the previous turn's state still holds.

Progress check:
- Decide whether the previous turn made progress, was a verified wait, or made no progress.
- Progress changes authoritative state or yields evidence that changes the next action. Restating status is not progress.
- Do not repeat an action that already failed without new evidence.

Completion:
- If the objective is achieved and verified, call update_goal with status complete.
- Only set blocked if the same blocking condition has persisted for at least three consecutive goal turns.
- Do not mark complete merely because the token budget is nearly exhausted.
"@
}

function Invoke-CodexGoalRun {
    <#
    .SYNOPSIS
        Goal を終端 status まで外部駆動する (セッション保持型ドライバ)。
    .DESCRIPTION
        実測 (codex-cli 0.154.0): app-server は turn 完了後に Goal を自動継続しない。
        そのため、turn/start → turn/completed 待ち → goal.status 確認 → 継続 turn 送出
        というループを本関数が回す。app-server セッションは実行中ずっと保持する。
    .PARAMETER MaxTurns
        継続を含む最大ターン数。暴走防止の一次上限。
    .PARAMETER MaxMinutes
        壁時計での上限。turn の timeout とは別。
    .PARAMETER OnEvent
        進捗通知用の任意コールバック。引数に [pscustomobject] を渡す。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Objective,
        [int64]$TokenBudget,
        [string]$WorkingDirectory,
        [string]$CodexCommand = $script:DefaultCodexCommand,
        [int]$MaxTurns = 20,
        [int]$MaxMinutes = 120,
        [int]$TurnTimeoutSec = 1800,
        [scriptblock]$OnEvent,
        [string]$ContinuationPrompt
    )

    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
    if (-not $ContinuationPrompt) { $ContinuationPrompt = Get-CodexGoalContinuationPrompt -Objective $Objective }

    $check = Test-CodexGoalObjective -Objective $Objective
    if (-not $check.Valid) {
        throw "invalid goal objective ($($check.Reason), length=$($check.Length), max=$script:GoalObjectiveMaxLength)"
    }

    # paused は再開可能だが、このドライバから継続ターンを送ってはならない。
    $stopStatuses = @(Get-CodexGoalTerminalStatuses) + @("paused")
    $turns = New-Object System.Collections.Generic.List[object]
    $session = $null
    $threadId = $null
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    $remainingTimeout = {
        param([int]$Limit)
        $remaining = ($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { throw "goal run time limit reached" }
        return [int][math]::Min($Limit, [math]::Ceiling($remaining))
    }

    try {
        $session = New-CodexGoalSession -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory

        $startResult = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/start" `
            -Parameters @{ cwd = $WorkingDirectory } -TimeoutSec (& $remainingTimeout 60)
        $thread = Get-CodexGoalPropertySafe -InputObject $startResult -Name "thread"
        if ($null -eq $thread -or -not $thread.id) { throw "thread/start did not return a thread id" }
        $threadId = $thread.id

        $goal = Set-CodexThreadGoalInternal -Session $session -ThreadId $threadId -Objective $Objective `
            -Status "active" -TokenBudget $TokenBudget -HasTokenBudget:$PSBoundParameters.ContainsKey("TokenBudget") `
            -TimeoutSec (& $remainingTimeout 60)
        $status = [string](Get-CodexGoalPropertySafe -InputObject $goal -Name "status")

        for ($turn = 1; $turn -le $MaxTurns; $turn++) {
            if ($status -in $stopStatuses) { break }
            if ((Get-Date) -ge $deadline) { break }

            $text = if ($turn -eq 1) { $Objective } else { $ContinuationPrompt }
            [void](Invoke-CodexGoalSessionRpc -Session $session -Method "turn/start" `
                    -Parameters @{ threadId = $threadId; input = @(@{ type = "text"; text = $text }) } `
                    -TimeoutSec (& $remainingTimeout 60))

            if ((Get-Date) -ge $deadline) { break }
            $wait = Wait-CodexGoalTurnCompleted -Session $session -TimeoutSec (& $remainingTimeout $TurnTimeoutSec)

            $currentGoal = if ($wait.Goal) { $wait.Goal } else { $goal }
            if ((Get-Date) -lt $deadline) {
                $statusResult = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/goal/get" `
                    -Parameters @{ threadId = $threadId } -TimeoutSec (& $remainingTimeout 60)
                $currentGoal = Get-CodexGoalPropertySafe -InputObject $statusResult -Name "goal"
                if ($null -eq $currentGoal) { $currentGoal = $statusResult }
            }
            $goal = $currentGoal
            $status = [string](Get-CodexGoalPropertySafe -InputObject $currentGoal -Name "status")

            $record = [pscustomobject]@{
                Turn          = $turn
                TurnCompleted = $wait.TurnCompleted
                TimedOut      = $wait.TimedOut
                GoalStatus    = $status
                TokensUsed    = Get-CodexGoalPropertySafe -InputObject $currentGoal -Name "tokensUsed"
                TimeUsedSec   = Get-CodexGoalPropertySafe -InputObject $currentGoal -Name "timeUsedSeconds"
            }
            $turns.Add($record)
            # コールバックの出力はホストへ流す。パイプラインへ流すと
            # Invoke-CodexGoalRun の戻り値に混ざるため。
            if ($OnEvent) { & $OnEvent $record | Write-Host }

            if ($wait.TimedOut) { break }
        }

        $finalGoal = $goal
        if ($threadId -and (Get-Date) -lt $deadline) {
            $finalResult = Invoke-CodexGoalSessionRpc -Session $session -Method "thread/goal/get" `
                -Parameters @{ threadId = $threadId } -TimeoutSec (& $remainingTimeout 60)
            $finalGoal = Get-CodexGoalPropertySafe -InputObject $finalResult -Name "goal"
            if ($null -eq $finalGoal) { $finalGoal = $finalResult }
        }

        $finalStatus = if ($finalGoal) { [string](Get-CodexGoalPropertySafe -InputObject $finalGoal -Name "status") } else { $status }
        $stopReason = if ($finalStatus -in $stopStatuses) { "goal-$finalStatus" }
        elseif ((Get-Date) -ge $deadline) { "time-limit" }
        elseif ($turns.Count -ge $MaxTurns) { "max-turns" }
        else { "turn-timeout" }

        return [pscustomobject]@{
            ThreadId    = $threadId
            Objective   = $Objective
            FinalStatus = $finalStatus
            StopReason  = $stopReason
            # List[object] を @() で包むと [pscustomobject] リテラルが
            # "Argument types do not match" で失敗するため ToArray() を使う。
            Turns       = $turns.ToArray()
            Goal        = $finalGoal
        }
    }
    finally {
        Close-CodexGoalSession -Session $session
    }
}

# ------------------------------------------------------------
# Goal 一覧 (goals_1.sqlite の読み取り)
# ------------------------------------------------------------

function Get-CodexGoalDatabasePath {
    <#
    .SYNOPSIS
        Codex の goals DB のパスを返す。CODEX_HOME 未設定なら ~/.codex。
    #>
    param([string]$CodexHome)

    if (-not $CodexHome) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
    }
    return (Join-Path $CodexHome "goals_1.sqlite")
}

function ConvertFrom-CodexGoalListJson {
    <#
    .SYNOPSIS
        goals DB から読み出した JSON 行を Goal オブジェクトへ変換する (純粋関数)。
    #>
    param([AllowEmptyString()][AllowNull()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }

    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if ($null -eq $parsed) { return @() }

    $rows = if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) { @($parsed) } else { @($parsed) }

    $out = @()
    foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        $out += [pscustomobject]@{
            ThreadId        = [string](Get-CodexGoalPropertySafe -InputObject $row -Name "thread_id")
            GoalId          = [string](Get-CodexGoalPropertySafe -InputObject $row -Name "goal_id")
            Status          = [string](Get-CodexGoalPropertySafe -InputObject $row -Name "status")
            Objective       = [string](Get-CodexGoalPropertySafe -InputObject $row -Name "objective")
            TokenBudget     = Get-CodexGoalPropertySafe -InputObject $row -Name "token_budget"
            TokensUsed      = Get-CodexGoalPropertySafe -InputObject $row -Name "tokens_used"
            TimeUsedSeconds = Get-CodexGoalPropertySafe -InputObject $row -Name "time_used_seconds"
            UpdatedAtMs     = Get-CodexGoalPropertySafe -InputObject $row -Name "updated_at_ms"
        }
    }

    return $out
}

function Get-CodexGoalList {
    <#
    .SYNOPSIS
        Codex の goals DB から現在の Goal 一覧を読む (読み取り専用)。
    .DESCRIPTION
        PowerShell に sqlite が無いため python3 → sqlite3 CLI の順で外部コマンドを使う。
        どちらも無い / DB が無い場合は Available=$false と Reason を返し、例外にしない
        (メニュー表示を止めないため)。
    #>
    param(
        [string]$CodexHome
    )

    $dbPath = Get-CodexGoalDatabasePath -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        return [pscustomobject]@{ Available = $false; Reason = "goals-db-not-found"; DatabasePath = $dbPath; Goals = @() }
    }

    $query = "SELECT thread_id,goal_id,status,objective,token_budget,tokens_used,time_used_seconds,updated_at_ms FROM thread_goals ORDER BY updated_at_ms DESC"
    $json = $null
    $tool = $null

    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $py = @"
import json,sqlite3,sys
try:
    c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True)
    rows=[dict(zip(['thread_id','goal_id','status','objective','token_budget','tokens_used','time_used_seconds','updated_at_ms'],r))
          for r in c.execute(sys.argv[2])]
    print(json.dumps(rows,ensure_ascii=False))
except Exception:
    sys.exit(1)
"@
        $json = & python3 -c $py $dbPath $query 2>$null
        if ($LASTEXITCODE -eq 0) { $tool = "python3" } else { $json = $null }
    }

    if ($null -eq $json -and (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
        $raw = & sqlite3 -readonly -json $dbPath $query 2>$null
        if ($LASTEXITCODE -eq 0) { $json = $raw; $tool = "sqlite3" }
    }

    if ($null -eq $json) {
        return [pscustomobject]@{ Available = $false; Reason = "no-sqlite-reader"; DatabasePath = $dbPath; Goals = @() }
    }

    return [pscustomobject]@{
        Available    = $true
        Reason       = "ok"
        DatabasePath = $dbPath
        Tool         = $tool
        Goals        = @(ConvertFrom-CodexGoalListJson -Json ([string]::Join("", @($json))))
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
    "Read-CodexGoalSessionStdoutLine",
    "Read-CodexGoalSessionLine",
    "Invoke-CodexGoalSessionRpc",
    "Wait-CodexGoalTurnCompleted",
    "Start-CodexGoalRun",
    "Set-CodexThreadGoal",
    "Get-CodexThreadGoal",
    "Clear-CodexThreadGoal",
    "Get-CodexGoalTerminalStatuses",
    "Get-CodexGoalContinuationPrompt",
    "Invoke-CodexGoalRun",
    "Get-CodexGoalDatabasePath",
    "ConvertFrom-CodexGoalListJson",
    "Get-CodexGoalList"
)
