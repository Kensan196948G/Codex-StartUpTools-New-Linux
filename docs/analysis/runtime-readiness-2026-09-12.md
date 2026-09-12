# 実利用可能性の検証記録

## 目的と正本

2026-09-12 の自律改善。Linux の起動、プロジェクト選択、Supervisor、Goal、診断・リリース確認を実際に使用できる状態へ進める。
GitHub、承認済み方針、README、設定テンプレート、既存実装・テストを照合し、OpenViking は補助的な記憶として扱う。
本リポジトリはローカル CLI ツールであり、今回 Web サービスや DB を新設しない。

## 初動分析と計画

開始時は `main`、`c06352e`、作業ツリーはクリーン。open PR / Issue はゼロ。
既存 Pester は 394 成功、0 失敗、実 Codex E2E 1 スキップ。
GitHub Ruleset `central-auto-merge` は active で、既存の必須チェック4種を確認した。

| 不足 | 優先度 | 修正方針 | 影響ファイル | 検証 |
|---|---|---|---|---|
| Goal の無音待機後に並行読取例外 | P1 | 保留中の非同期読取を再利用 | CodexGoalClient / テスト / 移植文書 | 実ストリームのタイムアウト後応答 |
| Goal の stderr 未排出、最大時間超過 | P1 / P2 | 非同期排出、残り時間を RPC / ターン待機へ反映 | 同上 | 大量 stderr、期限の回帰、実 Codex |
| 同名プロジェクトの誤選択 | P1 | フルパスで選択対象を保持、曖昧な名前指定を拒否 | SupervisorManager / StartupMenu / LauncherCommon / テスト | 2 ルートに同名の候補を作る回帰 |
| Linux の TEMP 未設定で診断やログ退避が失敗 | P2 | MCP 出力はメモリで扱い、ログ退避先は OS API で解決 | McpHealthCheck / LogManager / テスト | TEMP 未設定、特殊引数、大量出力、子プロセス終了 |
| 初回 DryRun が失敗し、ログへの副作用もある | P2 | テンプレートを読取検証し、ログ作成・削除を抑止 | 起動スクリプト2本 / テスト | 初回起動、既存ファイルのハッシュ不変、不正テンプレート |
| テスト未実行や構造不正を品質ゲートが見逃す | P2 | Pester 結果と成功件数を判定、実スキーマ検証、lint Error / 依存欠落を拒否 | ReleaseCheck / CI / テスト | 正常系と各失敗条件の終了コード |

変更は既存モジュール境界に収め、外部 API 契約や認証方式は変更しない。
新規ランタイム依存、DB migration、production secret、公開範囲、登録プロジェクト全件への適用はない。
コードの rollback はこの変更の逆差分を作業ブランチと PR で適用する。ユーザーの状態・設定の巻き戻しは不要。

## 検証と外部連携

- PowerShell / Pester / PSScriptAnalyzer をローカルで使用。ビルド済みバイナリを生成するプロジェクトではないため、モジュール読込・構文解析・テスト・CLI 起動を検証対象とする。
- 統合 Pester は 437 成功、失敗・スキップともゼロ。続く履歴の大小文字比較修正は追加回帰2件を含む近傍7件で成功。LauncherCommon の自動変数名との衝突を避ける整理後も近傍19件が成功した。
- 構造検査は29ファイルで Critical / Warning ともゼロ。モジュール依存欠落ゼロ、state / config 検証成功。CI YAML はパーサで4ジョブの構文を確認した。
- 全コード変更のコミット後、`CODEX_STARTUP_E2E=1` を指定した正式な `Invoke-ReleaseCheck.ps1 -Json` は7項目すべて成功。Git clean、全 Pester、実起動 DryRun、文書・設定・構造検査を通過した。lint は Error ゼロ、既存 Warning 305件を残す。
- Codex CLI 0.154.0 の実 E2E は Goal 設定・取得・更新・削除を含め 47 成功、スキップゼロ。検証用 Goal の実駆動は 1 ターンで `complete` を確認し、検証用 Goal を削除した。
- CI の異常系は discovery failure、ゼロ件、assertion failure、不正 state、不正 config、lint Error、依存欠落の7条件で非ゼロ終了を確認。
- `shellcheck start.sh` は成功。Gitleaks 8.30.1 は配布チェックサムを照合して使用し、Git 管理対象の作業ツリーで検出ゼロ。秘密候補の値は出力しない。
- MCP 検査は既存 Linux 環境の `setsid`、`sh`、外部 `kill`、`/proc` を利用する。開始前と回収前に PID / PGID / SID を確認し、検査専用グループ以外を終了しない。未導入時は検査開始前に拒否する。
- Dependabot alerts はリポジトリで無効のため API は 403。依存脆弱性の網羅的な保証はしない。新規の製品依存は追加していない。
- Local PostgreSQL は `/var/run/postgresql:5432` の待受が正常。本プロジェクトには接続設定、Schema、Migration がないため、DB の読書き、Backup / Restore は対象外。別プロジェクトの DB を操作していない。
- Cloudflare の配備コード、対象環境、ドメイン定義は本リポジトリにない。Deployment と公開サービスの Health Check は対象外。本番配備・タグ・release は行っていない。
- OpenDesign の接続および本プロジェクト用デザイン成果物は確認できない。今回の UI は既存ターミナルメニューを対象とする。

## OpenViking

専用 MCP は本セッションにないが、中央の運用文書を参照し、既存ユーザー認証で loopback の Local API に接続した。
`health` / `ready` は正常。秘密はプロセス内だけで読み、引数・ログ・新規ファイルへ保存していない。

参照した関連記憶:

- `viking://user/harness/memories/trajectories/codex_goal_cli_20260912094443.md`: 非対話 CLI と Goal クライアントの責務分離。
- `viking://user/harness/memories/trajectories/codex_goal_cli_tests_20260912094443.md`: validate が RPC を使用しない検証。
- `viking://user/harness/memories/trajectories/codex_goal_cli_tests_run_20260912094443.md`: objective 検証の断片。
- `viking://user/harness/memories/trajectories/codex_goal_clear_20260912094443.md`: 過去の環境整理記録。今回の操作承認には使用していない。

過去記憶は断片や無関係な検索結果を含むため、現在のコードと実行結果を優先した。
今回発見したストリーム待機、Linux 一時ディレクトリ、パス識別、検証未実行の誤判定は、再利用可能な知見1件にまとめて保存した。
保存先は `viking://resources/codex-startuptools-runtime-readiness-20260912.md`。HTTP 200、semantic / vector 処理完了、本文の読み戻しを確認した。
保存時点は最終 CI 前と明記し、GitHub 上のマージ完了を先取りして記録していない。

## 残存する制限

- lint Warning は既存分を含め継続表示する。Warning ゼロとは報告しない。
- Goal の時間制限には秒単位の切り上げとプロセス終了処理の待機時間が加わる。
- MCP の終了処理は検査専用プロセスグループを対象とする。自ら別セッションへ離脱する子や、出力を閉じて正常終了したコマンドが残すバックグラウンドプロセスは対象外。healthCommand は有限時間で終了する診断コマンドとして設定する。
- Supervisor の preview は既知の管理フィールドを比較する。任意の拡張フィールドを持つ既存 manifest を置換する場合は、ファイル全体を確認する必要がある。
- Agents API は承認済み範囲の dry-run 契約に留め、live 実行を完成機能として扱わない。

## 仕様参照

Codex app-server の接続方式は [公式ドキュメント](https://learn.chatgpt.com/docs/app-server) を参照し、Goal の挙動は本環境の CLI と回帰テストで照合した。
