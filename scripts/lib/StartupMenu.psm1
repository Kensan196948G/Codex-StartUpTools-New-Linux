Set-StrictMode -Version Latest

$script:MenuVersion = "1.0"
$script:MenuTitle   = "Codex StartUp Tools"
$script:MenuSubtitle = "Linux / Codex only / Supervisor ready"

# ---------------------------------------------------------------
# メニュー定義
# ---------------------------------------------------------------

function Get-MenuItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $localDir = if ($Config.projectsDir) { $Config.projectsDir } elseif ($env:HOME) { Join-Path $env:HOME "Projects" } else { "/home/kensan/Projects" }

    $items = [System.Collections.Generic.List[pscustomobject]]::new()

    # --- ローカルセクション ---
    $items.Add([pscustomobject]@{
        Key     = 'L1'
        Label   = "Codex を起動"
        Note    = "Linux ($localDir) / full-auto"
        Section = "Linux registered projects ($localDir)"
        Action  = 'launch-local-codex'
        Enabled = $true
    })

    # --- 診断・セットアップセクション ---
    $items.Add([pscustomobject]@{
        Key     = '1'
        Label   = "プロジェクトダッシュボード"
        Note    = "Git / テスト / Token / フェーズを表示"
        Section = "診断・セットアップ"
        Action  = 'show-dashboard'
        Enabled = $true
    })
    $items.Add([pscustomobject]@{
        Key     = '2'
        Label   = "MCP ヘルスチェック"
        Note    = "MCP サーバーの状態を確認"
        Section = $null
        Action  = 'mcp-health'
        Enabled = $true
    })
    $items.Add([pscustomobject]@{
        Key     = '3'
        Label   = "Architecture Check"
        Note    = "設計違反・秘密情報の静的解析"
        Section = $null
        Action  = 'arch-check'
        Enabled = $true
    })
    $items.Add([pscustomobject]@{
        Key     = '4'
        Label   = "Worktree Manager"
        Note    = "Git worktree の一覧・作成・削除"
        Section = $null
        Action  = 'worktree'
        Enabled = $true
    })
    $items.Add([pscustomobject]@{
        Key     = '5'
        Label   = "Token Budget 確認"
        Note    = "トークン使用状況と残量ゾーンを表示"
        Section = $null
        Action  = 'token-budget'
        Enabled = $true
    })
    $items.Add([pscustomobject]@{
        Key     = '6'
        Label   = "Bootstrap 実行 (preflight)"
        Note    = "設定・ツール・CI の事前確認"
        Section = $null
        Action  = 'bootstrap'
        Enabled = $true
    })

    # --- 最近のプロジェクトセクション ---
    $items.Add([pscustomobject]@{
        Key     = '7'
        Label   = "最近のプロジェクト一覧"
        Note    = "履歴から再起動"
        Section = "プロジェクト管理"
        Action  = 'recent-projects'
        Enabled = $Config.recentProjects.enabled -eq $true
    })
    $items.Add([pscustomobject]@{
        Key     = '8'
        Label   = "Supervisor 適用"
        Note    = "登録プロジェクトに .codex/supervisor.json を配布"
        Section = $null
        Action  = 'apply-supervisor'
        Enabled = $Config.supervisor.enabled -eq $true
    })
    $items.Add([pscustomobject]@{
        Key     = '9'
        Label   = "Supervisor レポート"
        Note    = "登録プロジェクトの適用状況を一覧表示"
        Section = $null
        Action  = 'supervisor-report'
        Enabled = $Config.supervisor.enabled -eq $true
    })
    $items.Add([pscustomobject]@{
        Key     = '10'
        Label   = "MessageBus ログ確認"
        Note    = "フェーズ遷移・CI メッセージを表示"
        Section = $null
        Action  = 'message-bus'
        Enabled = $true
    })

    # --- 終了 ---
    $items.Add([pscustomobject]@{
        Key     = '0'
        Label   = "終了"
        Note    = ""
        Section = $null
        Action  = 'exit'
        Enabled = $true
    })

    return $items
}

# ---------------------------------------------------------------
# ヘッダー・フッター表示
# ---------------------------------------------------------------

