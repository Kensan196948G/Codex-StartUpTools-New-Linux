Set-StrictMode -Version Latest

# ============================================================
# GoalRouter.psm1 — Evidence 駆動の Goal 選択 (Codex 版)
#
# 役割:
#   Codex ネイティブ Goal は「与えられた Goal をどう回すか」は担うが、
#   「どの Goal を選ぶか」は人間が /goal と打つしかない。
#   本モジュールは Project 状態 + Repository / Runtime Evidence + ユーザー意図から
#   Primary Goal (5 分類) と Specialized Goal (6 分類) を決定し、
#   config/goals/<effective>.md の /goal 本文を CodexGoalClient へ渡せる形にする。
#
#   Evidence → Route → Primary → Specialized → effective → goals/<effective>.md
#
# 移植元: Claude-StartUpTools-New-Linux lib/goal-router.sh (ClaudeOS v10.1)
#   移植方針: 判定ロジックは goals の分類・優先順位・lock/reroute を忠実に踏襲し、
#             state.json のキーも互換 (goal_router ブロック) に保つ。
#             外部呼び出し (gh / curl) は evidence 側に閉じ込め、
#             Invoke-GoalRouterRoute は純粋関数のままにする (テスト容易性)。
#
# 設計原則:
#   - 単一モジュール: CLI / Launcher / メニューはすべてここを呼ぶ
#   - Fail-safe: Router が失敗しても起動を止めない (fallback 連鎖で必ず 1 つ返す)
#   - Flapping 防止: session lock。重大状態変化・ユーザー新指示時のみ reroute
#   - 権限非昇格: Routing 結果は Goal の選択であり Human Gate / permissions を変えない
# ============================================================

$script:PrimaryGoals = @("development", "mvp-release", "assessment", "deep-debug", "product-assurance")
$script:SpecializedGoals = @("production-release", "hotfix", "security-emergency", "refactoring", "safe-auto-merge", "pr-babysit")
$script:DefaultLockMinutes = 720
$script:DefaultRuntimeErrorThreshold = 5
$script:GoalRouterVersion = 1

function Get-GoalRouterPrimaryGoals { return $script:PrimaryGoals }
function Get-GoalRouterSpecializedGoals { return $script:SpecializedGoals }
function Get-GoalRouterDefaultLockMinutes { return $script:DefaultLockMinutes }

# ------------------------------------------------------------
# 分類ヘルパ
# ------------------------------------------------------------

function Test-GoalRouterIsPrimary {
    param([string]$Goal)
    return [bool]($script:PrimaryGoals -contains $Goal)
}

function Test-GoalRouterIsSpecialized {
    param([string]$Goal)
    return [bool]($script:SpecializedGoals -contains $Goal)
}

function Test-GoalRouterIsGoal {
    param([string]$Goal)
    return (Test-GoalRouterIsPrimary -Goal $Goal) -or (Test-GoalRouterIsSpecialized -Goal $Goal)
}

function Get-GoalRouterLabelJa {
    param([string]$Goal)
    $labels = @{
        "development"        = "開発"
        "mvp-release"        = "MVPリリース"
        "assessment"         = "評価"
        "deep-debug"         = "詳細デバッグ"
        "product-assurance"  = "品質保証"
        "production-release" = "本番リリース"
        "hotfix"             = "緊急修正"
        "security-emergency" = "セキュリティ緊急対応"
        "refactoring"        = "リファクタリング"
        "safe-auto-merge"    = "安全自動マージ"
        "pr-babysit"         = "PR見守り"
    }
    if ($labels.ContainsKey($Goal)) { return $labels[$Goal] }
    return ""
}

function Get-GoalRouterPrimaryFor {
    <#
    .SYNOPSIS
        Specialized 単独指定時の既定 Primary (Claude 側 §5 推奨マッピング)。
    #>
    param([string]$Specialized)
    switch ($Specialized) {
        "production-release" { return "product-assurance" }
        "hotfix"             { return "deep-debug" }
        "security-emergency" { return "deep-debug" }
        "refactoring"        { return "development" }
        "safe-auto-merge"    { return "product-assurance" }
        "pr-babysit"         { return "product-assurance" }
        default              { return "" }
    }
}

function Test-GoalRouterAllows {
    <#
    .SYNOPSIS
        Primary 配下で許可される Specialized か。
    #>
    param([string]$Primary, [string]$Specialized)

    if ([string]::IsNullOrEmpty($Specialized) -or $Specialized -eq "null") { return $true }

    $key = "$Primary`:$Specialized"
    return [bool](@(
            "development:refactoring", "development:hotfix",
            "mvp-release:production-release",
            "assessment:security-emergency",
            "deep-debug:hotfix", "deep-debug:security-emergency",
            "product-assurance:production-release", "product-assurance:safe-auto-merge", "product-assurance:pr-babysit"
        ) -contains $key)
}

