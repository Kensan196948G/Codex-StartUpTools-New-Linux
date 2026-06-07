# モジュール移植メモ

このドキュメントは `scripts/lib/` 内の各モジュールの移植状況を記録します。
参照元リポジトリ: `https://github.com/Kensan196948G/Codex-StartUpTools-New-Windows.git`

---

## 移植分類

| 分類 | 説明 |
|---|---|
| ✅ そのまま移植 | 変更なし、またはパス調整のみ |
| ⚙️ 調整して移植 | 軽微な修正・Codex 向け最適化あり |
| 🔄 置換実装 | Codex 向けに再設計 |

---

## ArchitectureCheck.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ✅ そのまま移植 |
| **元の場所** | `scripts/lib/ArchitectureCheck.psm1` |
| **移植理由** | 静的な設計違反検査は Codex 側でもそのまま有効 |
| **差異** | `$script:ModuleDependencyRules` の対象スクリプト名が元リポジトリ依存（`Start-ClaudeCode.ps1` 等）。現在のプロジェクトには未存在。将来移植時に更新が必要 |
| **検証** | `tests/unit/ArchitectureCheck.Tests.ps1` |

---

## Config.psm1 / ConfigSchema.ps1 / ConfigLoader.ps1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/Config.psm1`, `scripts/lib/ConfigLoader.ps1`, `scripts/lib/ConfigSchema.ps1` |
| **移植理由** | 設定スキーマは再利用できるが、デフォルト値を Codex 主体に寄せた |
| **差異** | `config.json.template` を Linux / Codex only / registeredProjects / supervisor 構成へ変更。Claude / Copilot / SSH 設定は削除 |
| **検証** | `tests/unit/Config.Tests.ps1`, `tests/unit/ConfigSchema.Tests.ps1` |

---

## ErrorHandler.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ✅ そのまま移植 |
| **元の場所** | `scripts/lib/ErrorHandler.psm1` |
| **移植理由** | 分類付きエラー処理は Claude ランタイムに依存しない |
| **差異** | なし |
| **検証** | `tests/unit/ErrorHandler.Tests.ps1` |

---

## LauncherCommon.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/LauncherCommon.psm1` |
| **移植理由** | 共通ユーティリティは再利用可能 |
| **差異** | Codex デフォルトツール前提に一部のデフォルト値を変更 |
| **検証** | `tests/unit/LauncherCommon.Tests.ps1` |

---

## LogManager.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ✅ そのまま移植 |
| **元の場所** | `scripts/lib/LogManager.psm1` |
| **移植理由** | ログ運用は Claude ランタイムに依存しない |
| **差異** | なし |
| **検証** | `tests/unit/LogManager.Tests.ps1` |

---

## McpHealthCheck.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/McpHealthCheck.psm1` |
| **移植理由** | MCP ヘルス診断の基本ロジックは再利用可能 |
| **差異** | 監視対象の MCP を Codex 環境向けに変更。Claude 専用エンドポイントへの依存を除去 |
| **検証** | `tests/unit/McpHealthCheck.Tests.ps1` |

---

## MessageBus.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ✅ そのまま移植 |
| **元の場所** | `scripts/lib/MessageBus.psm1` |
| **移植理由** | state.json ベースの軽量メッセージ連携は Codex 側でも再利用しやすい |
| **差異** | なし |
| **検証** | `tests/unit/MessageBus.Tests.ps1` |

---

## RecentProjects.ps1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/RecentProjects.ps1` |
| **移植理由** | 最近使ったプロジェクト追跡は汎用的 |
| **差異** | 履歴ファイルのデフォルトパスを `/home/kensan/.codex-startup/` 以下に変更 |
| **検証** | `tests/unit/RecentProjects.Tests.ps1` |

---