function Write-MenuHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [string]$ProjectRoot = ""
    )

    $width = 62
    $border = "=" * $width

    Write-Host ""
    Write-Host (" $border") -ForegroundColor Cyan
    Write-Host ("   $script:MenuTitle  v$script:MenuVersion") -ForegroundColor White
    Write-Host ("   $script:MenuSubtitle") -ForegroundColor Cyan
    Write-Host (" $border") -ForegroundColor Cyan

    # ダッシュボード情報（軽量版）
    if ($ProjectRoot -and (Test-Path $ProjectRoot)) {
        try {
            Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/ProjectDashboard.psm1") -Force -ErrorAction SilentlyContinue
            $info = Get-ProjectDashboardInfo -ProjectRoot $ProjectRoot -ErrorAction SilentlyContinue
            if ($info) {
                $stableIcon = if ($info.Phase.Stable) { "[STABLE]" } else { "[unstable]" }
                $stableColor = if ($info.Phase.Stable) { "Green" } else { "Yellow" }
                $cleanIcon = if ($info.Git.IsClean) { "clean" } else { "dirty" }
                Write-Host ""
                Write-Host ("  Branch : {0,-20} ({1})  Tests : {2}" -f $info.Git.Branch, $cleanIcon, $info.Tests.TestFileCount) -ForegroundColor Cyan
                Write-Host ("  Phase  : {0,-20} {1}" -f $info.Phase.Current, $stableIcon) -ForegroundColor $stableColor
            }
        }
        catch { }
    }
    Write-Host ""
}

function Write-MenuSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    Write-Host ("  -- {0} --" -f $Title) -ForegroundColor Yellow
}

function Write-MenuItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item
    )

    $keyPad = $Item.Key.PadLeft(3)
    $note = if ($Item.Note) { "  [{0}]" -f $Item.Note } else { "" }

    if ($Item.Enabled) {
        Write-Host ("    {0}.  {1}{2}" -f $keyPad, $Item.Label, $note) -ForegroundColor White
    }
    else {
        Write-Host ("    {0}.  {1}  [無効]" -f $keyPad, $Item.Label) -ForegroundColor Yellow
    }
}

function Show-Menu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [string]$ProjectRoot = ""
    )

    if (-not [Console]::IsOutputRedirected) {
        Clear-Host
    }
    Write-MenuHeader -Config $Config -ProjectRoot $ProjectRoot

    $items = Get-MenuItems -Config $Config
    $currentSection = ""

    foreach ($item in $items) {
        if ($item.Key -eq '0') {
            Write-Host ""
        }

        if ($item.Section -and $item.Section -ne $currentSection) {
            Write-Host ""
            Write-MenuSection -Title $item.Section
            $currentSection = $item.Section
        }

        Write-MenuItem -Item $item
    }

    Write-Host ""
    Write-Host (" {0}" -f ("=" * 62)) -ForegroundColor Cyan
    Write-Host ""

    return $items
}

# ---------------------------------------------------------------
# 入力処理
# ---------------------------------------------------------------

function Read-MenuChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$Items
    )

    $choice = Read-Host "  選択してください"
    $choice = $choice.Trim().ToUpper()

    $found = $Items | Where-Object { $_.Key.ToUpper() -eq $choice -and $_.Enabled }
    if ($found) {
        return $found
    }

    return $null
}

# ---------------------------------------------------------------
# アクション実行
# ---------------------------------------------------------------