function ConvertFrom-GoalRouterLegacyGoalType {
    <#
    .SYNOPSIS
        旧 goal_type → "primary specialized" (半角スペース区切り)。
    #>
    param([string]$GoalType)

    if ($script:PrimaryGoals -contains $GoalType) { return "$GoalType " }
    if ($script:SpecializedGoals -contains $GoalType) {
        return "$(Get-GoalRouterPrimaryFor -Specialized $GoalType) $GoalType"
    }
    return " "
}

function Get-GoalRouterIntentClass {
    <#
    .SYNOPSIS
        ユーザー意図テキストを Primary/Specialized へ分類する ("primary specialized" 形式)。
    .DESCRIPTION
        優先順位は Claude 側 §7 を踏襲:
        security-emergency > deep-debug > hotfix > product-assurance > production-release
        > assessment > mvp-release > development
        判定不能なら空文字を返す (呼び出し側が LLM 分類や状態判定へフォールバックする)。
    #>
    param([AllowEmptyString()][string]$Intent)

    if ([string]::IsNullOrWhiteSpace($Intent)) { return "" }
    $t = $Intent.ToLowerInvariant()

    $sec = $t -match '(脆弱|セキュリティ|security|cve|漏洩|exploit|侵害)'
    $hot = $t -match '(hotfix|ホットフィックス|緊急修正|緊急対応|本番障害)'
    $dbg = $t -match '(直して|直す|修正|バグ|bug|ci ?失敗|ci ?failure|failing|failure|error|エラー|regression|回帰|障害|debug|デバッグ|動かない|落ちる|不具合|500|crash)'
    $pa = $t -match '(総合テスト|品質保証|リリース判定|release ?判定|assurance|受入テスト|golden|fail-?safe|contract ?test|recovery ?test|chaos)'
    $asm = $t -match '(評価|全体確認|レビュー|review|監査|audit|比較|readiness|gap ?分析|技術的負債の?評価|assess)'
    $mvp = $t -match '(mvp|poc|prototype|プロトタイプ|最小版|最小限|新規プロジェクト|新規開発|0 ?から|ゼロから|立ち上げ)'
    $dev = $t -match '(作って|作成|実装|改善|機能追加|追加して|開発|develop|feature|enhance|ui/ux|api ?改善|運用改善)'
    $ref = $t -match '(リファクタ|refactor|技術的負債|技術負債|tech ?debt|cleanup)'
    $rel = $t -match '(本番リリース|production ?release|デプロイ準備|release ?candidate|リリース準備|署名|signoff|deploy\.ready)'
    $mrg = $t -match '(auto-?merge|自動マージ|マージして|merge)'
    $baby = $t -match '(babysit|番人|pr ?監視|ci ?の?面倒)'

    if ($sec -and ($dbg -or $hot -or $asm)) { return "deep-debug security-emergency" }
    if ($sec) { return "assessment security-emergency" }
    if ($hot) { return "deep-debug hotfix" }
    if ($dbg) { return "deep-debug" }
    if ($baby) { return "product-assurance pr-babysit" }
    if ($mrg) { return "product-assurance safe-auto-merge" }
    if ($pa) { return "product-assurance" }
    if ($rel) { return "product-assurance production-release" }
    if ($asm) { return "assessment" }
    if ($ref) { return "development refactoring" }
    if ($mvp) { return "mvp-release" }
    if ($dev) { return "development" }
    return ""
}

# ------------------------------------------------------------
# 内部ユーティリティ
# ------------------------------------------------------------

function Get-GoalRouterEvidenceValue {
    <#
    .SYNOPSIS
        Evidence ハッシュから安全に値を取り出す (StrictMode 対策)。無ければ既定値。
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Evidence,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Default = ""
    )

    if ($Evidence.ContainsKey($Key) -and $null -ne $Evidence[$Key]) {
        return [string]$Evidence[$Key]
    }
    return $Default
}

function ConvertTo-GoalRouterInt {
    <#
    .SYNOPSIS
        文字列を整数化する。数値でなければ既定値を返す。
    #>
    param([AllowEmptyString()][string]$Value, [int]$Default = 0)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-GoalRouterEpoch {
    <#
    .SYNOPSIS
        ISO-8601 文字列を Unix epoch 秒へ変換する。解析不能なら 0。
    #>
    param([AllowEmptyString()][string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return 0 }
    $dt = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Timestamp, [ref]$dt)) { return [int64]$dt.ToUnixTimeSeconds() }
    return 0
}

