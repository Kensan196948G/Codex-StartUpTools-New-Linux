# 移植マスタープラン

## 対象範囲

参照元:

- `https://github.com/Kensan196948G/Codex-StartUpTools-New-Windows.git`

移植先:

- `/home/kensan/Projects/Codex-StartUpTools-New-Linux`

## 移植原則

- ディレクトリ構造ではなく、機能を移植する
- 方針、実装、テンプレートを分離して扱う
- Claude 専用ランタイム前提を Codex 向け運用に置き換える
- 各移植領域を個別にレビュー可能な単位で進める
- Codex を標準開発エージェントとして実装を進める
- Linux ローカル起動、`/home/kensan/Projects` 配下の登録プロジェクト候補、Codex only を現行ターゲットにする
- SSH / Claude / Copilot 起動はランタイムから削除する

## 作業ストリーム

1. 運用方針
2. ドキュメントと正本構造
3. 再利用可能な PowerShell / 補助スクリプト
4. 検証とテスト
5. 必要に応じた自動化とバックログ支援

## 一次分類

- 高確率で移植しやすい
  - ガバナンス文書
  - ループ定義
  - アーキテクチャチェック
  - 汎用スクリプトユーティリティ
  - 再利用可能なスクリプト挙動を検証するテスト
- 調整が必要
  - ランチャーフロー
  - 状態管理
  - エージェントチーム抽象
  - Issue 同期
- 部分移植または置換
  - Claude hooks
  - Claude templates
  - Claude ランタイム専用 commands

## 1セッションの定義

1回の作業セッションでは、次のいずれか1つを完了目標にします。

- 1つの文書群の監査
- 1つのスクリプトモジュールの監査
- 1つの移植機能の骨格作成
- 1回の検証実施

## 完了条件

- 元機能との対応が記録されている
- 移植先の配置方針が決まっている
- 移植先ファイルが作成されている
- 検証メモが残っている

## 完了済みスライス

- Token budget manager
  - target module: `scripts/lib/TokenBudget.psm1`
  - verification: `tests/unit/TokenBudget.Tests.ps1`
  - migration notes: `docs/migration/token-budget-migration.md`
- Config and recent-projects layer
  - target modules: `scripts/lib/Config.psm1`, `scripts/lib/ConfigLoader.ps1`, `scripts/lib/ConfigSchema.ps1`, `scripts/lib/RecentProjects.ps1`
  - verification: `tests/unit/Config.Tests.ps1`, `tests/unit/ConfigSchema.Tests.ps1`, `tests/unit/RecentProjects.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Architecture guard layer
  - target module: `scripts/lib/ArchitectureCheck.psm1`
  - verification: `tests/unit/ArchitectureCheck.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Logging and categorized error handling
  - target modules: `scripts/lib/LogManager.psm1`, `scripts/lib/ErrorHandler.psm1`
  - verification: `tests/unit/LogManager.Tests.ps1`, `tests/unit/ErrorHandler.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Worktree manager
  - target module: `scripts/lib/WorktreeManager.psm1`
  - verification: `tests/unit/WorktreeManager.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Message bus
  - target module: `scripts/lib/MessageBus.psm1`
  - verification: `tests/unit/MessageBus.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Statusline manager
  - target module: `scripts/lib/StatuslineManager.psm1`
  - verification: `tests/unit/StatuslineManager.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Session state manager
  - target module: `scripts/lib/SessionTabManager.psm1`
  - verification: `tests/unit/SessionTabManager.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Launcher common subset
  - target module: `scripts/lib/LauncherCommon.psm1`
  - verification: `tests/unit/LauncherCommon.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- MCP health-check subset
  - target module: `scripts/lib/McpHealthCheck.psm1`
  - verification: `tests/unit/McpHealthCheck.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Reduced state model
  - target artifacts: `state.schema.json`, `state.json.example`
  - verification: `tests/unit/StateSchema.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Codex startup entrypoints
  - target artifacts: `scripts/main/Start-CodexBootstrap.ps1`, `scripts/main/Start-Codex.ps1`
  - verification: `tests/unit/StartCodexBootstrap.Tests.ps1`, `tests/unit/StartCodex.Tests.ps1`
  - migration notes: `docs/migration/config-and-architecture-migration.md`
- Linux menu and Supervisor selection
  - target artifacts: `start.sh`, `scripts/main/Start-Menu.ps1`, `scripts/lib/StartupMenu.psm1`, `scripts/lib/SupervisorManager.psm1`
  - verification: `tests/unit/StartupMenu.Tests.ps1`, `tests/unit/SupervisorManager.Tests.ps1`
  - note: Supervisor writes only to numbered selections unless `all` is explicitly entered

## 次の候補

1. Supervisor 適用結果の運用レポート化
2. GitHub Projects 同期の Codex 向け再設計
3. 登録プロジェクト候補のフィルタ UI 改善