function Invoke-MenuAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item,

        [Parameter(Mandatory)]
        [object]$Config,

        [string]$ProjectRoot = "",
        [string]$StatePath = ""
    )

    switch ($Item.Action) {
        'show-dashboard' {
            Invoke-DashboardAction -ProjectRoot $ProjectRoot -StatePath $StatePath
        }
        'mcp-health' {
            Invoke-McpHealthAction -ProjectRoot $ProjectRoot
        }
        'arch-check' {
            Invoke-ArchCheckAction -ProjectRoot $ProjectRoot
        }
        'worktree' {
            Invoke-WorktreeAction -ProjectRoot $ProjectRoot
        }
        'token-budget' {
            Invoke-TokenBudgetAction -StatePath $StatePath -ProjectRoot $ProjectRoot
        }
        'bootstrap' {
            Invoke-BootstrapAction -ProjectRoot $ProjectRoot
        }
        'recent-projects' {
            Invoke-RecentProjectsAction -Config $Config
        }
        'message-bus' {
            Invoke-MessageBusAction -StatePath $StatePath
        }
        'launch-local-codex' {
            Invoke-LaunchAction -Config $Config -Tool 'codex' -Mode 'local' -ProjectRoot $ProjectRoot
        }
        'apply-supervisor' {
            Invoke-SupervisorAction -Config $Config -ProjectRoot $ProjectRoot
        }
        'supervisor-report' {
            Invoke-SupervisorReportAction -Config $Config
        }
        'exit' {
            return $false
        }
        default {
            Write-Host "  [INFO] この機能は未実装です: $($Item.Action)" -ForegroundColor Yellow
        }
    }

    return $true
}

function Invoke-DashboardAction {
    param([string]$ProjectRoot, [string]$StatePath)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/ProjectDashboard.psm1") -Force -ErrorAction SilentlyContinue
        Show-ProjectDashboard -ProjectRoot $ProjectRoot -StatePath $StatePath | Out-Null
    }
    catch {
        Write-Host "  [ERROR] ダッシュボード表示エラー: $_" -ForegroundColor Red
    }
    Wait-MenuInput
}

function Invoke-McpHealthAction {
    param([string]$ProjectRoot)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/McpHealthCheck.psm1") -Force -ErrorAction SilentlyContinue
        $report = Get-McpHealthReport -ProjectRoot $ProjectRoot
        Write-Host "  MCP ヘルスチェック結果:" -ForegroundColor Cyan
        Write-Host ("  {0}" -f $report.Summary)
        foreach ($entry in $report.Entries) {
            $color = if ($entry.Healthy) { "Green" } else { "Red" }
            $icon = if ($entry.Healthy) { "[OK]  " } else { "[WARN]" }
            Write-Host ("    {0} {1}" -f $icon, $entry.Name) -ForegroundColor $color
        }
    }
    catch {
        Write-Host "  [ERROR] MCP ヘルスチェックエラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-ArchCheckAction {
    param([string]$ProjectRoot)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/ArchitectureCheck.psm1") -Force -ErrorAction SilentlyContinue
        $result = Show-ArchitectureCheckReport -Path (Join-Path $ProjectRoot "scripts")
        Write-Host ""
    }
    catch {
        Write-Host "  [ERROR] Architecture Check エラー: $_" -ForegroundColor Red
    }
    Wait-MenuInput
}