function Get-GoalRouterProperty {
    <#
    .SYNOPSIS
        入れ子オブジェクトから安全にプロパティを取り出す。
    #>
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    if ($InputObject.PSObject.Properties.Name -contains $Name) { return $InputObject.$Name }
    return $null
}

# ------------------------------------------------------------
# Evidence 収集 (外部呼び出しはすべてここに閉じ込める)
# ------------------------------------------------------------

function Get-GoalRouterEvidence {
    <#
    .SYNOPSIS
        Project 状態 / Git / CI / Runtime / 意図 から Routing 用 Evidence を集める。
    .DESCRIPTION
        戻り値は key=value 相当のハッシュ。Invoke-GoalRouterRoute はこのハッシュだけを見る
        (純粋関数) ため、テストでは Evidence を直接与えれば外部 I/O は不要。
    .PARAMETER SkipGitHub
        gh による CI / open PR 収集を行わない (network を使わない)。
    .PARAMETER SkipRuntime
        state.runtime.* の health / error_log 収集を行わない。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowEmptyString()][string]$Intent = "",
        [switch]$SkipGitHub,
        [switch]$SkipRuntime
    )

    $ev = [ordered]@{}

    # --- state.json ---
    $statePath = Join-Path $ProjectDir "state.json"
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $ev["state_present"] = "1"
        }
        catch {
            $ev["state_present"] = "0"
            $ev["state_error"] = "1"
            $state = $null
        }
    }
    else {
        $ev["state_present"] = "0"
    }

    if ($null -ne $state) {
        $project = Get-GoalRouterProperty -InputObject $state -Name "project"
        $maintenance = Get-GoalRouterProperty -InputObject $state -Name "maintenance"
        $phaseMode = Get-GoalRouterProperty -InputObject $project -Name "phase_mode"
        if (-not $phaseMode) { $phaseMode = Get-GoalRouterProperty -InputObject $maintenance -Name "phase_mode" }

        $ev["phase_mode"] = [string]$phaseMode
        $ev["legacy_goal_type"] = [string](Get-GoalRouterProperty -InputObject $state -Name "goal_type")
        $ev["deploy_ready"] = [string](Get-GoalRouterProperty -InputObject (Get-GoalRouterProperty -InputObject $state -Name "deploy") -Name "ready")
        $ev["exec_phase"] = [string](Get-GoalRouterProperty -InputObject (Get-GoalRouterProperty -InputObject $state -Name "execution") -Name "phase")
        $ev["stable_achieved"] = [string](Get-GoalRouterProperty -InputObject (Get-GoalRouterProperty -InputObject $state -Name "stable") -Name "stable_achieved")
        $ev["deploy_executed"] = if (Get-GoalRouterProperty -InputObject (Get-GoalRouterProperty -InputObject $state -Name "deploy") -Name "executed_at") { "true" } else { "" }

        $kpi = Get-GoalRouterProperty -InputObject $state -Name "kpi"
        $ev["security_critical"] = [string](Get-GoalRouterProperty -InputObject $kpi -Name "security_critical")
        $ev["blocker_count"] = [string](Get-GoalRouterProperty -InputObject $kpi -Name "blocker_count")
        $ev["ci_success_rate"] = [string](Get-GoalRouterProperty -InputObject $kpi -Name "ci_success_rate")

        $blockedIssues = Get-GoalRouterProperty -InputObject $state -Name "blocked_issues"
        $ev["blocked_issues"] = if ($blockedIssues -is [System.Collections.ICollection]) { [string]$blockedIssues.Count } else { "" }

        # 前回の Routing 結果 (lock 判定に使う)
        $gr = Get-GoalRouterProperty -InputObject $state -Name "goal_router"
        foreach ($key in @("mode", "primary_goal", "specialized_goal", "locked_by_user", "session_locked", "last_routed_at", "reason")) {
            $ev["prev_$key"] = [string](Get-GoalRouterProperty -InputObject $gr -Name $key)
        }
        $snap = Get-GoalRouterProperty -InputObject $gr -Name "evidence_snapshot"
        foreach ($key in @("deploy_ready", "phase_mode", "security_critical", "ci", "runtime_health")) {
            $ev["prev_snap_$key"] = [string](Get-GoalRouterProperty -InputObject $snap -Name $key)
        }
    }

    # --- Git (ローカル。ネットワーク不要) ---
    $gitDir = Join-Path $ProjectDir ".git"
    if (Test-Path -LiteralPath $gitDir) {
        $ev["git_repo"] = "1"
        $ev["git_branch"] = (& git -C $ProjectDir rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
        $porcelain = @(& git -C $ProjectDir status --porcelain 2>$null)
        $ev["git_dirty"] = [string]$porcelain.Count
        $countRaw = (& git -C $ProjectDir rev-list --count HEAD 2>$null | Select-Object -First 1)
        $ev["git_commits"] = [string](ConvertTo-GoalRouterInt -Value ([string]$countRaw) -Default 0)
    }
    else {
        $ev["git_repo"] = "0"
    }

    $ev["has_ci"] = if (Test-Path -LiteralPath (Join-Path $ProjectDir ".github/workflows")) { "1" } else { "0" }
    $hasTests = @("tests", "test", "__tests__", "spec") | Where-Object { Test-Path -LiteralPath (Join-Path $ProjectDir $_) }
    $ev["has_tests"] = if ($hasTests) { "1" } else { "0" }

    # --- gh (任意。失敗は unknown) ---
    $ci = "unknown"
    $prs = ""
    if (-not $SkipGitHub -and $ev["git_repo"] -eq "1" -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $origin = (& git -C $ProjectDir remote get-url origin 2>$null | Select-Object -First 1)
        if ($origin) {
            $prs = (& gh pr list --state open --json number --jq "length" -R $origin 2>$null | Select-Object -First 1)
            $conclusion = (& gh run list --limit 1 --json conclusion,status --jq '.[0] | if .status != "completed" then "running" else (.conclusion // "unknown") end' -R $origin 2>$null | Select-Object -First 1)
            if ($conclusion) { $ci = [string]$conclusion }
        }
    }
    $ev["pr_open"] = [string]$prs
    $ev["ci"] = $ci

    # --- Runtime (state.runtime.* が設定されている Project のみ) ---
    $health = "unknown"
    $errors = ""
    if (-not $SkipRuntime -and $null -ne $state) {
        $runtime = Get-GoalRouterProperty -InputObject $state -Name "runtime"
        $healthUrl = [string](Get-GoalRouterProperty -InputObject $runtime -Name "health_url")
        $errorLog = [string](Get-GoalRouterProperty -InputObject $runtime -Name "error_log")

        if ($healthUrl -match '^https?://') {
            try {
                $response = Invoke-WebRequest -Uri $healthUrl -Method Head -TimeoutSec 5 -SkipHttpErrorCheck -ErrorAction Stop
                $health = if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400) { "ok" } else { "down" }
            }
            catch {
                $health = "down"
            }
        }

        if ($errorLog) {
            $resolved = $errorLog -replace '^~', $HOME
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                $tail = Get-Content -LiteralPath $resolved -Tail 500 -ErrorAction SilentlyContinue
                $errors = [string](@($tail | Where-Object { $_ -match 'ERROR|FATAL|Traceback|panic:|Unhandled|CRITICAL' }).Count)
            }
        }
    }
    $ev["runtime_health"] = $health
    $ev["runtime_errors"] = $errors
    $ev["cf_deploy"] = "unknown"   # Cloudflare 判定は Claude 側と同様に観測のみ (routing には使わない)

    # --- 意図 ---
    $ev["intent"] = $Intent
    $ev["intent_class"] = Get-GoalRouterIntentClass -Intent $Intent
    $ev["execution_plane"] = "local"   # Managed Plane は未実装。fail-safe で local。

    return $ev
}

