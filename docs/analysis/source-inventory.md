# 元リポジトリ棚卸し

対象:

- `D:\ClaudeCode-StartUpTools-New`

## 初期観察

- ドキュメント比重が高い
- 再利用可能なロジックは主に `scripts/lib` と `scripts/main` に集中している
- Claude 固有のテンプレートと指示文ツリーが大きい
- 既存テストがあるため、選択移植の判断材料として使いやすい

## 初期監査時の概数

- `node_modules` を除くファイル数: 約 382
- Markdown ファイル数: 263
- PowerShell ファイル数: 86
- 設定系ファイル数: 17

## 直近の重点項目

1. ルート文書を Codex 向けに対応付ける
2. `scripts/lib` を分類する
3. `tests` を分類する
4. `Claude/templates` から何を除外するか決める

## 移植済みスライス

- `scripts/lib/TokenBudget.psm1`
  - 分類: 調整して移植
  - 理由: 予算ロジックは汎用だが、リポジトリルート解決を Codex ローカル前提に簡素化した
  - 検証: `tests/unit/TokenBudget.Tests.ps1`
- `scripts/lib/Config*.ps1`, `scripts/lib/RecentProjects.ps1`
  - 分類: 調整して移植
  - 理由: 設定スキーマは再利用できるが、デフォルト値を Codex 主体に寄せた
  - 検証: `tests/unit/Config.Tests.ps1`, `tests/unit/ConfigSchema.Tests.ps1`, `tests/unit/RecentProjects.Tests.ps1`
- `scripts/lib/ArchitectureCheck.psm1`
  - 分類: そのまま移植
  - 理由: 静的な設計違反検査は Codex 側でもそのまま有効
  - 検証: `tests/unit/ArchitectureCheck.Tests.ps1`
- `scripts/lib/LogManager.psm1`, `scripts/lib/ErrorHandler.psm1`
  - 分類: そのまま移植
  - 理由: ログ運用と分類付きエラー処理は Claude ランタイムに依存しない
  - 検証: `tests/unit/LogManager.Tests.ps1`, `tests/unit/ErrorHandler.Tests.ps1`
- `scripts/lib/WorktreeManager.psm1`
  - 分類: そのまま移植
  - 理由: Git worktree 管理は Codex 側でもそのまま利用価値が高い
  - 検証: `tests/unit/WorktreeManager.Tests.ps1`
- `scripts/lib/MessageBus.psm1`
  - 分類: そのまま移植
  - 理由: state.json ベースの軽量メッセージ連携は Codex 側でも再利用しやすい
  - 検証: `tests/unit/MessageBus.Tests.ps1`
- `scripts/lib/StatuslineManager.psm1`
  - 分類: 調整して移植
  - 理由: 設定読取はそのまま使えるが、同期先や運用前提は Codex 側に合わせて見直す必要がある
  - 検証: `tests/unit/StatuslineManager.Tests.ps1`
- `scripts/lib/SessionTabManager.psm1`
  - 分類: 調整して移植
  - 理由: UI 表示ではなく、session.json の状態管理部分を Codex 向けに再利用する
  - 検証: `tests/unit/SessionTabManager.Tests.ps1`
- `scripts/lib/LauncherCommon.psm1`
  - 分類: 調整して移植
  - 理由: 起動共通処理は有用だが、Codex 側では最小責務に分解して残す必要がある
  - 検証: `tests/unit/LauncherCommon.Tests.ps1`
- `scripts/lib/McpHealthCheck.psm1`
  - 分類: 調整して移植
  - 理由: MCP 診断は有用だが、Claude 固有の起動 / 停止運用は切り落として最小診断に縮小する
  - 検証: `tests/unit/McpHealthCheck.Tests.ps1`
- `state.schema.json`, `state.json.example`
  - 分類: 調整して移植
  - 理由: Claude 側の巨大 state モデルは持ち込まず、`TokenBudget` と `MessageBus` が必要とする最小項目へ縮小した
  - 検証: `tests/unit/StateSchema.Tests.ps1`
- `scripts/main/Start-CodexBootstrap.ps1`, `scripts/main/Start-Codex.ps1`
  - 分類: 調整して置換実装
  - 理由: Claude 側の複数起動メニューをそのまま持ち込まず、Codex 向けの bootstrap、明示的 preflight、readiness 判定、state 更新、phase transition publish、標準ログ出力、分類付き失敗表示付きの単一ローカル起動入口へ再構成した
  - 検証: `tests/unit/StartCodexBootstrap.Tests.ps1`, `tests/unit/StartCodex.Tests.ps1`