## SessionTabManager.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/SessionTabManager.psm1` |
| **移植理由** | session.json の状態管理部分を Codex 向けに再利用 |
| **差異** | Claude セッション固有のフィールドを除去。Codex セッション情報向けに再構成 |
| **検証** | `tests/unit/SessionTabManager.Tests.ps1` |

---

## StatuslineManager.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/StatuslineManager.psm1` |
| **移植理由** | ステータスライン管理の基本構造は再利用可能 |
| **差異** | 同期先と運用前提を Codex 側に合わせて見直し |
| **検証** | `tests/unit/StatuslineManager.Tests.ps1` |

---

## TokenBudget.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ⚙️ 調整して移植 |
| **元の場所** | `scripts/lib/TokenBudget.psm1` |
| **移植理由** | 予算ロジックは汎用だが、リポジトリルート解決を Codex ローカル前提に簡素化 |
| **差異** | `$script:StartupRoot` 解決ロジックを簡素化。Codex セッション向けトークンゾーン定義を調整 |
| **検証** | `tests/unit/TokenBudget.Tests.ps1` |

---

## WorktreeManager.psm1

| 項目 | 内容 |
|---|---|
| **分類** | ✅ そのまま移植 |
| **元の場所** | `scripts/lib/WorktreeManager.psm1` |
| **移植理由** | Git worktree 管理は Codex 側でもそのまま利用価値が高い |
| **差異** | なし |
| **検証** | `tests/unit/WorktreeManager.Tests.ps1` |

---

## エントリポイント

### Start-Codex.ps1

| 項目 | 内容 |
|---|---|
| **分類** | 🔄 置換実装 |
| **元の対応** | `scripts/main/Start-ClaudeCode.ps1` 等 |
| **移植理由** | Codex を主ツールとした新規エントリポイントとして再設計 |
| **差異** | Claude 専用依存を除去し、`tools.defaultTool = codex` を前提とした起動フローに再設計 |
| **検証** | `tests/unit/StartCodex.Tests.ps1` |

### Start-CodexBootstrap.ps1

| 項目 | 内容 |
|---|---|
| **分類** | 🔄 置換実装 |
| **元の対応** | ClaudeOS 起動シーケンス群 |
| **移植理由** | Codex 向け preflight チェック・state 初期化・フェーズ遷移通知として新規設計 |
| **差異** | Claude hook・ClaudeOS シーケンスを除去。Codex ネイティブな preflight チェックに特化 |
| **検証** | `tests/unit/StartCodexBootstrap.Tests.ps1` |

---

---

## ProjectDashboard.psm1

| 項目 | 内容 |
|---|---|
| **分類** | 🔄 置換実装（Codex ネイティブ新規） |
| **元の対応** | 参照フォルダの `Start-Menu.ps1`・`Show-SessionInfoTab.ps1` の一部機能 |
| **移植理由** | 起動後ダッシュボードの最小構成。Git 状態・テスト件数・token残量・フェーズを一覧表示 |
| **差異** | Claude 専用の重厚な MenuCommon.psm1 依存を排除し、既存モジュール（TokenBudget・MessageBus等）を組み合わせた軽量実装 |
| **検証** | `tests/unit/ProjectDashboard.Tests.ps1`（22 件） |

---

## SupervisorManager.psm1

| 項目 | 内容 |
|---|---|
| **分類** | 🔄 置換実装（Linux / Codex ネイティブ新規） |
| **元の対応** | Agent Teams / 自律ループ運用の概念 |
| **移植理由** | 登録プロジェクト候補へ Codex Supervisor 設定を配布し、Monitor → Build → Verify → Improve の自律ループを各プロジェクトで再利用するため |
| **差異** | SSH / Claude ランタイムへは接続しない。`.codex/supervisor.json` を番号選択した Linux ローカルプロジェクトへ作成する |
| **検証** | `tests/unit/SupervisorManager.Tests.ps1`, `tests/unit/StartupMenu.Tests.ps1` |

---

*最終更新: 2026-06-07*