# ------------------------------------------------------------
# Routing (純粋関数)
# ------------------------------------------------------------

function Invoke-GoalRouterRoute {
    <#
    .SYNOPSIS
        Evidence から Primary / Specialized / effective Goal を決定する (純粋関数)。
    .DESCRIPTION
        外部 I/O を一切行わない。Claude 側 goal_router__route の優先順位・
        session lock・reroute 条件・fail-safe を忠実に移植している。
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Evidence,
        [AllowEmptyString()][string]$Explicit = "",
        [AllowEmptyString()][string]$Mode = "",
        [string]$Trigger = "auto",
        [int]$LockMinutes = $script:DefaultLockMinutes,
        [int]$RuntimeErrorThreshold = $script:DefaultRuntimeErrorThreshold,
        [bool]$ForceReroute = $false
    )

    $get = { param($k, $d) Get-GoalRouterEvidenceValue -Evidence $Evidence -Key $k -Default $d }

    $sec = ConvertTo-GoalRouterInt -Value (& $get "security_critical" "") -Default 0
    $ci = & $get "ci" "unknown"
    $pm = & $get "phase_mode" ""
    $intent = & $get "intent" ""
    $blocked = ConvertTo-GoalRouterInt -Value (& $get "blocked_issues" "") -Default 0
    $blockers = ConvertTo-GoalRouterInt -Value (& $get "blocker_count" "") -Default 0
    $rate = & $get "ci_success_rate" ""
    $rtHealth = & $get "runtime_health" "unknown"
    $cf = & $get "cf_deploy" "unknown"
    $rtErrors = ConvertTo-GoalRouterInt -Value (& $get "runtime_errors" "") -Default 0

    $inProd = ($pm -eq "maintenance" -or $pm -eq "released" -or (& $get "deploy_executed" "") -eq "true")
    $ciBad = $false
    if ($ci -eq "failure") { $ciBad = $true }
    elseif ($ci -eq "unknown" -and $rate -match '^0?\.[0-9]+$') {
        if ([double]$rate -lt 0.5) { $ciBad = $true }
    }

    # モード決定: 引数 > 前回 state > auto
    if (-not $Mode) { $Mode = & $get "prev_mode" "" }
    if (-not $Mode -or $Mode -eq "null") { $Mode = "auto" }
    if ($Mode -ne "auto" -and $Mode -ne "manual") { $Mode = "auto" }

    $lockedByUser = (& $get "prev_locked_by_user" "false") -eq "true"
    $unlock = $false
    $primary = ""
    $specialized = ""
    $confidence = "0.50"
    $reason = ""
    $transition = "new"
    $used = New-Object System.Collections.Generic.List[string]

    # ---- 1) explicit ----
    if ($Explicit -eq "auto") {
        $Mode = "auto"; $lockedByUser = $false; $Explicit = ""; $transition = "unlocked"; $unlock = $true
    }
    if (-not $Explicit -and $Mode -eq "manual" -and (& $get "prev_primary_goal" "")) {
        $Explicit = & $get "prev_primary_goal" ""
        $lockedByUser = $true
        $prevSpec = & $get "prev_specialized_goal" ""
        if ($prevSpec -and $prevSpec -ne "null") { $specialized = $prevSpec }
    }

    if ($Explicit) {
        if (Test-GoalRouterIsPrimary -Goal $Explicit) {
            $primary = $Explicit
        }
        elseif (Test-GoalRouterIsSpecialized -Goal $Explicit) {
            $specialized = $Explicit
            $primary = Get-GoalRouterPrimaryFor -Specialized $Explicit
        }
        else {
            $used.Add("explicit_unknown:$Explicit")
            $Explicit = ""
        }
    }

    if ($Explicit) {
        $confidence = "1.00"
        $reason = "explicit:$Explicit"
        $used.Add("explicit:$Explicit")
        if ($lockedByUser -and $Trigger -ne "user") { $reason = "manual-lock:$Explicit" }

        # Security Critical は明示指定より優先 (§7)
        if ($sec -gt 0 -and $specialized -ne "security-emergency") {
            if (-not (Test-GoalRouterAllows -Primary $primary -Specialized "security-emergency")) {
                $primary = "deep-debug"
            }
            $specialized = "security-emergency"
            $reason = "security-critical-override:$Explicit"
            $confidence = "0.95"
            $used.Add("security_critical:$sec")
        }
    }
    else {
        # ---- 2) auto routing (§7 優先順位) ----
        $intentClass = & $get "intent_class" ""
        if (-not $intentClass) { $intentClass = Get-GoalRouterIntentClass -Intent $intent }

        if ($sec -gt 0) {
            $primary = "deep-debug"; $specialized = "security-emergency"
            $confidence = "0.95"; $reason = "security-critical"; $used.Add("security_critical:$sec")
        }
        elseif ($rtHealth -eq "down") {
            $primary = "deep-debug"; $confidence = "0.90"
            $reason = "runtime-incident (health check down)"; $used.Add("runtime_health:down")
            if ($inProd) { $specialized = "hotfix"; $used.Add("in_production:true") }
        }
        elseif ($ciBad) {
            $primary = "deep-debug"; $confidence = "0.85"; $reason = "ci-failure"; $used.Add("ci:$ci")
            if ($pm -eq "maintenance" -or $pm -eq "released") { $specialized = "hotfix"; $used.Add("phase_mode:$pm") }
        }
        elseif ($cf -eq "failure") {
            $primary = "deep-debug"; $confidence = "0.80"; $reason = "cloudflare-deploy-failure"; $used.Add("cf_deploy:failure")
        }
        elseif ($intentClass) {
            $parts = $intentClass -split ' ', 2
            $primary = $parts[0]
            $specialized = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            if ($specialized -eq $primary) { $specialized = "" }
            $confidence = "0.80"
            $reason = "user-intent:$primary$(if ($specialized) { "/$specialized" })"
            $used.Add("user_intent:$primary")
        }
        elseif ($rtErrors -ge $RuntimeErrorThreshold) {
            $primary = "deep-debug"; $confidence = "0.75"
            $reason = "runtime errors in log ($rtErrors >= $RuntimeErrorThreshold)"
            $used.Add("runtime_errors:$rtErrors")
            if ($inProd) { $specialized = "hotfix" }
        }
        elseif ((& $get "deploy_ready" "") -eq "true") {
            $primary = "product-assurance"; $specialized = "production-release"; $confidence = "0.80"
            $reason = "deploy.ready=true (human signoff wait)"; $used.Add("deploy_ready:true")
        }
        elseif ((& $get "exec_phase" "") -eq "Release") {
            $primary = "product-assurance"; $specialized = "production-release"; $confidence = "0.75"
            $reason = "execution.phase=Release"; $used.Add("exec_phase:Release")
        }
        elseif (($blocked -gt 0 -or $blockers -gt 0) -and ($pm -eq "maintenance" -or $pm -eq "released")) {
            $primary = "deep-debug"; $specialized = "hotfix"; $confidence = "0.70"
            $reason = "blocker in maintenance"; $used.Add("blocked_issues:$blocked"); $used.Add("phase_mode:$pm")
        }
        elseif ((& $get "stable_achieved" "") -eq "true" -and $pm -eq "development") {
            $primary = "product-assurance"; $confidence = "0.70"
            $reason = "stable achieved -> release assurance"
            $used.Add("stable_achieved:true"); $used.Add("phase_mode:development")
        }
        elseif ($pm -eq "maintenance" -or $pm -eq "released") {
            $primary = "development"; $confidence = "0.70"
            $reason = "phase_mode=$pm (continuous improvement)"; $used.Add("phase_mode:$pm")
        }
        elseif ((& $get "legacy_goal_type" "") -and (Test-GoalRouterIsGoal -Goal (& $get "legacy_goal_type" ""))) {
            $legacy = & $get "legacy_goal_type" ""
            $mapped = ConvertFrom-GoalRouterLegacyGoalType -GoalType $legacy
            $parts = $mapped.Trim() -split ' ', 2
            $primary = $parts[0]
            $specialized = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            if ($specialized -eq $primary) { $specialized = "" }
            $confidence = "0.60"; $reason = "legacy goal_type=$legacy"; $used.Add("legacy_goal_type:$legacy")
        }
        elseif ((& $get "state_present" "0") -eq "0" -or ((& $get "has_ci" "0") -eq "0" -and (& $get "has_tests" "0") -eq "0") -or ((ConvertTo-GoalRouterInt -Value (& $get "git_commits" "0") -Default 0) -le 5)) {
            $primary = "mvp-release"; $confidence = "0.55"
            $reason = "new/early project (no state, ci, tests or few commits)"
            $used.Add("has_ci:$(& $get "has_ci" "0")"); $used.Add("has_tests:$(& $get "has_tests" "0")"); $used.Add("git_commits:$(& $get "git_commits" "0")")
        }
        else {
            $primary = "development"; $confidence = "0.50"
            $reason = "default (existing project, no stronger evidence)"
            $used.Add("phase_mode:$(if ($pm) { $pm } else { 'unknown' })"); $used.Add("ci:$ci")
        }

        if ($ci -eq "success") { $used.Add("ci:success") }
    }

    # ---- 3) Flapping 防止: session lock ----
    $sessionLocked = $true
    $prevP = & $get "prev_primary_goal" ""
    $prevS = & $get "prev_specialized_goal" ""
    if ($prevS -eq "null") { $prevS = "" }

    if (-not $Explicit -and $prevP -and (Test-GoalRouterIsPrimary -Goal $prevP) -and (-not $unlock) `
            -and (& $get "prev_session_locked" "") -eq "true" -and (-not $ForceReroute)) {

        $prevEpoch = ConvertTo-GoalRouterEpoch -Timestamp (& $get "prev_last_routed_at" "")
        $nowEpoch = [int64][datetimeoffset]::UtcNow.ToUnixTimeSeconds()
        $ageMin = if ($prevEpoch -eq 0) { $LockMinutes + 1 } else { [int](($nowEpoch - $prevEpoch) / 60) }

        # 重大変化 = reroute 条件
        $critical = $false
        if ($sec -gt 0 -and ((& $get "prev_snap_security_critical" "0") -eq "0" -or -not (& $get "prev_snap_security_critical" ""))) { $critical = $true }
        if ($ciBad -and (& $get "prev_snap_ci" "") -ne "failure") { $critical = $true }
        if ($rtHealth -eq "down" -and (& $get "prev_snap_runtime_health" "") -ne "down") { $critical = $true }
        $prevDr = & $get "prev_snap_deploy_ready" ""
        if ($prevDr -and $prevDr -ne (& $get "deploy_ready" "")) { $critical = $true }
        $prevPm = & $get "prev_snap_phase_mode" ""
        if ($prevPm -and $prevPm -ne $pm) { $critical = $true }
        if ($intent) { $critical = $true }
        if ($Trigger -in @("user", "reroute", "goal-reached")) { $critical = $true }

        if ((-not $critical) -and $ageMin -le $LockMinutes) {
            if ($prevP -ne $primary -or $prevS -ne $specialized) {
                $reason = "locked:kept $prevP$(if ($prevS) { "/$prevS" }) (candidate $primary$(if ($specialized) { "/$specialized" }): $reason)"
                $primary = $prevP
                $specialized = $prevS
                $used.Add("session_lock:${ageMin}m")
            }
            $transition = "kept"
        }
        elseif ($critical) { $transition = "reroute" }
        else { $transition = "lock-expired" }
    }

    if ($transition -eq "new" -and $prevP) { $transition = "routed" }
    if ($prevP -and $prevP -eq $primary -and $prevS -eq $specialized -and $transition -notin @("kept", "unlocked")) {
        $transition = "unchanged"
    }

    # ---- 4) 整合性 / fail-safe ----
    $fallback = $false
    if (-not (Test-GoalRouterIsPrimary -Goal $primary)) {
        $fallback = $true
        $legacy = & $get "legacy_goal_type" ""
        if ($legacy -and (Test-GoalRouterIsGoal -Goal $legacy)) {
            $mapped = ConvertFrom-GoalRouterLegacyGoalType -GoalType $legacy
            $parts = $mapped.Trim() -split ' ', 2
            $primary = $parts[0]
            $specialized = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        }
        elseif ($pm -eq "maintenance" -or $pm -eq "released") {
            $primary = "development"; $specialized = ""
        }
        else {
            $primary = "mvp-release"; $specialized = ""
        }
        if ($specialized -eq $primary) { $specialized = "" }
        $reason = "fallback:$(if ($reason) { $reason } else { 'router-error' })"
        $confidence = "0.30"
    }

    if ($specialized -and -not (Test-GoalRouterAllows -Primary $primary -Specialized $specialized)) {
        $used.Add("specialized_rejected:$specialized")
        $specialized = ""
    }

    $effective = if ($specialized) { $specialized } else { $primary }
    $plane = & $get "execution_plane" "local"
    if ($plane -ne "managed" -and $plane -ne "local") { $plane = "local" }

    return [pscustomobject]@{
        Primary       = $primary
        Specialized   = $specialized
        Effective     = $effective
        Confidence    = $confidence
        Reason        = $reason
        EvidenceUsed  = @($used)
        Transition    = $transition
        Mode          = $Mode
        LockedByUser  = $lockedByUser
        SessionLocked = $sessionLocked
        Fallback      = $fallback
        Plane         = $plane
        Snapshot      = [pscustomobject]@{
            DeployReady     = & $get "deploy_ready" ""
            PhaseMode       = $pm
            SecurityCritical = [string]$sec
            Ci              = $ci
            RuntimeHealth   = $rtHealth
        }
    }
}

# ------------------------------------------------------------
# 永続化 (state.json)
# ------------------------------------------------------------

function Save-GoalRouterState {
    <#
    .SYNOPSIS
        Routing 結果を state.json の goal_router ブロックへ原子的に書き込む。
    .DESCRIPTION
        他キーは変更しない。一時ファイルへ書いてから置換することで、
        書き込み途中の state.json 破損を避ける (Claude 側 persist と同じ方針)。
        state.json が存在しない / 壊れている場合は何もせず $false を返し、起動を止めない。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Route
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $false }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $false
    }
    if ($null -eq $state -or -not ($state -is [psobject])) { return $false }

    $block = [ordered]@{
        mode                 = $Route.Mode
        primary_goal         = $Route.Primary
        specialized_goal     = if ($Route.Specialized) { $Route.Specialized } else { $null }
        effective_goal_type  = $Route.Effective
        confidence           = [double]$Route.Confidence
        reason               = $Route.Reason
        evidence             = @($Route.EvidenceUsed)
        locked_by_user       = [bool]$Route.LockedByUser
        session_locked       = [bool]$Route.SessionLocked
        route_version        = $script:GoalRouterVersion
        last_routed_at       = [datetimeoffset]::UtcNow.ToString("o")
        last_transition_reason = $Route.Transition
        execution_plane      = $Route.Plane
        evidence_snapshot    = [ordered]@{
            deploy_ready     = $Route.Snapshot.DeployReady
            phase_mode       = $Route.Snapshot.PhaseMode
            security_critical = $Route.Snapshot.SecurityCritical
            ci               = $Route.Snapshot.Ci
            runtime_health   = $Route.Snapshot.RuntimeHealth
        }
    }

    # 既存の goal_router を差し替える (他キーは不変)。
    if ($state.PSObject.Properties.Name -contains "goal_router") {
        $state.goal_router = [pscustomobject]$block
    }
    else {
        $state | Add-Member -NotePropertyName "goal_router" -NotePropertyValue ([pscustomobject]$block) -Force
    }

    $json = $state | ConvertTo-Json -Depth 100
    $tempPath = "$StatePath.tmp-$([guid]::NewGuid().ToString('N').Substring(0,8))"

    try {
        Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Resolve-GoalRouter {
    <#
    .SYNOPSIS
        Evidence 収集 → Routing → (任意で) state.json 永続化 をまとめて行う。
    .PARAMETER Goal
        "auto" または明示的な Goal 名 (Primary / Specialized)。
    .PARAMETER Trigger
        auto | user | cli | cron | supervisor-start | goal-reached | reroute
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [AllowEmptyString()][string]$Goal = "",
        [AllowEmptyString()][string]$Intent = "",
        [string]$Trigger = "auto",
        [switch]$NoPersist,
        [switch]$SkipGitHub,
        [switch]$SkipRuntime,
        [int]$LockMinutes = $script:DefaultLockMinutes
    )

    $evidence = Get-GoalRouterEvidence -ProjectDir $ProjectDir -Intent $Intent `
        -SkipGitHub:$SkipGitHub -SkipRuntime:$SkipRuntime

    $route = Invoke-GoalRouterRoute -Evidence $evidence -Explicit $Goal -Trigger $Trigger -LockMinutes $LockMinutes

    if (-not $NoPersist) {
        $statePath = Join-Path $ProjectDir "state.json"
        [void](Save-GoalRouterState -StatePath $statePath -Route $route)
    }

    return $route
}

