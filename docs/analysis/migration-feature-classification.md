# 移植機能分類表

この文書では、移植元リポジトリの機能を次の3つに分類します。

- Codex へ移植しやすい機能
- Codex 向けに代替実装や再設計が必要な機能
- 移植対象から外すべき機能

移植元:

- `D:\ClaudeCode-StartUpTools-New`

判断根拠:

- ルート構成の監査
- ドキュメント構造の確認
- スクリプトとテストの棚卸し
- Claude 固有テンプレートと hooks の集中領域

## 1. Codex へ移植しやすい機能

これらは、比較的少ない調整で Codex に持ち込みやすい機能です。

| 機能領域 | 元の主な参照先 | Codex 側の扱い | 移植しやすい理由 |
|---|---|---|---|
| 運用原則 | `AGENTS.md`, `docs/common/11_自律開発コア.md` | Codex 向け方針文書として再構成 | 概念中心でベンダー依存が少ない |
| ループ設計 | `monitor-loop.md`, `build-loop.md`, `verify-loop.md`, `improve-loop.md` | 構造を維持して文言を Codex 向けに調整 | 開発ワークフローとして汎用性が高い |
| アーキテクチャレビュー規則 | `scripts/lib/ArchitectureCheck.psm1` と関連テスト | 軽微な I/F 整理で移植 | 検証ロジック自体は Claude 専用ではない |
| Token / 作業予算ルール | `scripts/lib/TokenBudget.psm1`, 状態管理文書 | Codex セッション運用向けに再定義 | 運用方針として転用しやすい |
| Worktree 運用概念 | `scripts/lib/WorktreeManager.psm1`, テスト群 | Codex リポジトリ運用向けに簡素化して移植 | Git worktree の考え方はそのまま使える |
| 汎用設定読み込みと検証 | `Config.psm1`, `ConfigLoader.ps1`, `ConfigSchema.ps1` | 必要部分のみ選択移植 | 設定処理はツール非依存で流用しやすい |
| ログ / エラー処理補助 | `LogManager.psm1`, `ErrorHandler.psm1`, `SessionLogger.ps1` | テスト付きで段階移植 | 補助モジュールとして再利用しやすい |
| バックログ整備の考え方 | `TASKS.md`, backlog manager 系文書 | 軽量な Codex 運用ポリシーとして再構築 | プロセス知見として有効 |
| テストと検証方針 | `tests/README.md`, unit / integration 戦略 | Codex 版品質基準として継承 | 開発品質の基本原則だから |
| ドキュメント構造パターン | `docs/common`, onboarding, FAQ 系 | 情報設計を維持しつつ書き換え | 実行環境依存が小さい |

## 2. Codex 向けに代替実装が必要な機能

考え方は有用ですが、そのままコピーすると Codex では不自然になる領域です。

| 機能領域 | 元の主な参照先 | Codex 側の推奨対応 | そのまま移植しにくい理由 |
|---|---|---|---|
| Boot Sequence 制御 | `Start-ClaudeOS.ps1`, `claudeos/system/*.md` | Codex 用の起動チェックリストと軽量 bootstrap に再設計 | 現状は ClaudeOS 中心設計 |
| Agent Teams 実行モデル | `scripts/lib/AgentTeams.psm1`, `AgentTeamBuilder.ps1`, agent docs | 役割定義だけ残し、Codex ワークフローに合わせ再構成 | Claude 型サブエージェント前提が強い |
| state.json ライフサイクル | `state.json`, `state.schema.json`, startup hooks | Codex で実際に使う項目だけに縮小 | Claude セッション段階管理を多く含む |
| 起動メニュー群 | `scripts/main/Start-*.ps1` | Codex 向けエントリポイントへ置換 | 現状のメニュー構成は Claude / 廃止ツール依存が混ざる |
| セッション情報 / Statusline | `Show-SessionInfoTab.ps1`, `Set-Statusline.ps1` | Codex アプリ / ターミナル事情に合わせ再設計 | UI 前提が異なる |
| Issue / Backlog 同期 | `IssueSyncManager.psm1`, `Sync-Issues.ps1` | GitHub 運用が必要な場合のみ再実装 | 外部サービスとリポジトリ運用に依存 |
| Cron / 定期実行 | `CronManager.psm1`, `New-CronSchedule.ps1`, Linux cron templates | Codex の自動化機能前提で必要最小限だけ再構築 | Claude セッション運用と密結合 |
| Self Evolution | `SelfEvolution.psm1`, evolution 文書 | 明示的な振り返りと改善記録へ置換 | 自動化前提をそのまま持ち込むと過剰になりやすい |
| MCP ヘルス診断 | `McpHealthCheck.psm1`, test scripts | 実際に使う Codex connector / tool に合わせ再構築 | 監視対象が Claude 前提 |
| Recent Projects / ランチャー UX | `RecentProjects.ps1`, menu helper 群 | 必要なら最小限のプロジェクト追跡へ置換 | ランチャー中心設計のため |
| テンプレート同期機構 | `TemplateSyncManager.ps1`, template folders | Codex 用テンプレートを別設計 | Claude 用テンプレート同期は流用しにくい |

## 3. 移植対象から外すべき機能

保守コストに対して Codex での価値が低く、直接移植は避けるべき領域です。

| 機能領域 | 元の主な参照先 | 推奨判断 | 移植しない理由 |
|---|---|---|---|
| Claude hook 実装群 | `.claude/claudeos/scripts/hooks/*`, hooks 文書 | 直接移植しない | Claude 固有イベントライフサイクル依存 |
| Claude 設定 / 指示文バンドル | `Claude/templates/claude/*`, `.claude/*` | 参考資料としてのみ保持 | 設定形式と契約がベンダー固有 |
| ClaudeOS command カタログそのもの | `Claude/templates/claudeos/commands/*` | 丸ごとコピーしない | command 意味体系が Codex ネイティブではない |
| Claude agent 定義ライブラリそのもの | `Claude/templates/claudeos/agents/*` | 発想だけ抽出 | 完全互換を狙うと保守負担が高い |
| Claude 専用プロンプトテンプレート | `START_PROMPT.md`, instruction fragments | 必要ならゼロから書き直す | プロンプト契約が異なる |
| Claude セッション完了メール前提の Linux 通知 | `report-and-mail.py`, cron launcher templates | 原則除外 | Claude の cron セッション前提で構成されている |
| Copilot / 旧複数ツール起動残骸 | `Start-CopilotCLI.ps1` など | 移植しない | 現在の対象スコープ外 |
| 大規模テンプレートアーカイブ全体 | `Claude/templates/claudeos/skills`, examples, rules など広範囲 | 例外時のみ個別採用 | 規模が大きく、Codex 初期構築には重すぎる |

## 推奨優先順位

最初に着手すべき領域:

1. 運用方針とルート文書
2. ループ設計と検証モデル
3. アーキテクチャチェックと再利用可能補助モジュール
4. 設定 / ログ系ユーティリティ
5. 移植済み機能のテスト

コアが安定してから着手する領域:

1. 状態管理モデル
2. エージェント役割モデル
3. 起動 / ランチャーフロー
4. 自動化や GitHub 連携

除外対象は、具体的な Codex 用ユースケースが出るまで参照専用に留めます。

## 実務ルール

次のいずれかに依存する機能は:

- Claude hook イベント
- Claude 専用 command 名
- Claude セッション bootstrap の意味体系
- Claude 専用テンプレート契約

原則として次のどちらかに分類します。

- `Codex 向けに置換実装`
- `移植しない`

`そのまま移植` にはしません。