function Invoke-WorktreeAction {
    param([string]$ProjectRoot)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/WorktreeManager.psm1") -Force -ErrorAction SilentlyContinue
        $worktrees = @(Get-Worktree -ProjectRoot $ProjectRoot -ErrorAction SilentlyContinue)
        Write-Host "  Git Worktree 一覧:" -ForegroundColor Cyan
        if ($worktrees.Count -eq 0) {
            Write-Host "    (worktree なし)" -ForegroundColor Yellow
        }
        else {
            $worktrees | ForEach-Object { Write-Host ("    {0}" -f $_) }
        }
    }
    catch {
        Write-Host "  [ERROR] Worktree 情報取得エラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-TokenBudgetAction {
    param([string]$StatePath, [string]$ProjectRoot)
    Write-Host ""
    if (-not $StatePath) { $StatePath = Join-Path $ProjectRoot "state.json" }
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/TokenBudget.psm1") -Force -ErrorAction SilentlyContinue
        $status = Get-TokenBudgetStatus -StatePath $StatePath
        Write-Host "  Token Budget 状況:" -ForegroundColor Cyan
        Write-Host ("    使用済み  : {0}%" -f $status.UsedPercent)
        Write-Host ("    残量      : {0}%" -f (100 - $status.UsedPercent))
        Write-Host ("    ゾーン    : {0}" -f $status.Zone.Label) -ForegroundColor $(
            switch ($status.Zone.Label) {
                "Red"    { "Red" }
                "Orange" { "Yellow" }
                "Yellow" { "Yellow" }
                default  { "Green" }
            }
        )
    }
    catch {
        Write-Host "  [ERROR] Token Budget エラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-BootstrapAction {
    param([string]$ProjectRoot)
    Write-Host ""
    Write-Host "  Bootstrap (preflight) を実行します..." -ForegroundColor Cyan
    Write-Host ""
    $bootstrapScript = Join-Path $ProjectRoot "scripts/main/Start-CodexBootstrap.ps1"
    if (Test-Path $bootstrapScript) {
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript -NonInteractive
    }
    else {
        Write-Host "  [ERROR] Bootstrap スクリプトが見つかりません: $bootstrapScript" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-RecentProjectsAction {
    param([object]$Config)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/Config.psm1") -Force -ErrorAction SilentlyContinue
        $historyPath = $Config.recentProjects.historyFile
        if ($historyPath) {
            $historyPath = [System.Environment]::ExpandEnvironmentVariables($historyPath)
        }
        $projects = @(Get-RecentProject -HistoryPath $historyPath -ErrorAction SilentlyContinue)
        Write-Host "  最近のプロジェクト:" -ForegroundColor Cyan
        if ($projects.Count -eq 0) {
            Write-Host "    (履歴なし)" -ForegroundColor Yellow
        }
        else {
            $i = 1
            $projects | Select-Object -First 10 | ForEach-Object {
                $result = if ($_.result) { $_.result } else { "unknown" }
                $color = if ($result -eq 'success') { "Green" } elseif ($result -eq 'failure') { "Red" } else { "Yellow" }
                Write-Host ("    {0,2}. {1,-30} [{2}]" -f $i, $_.project, $result) -ForegroundColor $color
                $i++
            }
        }
    }
    catch {
        Write-Host "  [ERROR] プロジェクト履歴取得エラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-MessageBusAction {
    param([string]$StatePath)
    Write-Host ""
    if (-not (Test-Path $StatePath)) {
        Write-Host "  [INFO] state.json が見つかりません: $StatePath" -ForegroundColor Yellow
        Wait-MenuInput
        return
    }
    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "  MessageBus ログ (phase.transition):" -ForegroundColor Cyan
        $msgs = @($state.'message_bus'.'phase.transition')
        if ($msgs.Count -eq 0) {
            Write-Host "    (メッセージなし)" -ForegroundColor Yellow
        }
        else {
            $msgs | Select-Object -Last 5 | ForEach-Object {
                Write-Host ("    [{0}] {1} -> {2}  (by {3})" -f `
                    $_.timestamp, $_.payload.from, $_.payload.to, $_.publisher) -ForegroundColor Cyan
            }
        }
    }
    catch {
        Write-Host "  [ERROR] MessageBus ログエラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Read-SupervisorProjectSelection {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Candidates,

        [Parameter(Mandatory)]
        [string]$InputText
    )

    $choice = $InputText.Trim()
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "0") {
        return @()
    }

    if ($choice.Equals("all", [System.StringComparison]::OrdinalIgnoreCase)) {
        return @($Candidates | ForEach-Object { $_.name })
    }

    $selected = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @($choice -split ",")) {
        $trimmed = $token.Trim()
        if (-not ($trimmed -match '^\d+$')) {
            continue
        }

        $index = [int]$trimmed
        if ($index -lt 1 -or $index -gt $Candidates.Count) {
            continue
        }

        $name = $Candidates[$index - 1].name
        if ($name -notin $selected) {
            $selected.Add($name)
        }
    }

    return @($selected)
}

function Invoke-SupervisorAction {
    param([object]$Config, [string]$ProjectRoot)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/SupervisorManager.psm1") -Force -ErrorAction Stop
        $candidates = @(Get-RegisteredProjectCandidate -Config $Config)
        Write-Host "  Supervisor 適用候補:" -ForegroundColor Cyan
        if ($candidates.Count -eq 0) {
            Write-Host "    (登録プロジェクト候補なし)" -ForegroundColor Yellow
            Write-Host ""
            Wait-MenuInput
            return
        }

        $i = 1
        $candidates | Select-Object -First 80 | ForEach-Object {
            Write-Host ("    {0,2}. {1}  ({2})" -f $i, $_.name, $_.path) -ForegroundColor Cyan
            $i++
        }
        if ($candidates.Count -gt 80) {
            Write-Host ("    ... and {0} more" -f ($candidates.Count - 80)) -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "    入力例: 1,3,5 / all / 0" -ForegroundColor Yellow

        $selectionText = Read-Host "  適用する番号をカンマ区切りで入力してください"
        $selectedNames = @(Read-SupervisorProjectSelection -Candidates $candidates -InputText $selectionText)
        if ($selectedNames.Count -eq 0) {
            Write-Host "  [INFO] Supervisor 適用をキャンセルしました。" -ForegroundColor Yellow
            Write-Host ""
            Wait-MenuInput
            return
        }

        $preview = @(Set-SupervisorForRegisteredProjects -Config $Config -ProjectNames $selectedNames -PreviewOnly)
        Write-Host ""
        Write-Host "  適用予定:" -ForegroundColor Cyan
        $preview | ForEach-Object {
            Write-Host ("    {0} -> {1}" -f $_.project, $_.target) -ForegroundColor Cyan
        }

        $answer = (Read-Host "  選択した候補へ適用しますか? (yes/no)").Trim().ToLowerInvariant()
        if ($answer -ne "yes") {
            Write-Host "  [INFO] Supervisor 適用をキャンセルしました。" -ForegroundColor Yellow
            Write-Host ""
            Wait-MenuInput
            return
        }

        $results = @(Set-SupervisorForRegisteredProjects -Config $Config -ProjectNames $selectedNames)
        Write-Host ("  [OK] Supervisor 適用完了: {0} project(s)" -f $results.Count) -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] Supervisor 適用エラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

function Invoke-SupervisorReportAction {
    param([object]$Config)
    Write-Host ""
    try {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "lib/SupervisorManager.psm1") -Force -ErrorAction Stop
        $report = Get-SupervisorReport -Config $Config
        Write-Host "  Supervisor 適用レポート:" -ForegroundColor Cyan
        Write-Host ("    Total   : {0}" -f $report.total)
        Write-Host ("    Managed : {0}" -f $report.managed) -ForegroundColor Green
        Write-Host ("    Missing : {0}" -f $report.missing) -ForegroundColor Yellow
        Write-Host ("    Foreign : {0}" -f $report.foreign) -ForegroundColor Magenta
        Write-Host ("    Invalid : {0}" -f $report.invalid) -ForegroundColor Red
        Write-Host ""

        $i = 1
        $report.entries | ForEach-Object {
            $color = switch ($_.status) {
                "Managed" { "Green" }
                "Missing" { "Yellow" }
                "Foreign" { "Magenta" }
                "Invalid" { "Red" }
                default { "White" }
            }
            $detail = if ($_.hasSupervisor) { "{0} / {1}" -f $_.managedBy, $_.mode } else { "not applied" }
            Write-Host ("    {0,2}. [{1,-7}] {2}  ({3})" -f $i, $_.status, $_.project, $detail) -ForegroundColor $color
            $i++
        }
    }
    catch {
        Write-Host "  [ERROR] Supervisor レポートエラー: $_" -ForegroundColor Red
    }
    Write-Host ""
    Wait-MenuInput
}

# ---------------------------------------------------------------
# プロジェクト選択
# ---------------------------------------------------------------

function Get-LocalProjectList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseDir,

        [int]$MaxCount = 40
    )

    if (-not (Test-Path $BaseDir)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $BaseDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^\.' } |
            Sort-Object Name |
            Select-Object -First $MaxCount |
            ForEach-Object { $_.Name }
    )
}

function Get-RecentProjectNames {
    [CmdletBinding()]
    param(
        [string]$HistoryPath,
        [string]$Tool = '',
        [string]$Mode = '',
        [int]$MaxCount = 5
    )

    if (-not $HistoryPath -or -not (Test-Path $HistoryPath)) {
        return @()
    }

    try {
        $historyPath = [System.Environment]::ExpandEnvironmentVariables($HistoryPath)
        $entries = @(Get-RecentProject -HistoryPath $historyPath -ErrorAction SilentlyContinue)

        if ($Tool) {
            $entries = @($entries | Where-Object { $_.tool -eq $Tool })
        }
        if ($Mode) {
            $entries = @($entries | Where-Object { $_.mode -eq $Mode })
        }

        return @(
            $entries |
                Select-Object -ExpandProperty project -Unique |
                Select-Object -First $MaxCount
        )
    }
    catch {
        return @()
    }
}

function Show-ProjectSelector {
    [CmdletBinding()]
    param(
        [string[]]$RecentProjects = @(),
        [string[]]$AllProjects    = @(),
        [string]$BaseLabel        = ""
    )

    $listed   = [System.Collections.Generic.List[string]]::new()
    $indexMap = @{}  # 番号 -> プロジェクト名

    Write-Host ""

    # 最近使ったプロジェクト（先頭に表示）
    if ($RecentProjects.Count -gt 0) {
        Write-Host "  ★ 最近使ったプロジェクト:" -ForegroundColor Yellow
        foreach ($p in $RecentProjects) {
            if ($p -notin $listed) {
                $num = $listed.Count + 1
                $listed.Add($p)
                $indexMap[$num] = $p
                Write-Host ("    {0,2}. {1}" -f $num, $p) -ForegroundColor White
            }
        }
        Write-Host ""
    }

    # 全プロジェクト一覧（重複除外）
    $remaining = @($AllProjects | Where-Object { $_ -notin $listed })
    if ($remaining.Count -gt 0) {
        if ($RecentProjects.Count -gt 0) {
            Write-Host "  ── その他のプロジェクト ──" -ForegroundColor Cyan
        } else {
            Write-Host "  プロジェクト一覧:" -ForegroundColor Cyan
            if ($BaseLabel) {
                Write-Host ("  ベース: {0}" -f $BaseLabel) -ForegroundColor Cyan
            }
        }
        foreach ($p in $remaining) {
            $num = $listed.Count + 1
            $listed.Add($p)
            $indexMap[$num] = $p
            Write-Host ("    {0,2}. {1}" -f $num, $p) -ForegroundColor White
        }
        Write-Host ""
    }

    if ($listed.Count -eq 0) {
        Write-Host "  (プロジェクトが見つかりませんでした)" -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host "     0.  ベースパスで起動（プロジェクト指定なし）" -ForegroundColor Cyan
    Write-Host ""

    # 選択入力
    $choice = (Read-Host "  番号を選択（または直接プロジェクト名を入力）").Trim()

    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') {
        return ''
    }

    # 数字ならインデックス変換
    if ($choice -match '^\d+$') {
        $idx = [int]$choice
        if ($indexMap.ContainsKey($idx)) {
            return $indexMap[$idx]
        }
    }

    # そのままプロジェクト名として扱う（直接テキスト入力）
    return $choice
}

function Select-ProjectInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [string]$Mode      = 'local',
        [string]$Tool      = 'codex'
    )

    $historyPath = $Config.recentProjects.historyFile

    $localBase = if ($Config.projectsDir) { $Config.projectsDir } elseif ($env:HOME) { Join-Path $env:HOME "Projects" } else { "/home/kensan/Projects" }

    $allProjects    = @(Get-LocalProjectList -BaseDir $localBase)
    $recentProjects = @(Get-RecentProjectNames -HistoryPath $historyPath -Tool $Tool -Mode 'local')

    return Show-ProjectSelector `
        -RecentProjects $recentProjects `
        -AllProjects    $allProjects `
        -BaseLabel      $localBase
}

function Invoke-LaunchAction {
    param(
        [object]$Config,
        [string]$Tool,
        [string]$Mode,
        [string]$ProjectRoot
    )

    Write-Host ""

    # ツール設定確認
    $toolConfig = $Config.tools.PSObject.Properties[$Tool]?.Value
    if (-not $toolConfig -or -not $toolConfig.enabled) {
        Write-Host ("  [WARN] {0} は config.json で無効化されています。" -f $Tool) -ForegroundColor Yellow
        Write-Host "         config/config.json の tools.$Tool.enabled を true に変更してください。" -ForegroundColor Yellow
        Write-Host ""
        Wait-MenuInput
        return
    }

    $cmd  = $toolConfig.command
    $toolArgs = @($toolConfig.args)

    # コマンド存在確認
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host ("  [ERROR] コマンドが見つかりません: {0}" -f $cmd) -ForegroundColor Red
        Write-Host ("          インストールコマンド: {0}" -f $toolConfig.installCommand) -ForegroundColor Yellow
        Write-Host ""
        Wait-MenuInput
        return
    }

    $localBase = if ($Config.projectsDir) { $Config.projectsDir } elseif ($env:HOME) { Join-Path $env:HOME "Projects" } else { "/home/kensan/Projects" }

    $project = Select-ProjectInteractive -Config $Config -Mode 'local' -Tool $Tool
    $workDir = if ([string]::IsNullOrWhiteSpace($project)) {
        $localBase
    } else {
        Join-Path $localBase $project
    }

    if (-not (Test-Path $workDir)) {
        Write-Host ("  [ERROR] ディレクトリが見つかりません: {0}" -f $workDir) -ForegroundColor Red
        Write-Host ""
        Wait-MenuInput
        return
    }

    Write-Host ("  {0} を起動します: {1}" -f $cmd, $workDir) -ForegroundColor Green
    Write-Host ""

    $previous = Get-Location
    try {
        Set-Location $workDir

        & $cmd @toolArgs
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location $previous
    }

    Write-Host ""
    if ($exitCode -ne 0) {
        Write-Host ("  [WARN] {0} が終了コード {1} で終了しました。" -f $cmd, $exitCode) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0} が正常に終了しました。" -f $cmd) -ForegroundColor Green
    }

    # RecentProjects 更新（エラーは無視）
    try {
        $historyPath = $Config.recentProjects.historyFile
        if ($historyPath -and $Config.recentProjects.enabled) {
            $historyPath = [System.Environment]::ExpandEnvironmentVariables($historyPath)
            $result = if ($exitCode -eq 0) { 'success' } else { 'failure' }
            $projName = if ($project) { $project } else { 'default' }
            Update-RecentProject -ProjectName $projName -Tool $Tool -Mode $Mode `
                -Result $result -ElapsedMs 0 `
                -HistoryPath $historyPath -MaxHistory $Config.recentProjects.maxHistory `
                -ErrorAction SilentlyContinue
        }
    }
    catch { }

    Write-Host ""
    Wait-MenuInput
}

# ---------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------

function Wait-MenuInput {
    Write-Host "  [Enter] でメニューに戻ります..." -ForegroundColor Cyan
    $null = Read-Host
}

# ---------------------------------------------------------------
# メインループ
# ---------------------------------------------------------------

function Start-InteractiveMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [string]$ProjectRoot = "",
        [string]$StatePath = "",
        [int]$MaxLoops = 0
    )

    $loopCount = 0
    $running = $true

    while ($running) {
        $loopCount++
        if ($MaxLoops -gt 0 -and $loopCount -gt $MaxLoops) {
            break
        }

        $items = Show-Menu -Config $Config -ProjectRoot $ProjectRoot
        $choice = Read-MenuChoice -Items $items

        if (-not $choice) {
            Write-Host "  [WARN] 無効な選択です。もう一度入力してください。" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        if ($choice.Action -eq 'exit') {
            Write-Host ""
            Write-Host "  終了します。" -ForegroundColor Cyan
            Write-Host ""
            $running = $false
            break
        }

        $continue = Invoke-MenuAction -Item $choice -Config $Config `
            -ProjectRoot $ProjectRoot -StatePath $StatePath

        if (-not $continue) {
            $running = $false
        }
    }
}

Export-ModuleMember -Function @(
    'Get-MenuItems',
    'Write-MenuHeader',
    'Write-MenuSection',
    'Write-MenuItem',
    'Show-Menu',
    'Read-MenuChoice',
    'Invoke-MenuAction',
    'Start-InteractiveMenu',
    'Wait-MenuInput',
    'Get-LocalProjectList',
    'Get-RecentProjectNames',
    'Show-ProjectSelector',
    'Read-SupervisorProjectSelection',
    'Invoke-SupervisorReportAction',
    'Select-ProjectInteractive'
)