# ------------------------------------------------------------
# Goal テンプレート解決
# ------------------------------------------------------------

function Get-GoalTemplateDirectory {
    <#
    .SYNOPSIS
        Goal テンプレートの探索順を返す (プロジェクト優先、無ければリポジトリ同梱)。
    #>
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    return @(
        (Join-Path $ProjectDir "config/goals"),
        (Join-Path $ProjectDir ".codex/goals"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "config/goals"),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "config/goals")
    )
}

function Get-GoalTemplatePath {
    <#
    .SYNOPSIS
        effective goal_type に対応するテンプレートの絶対パスを返す。
    .DESCRIPTION
        見つからなければ mvp-release へフォールバックする。両方無ければ $null。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$GoalType
    )

    foreach ($dir in Get-GoalTemplateDirectory -ProjectDir $ProjectDir) {
        $candidate = Join-Path $dir "$GoalType.md"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    foreach ($dir in Get-GoalTemplateDirectory -ProjectDir $ProjectDir) {
        $fallback = Join-Path $dir "mvp-release.md"
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    }
    return $null
}

Export-ModuleMember -Function @(
    "Get-GoalRouterPrimaryGoals",
    "Get-GoalRouterSpecializedGoals",
    "Get-GoalRouterDefaultLockMinutes",
    "Test-GoalRouterIsPrimary",
    "Test-GoalRouterIsSpecialized",
    "Test-GoalRouterIsGoal",
    "Get-GoalRouterLabelJa",
    "Get-GoalRouterPrimaryFor",
    "Test-GoalRouterAllows",
    "ConvertFrom-GoalRouterLegacyGoalType",
    "Get-GoalRouterIntentClass",
    "Get-GoalRouterEvidence",
    "Invoke-GoalRouterRoute",
    "Save-GoalRouterState",
    "Resolve-GoalRouter",
    "Get-GoalTemplateDirectory",
    "Get-GoalTemplatePath"
)
