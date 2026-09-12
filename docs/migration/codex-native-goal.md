# Codex ネイティブ Goal 移植メモ

参照元: `Claude-StartUpTools-New-Linux`（ClaudeOS v10.1 の `/goal` システム）
移植日: 2026-09-12
対象 Codex: `codex-cli 0.154.0`（0.153.4 で初回検証、0.154.0 で再検証）

---

## 1. 移植の結論（何を移植し、何を移植しなかったか）

**Codex には `/goal` が既にある。** `features.goals`（stable・既定 ON）として
永続 Goal と自動継続がハーネス側に実装済みで、Claude 側の
「起動プロンプト先頭へ `/goal "..."` を注入する」方式より機構として上位である。

したがって移植したのは **実行ループではなく「Goal の投入路」と「予算の既定値」** である。

| 分類 | 対象 | 判断 |
|---|---|---|
| ✅ そのまま活用 | Codex ネイティブ Goal（永続・自動継続・完了監査・blocked 監査） | 再実装しない |
| 🔄 置換実装 | `goal_extract__compose`（プロンプト注入）→ `thread/goal/set`（app-server RPC） | 自動継続を潰さないため |
| ⚙️ 調整して移植 | `goal_extract__block` 相当の `/goal` ブロック抽出 | 文字数検証を Codex 仕様（4,000 字）へ合わせた |
| 🚫 移植しない | `- or stop after N turns` 等のループ条件 | ハーネスの `GoalContinuation` と二重管理になり no-progress 判定と衝突する |
| ⏸️ 未移植（別途判断） | Goal Router（Evidence → Primary/Specialized の自動選択） | 本件の中核ギャップ。次段階 |

---

## 2. 実装したもの

| ファイル | 役割 |
|---|---|
| `scripts/lib/CodexGoalClient.psm1` | app-server JSON-RPC クライアント（純粋関数 + セッション + 高レベル操作） |
| `scripts/main/Invoke-CodexGoal.ps1` | 非対話 CLI（`validate` / `start` / `set` / `get` / `clear`） |
| `.codex/config.toml` | `[goals] max_goal_token_budget = 500000` |
| `tests/unit/CodexGoalClient.Tests.ps1` | 30 テスト（純粋関数 + セッション Mock + 任意の実機 E2E） |
| `tests/unit/Invoke-CodexGoal.Tests.ps1` | 10 テスト（RPC を呼ばない経路 + `-DryRun`） |

### 対応表（Claude 側 → Codex 側）

| Claude 側 | Codex 側 | 備考 |
|---|---|---|
| `goal_extract__block` | `Get-CodexGoalObjectiveFromTemplate` | 開き `/goal "` 〜 閉じ単独 `"` 行の規約を踏襲 |
| `goal_extract__ensure_stop` | （不要） | Codex が継続条件を内蔵 |
| `goal_extract__truncate` | `Test-CodexGoalObjective` | 4,000 字判定のみ。Codex が受理時に再検証する |
| `goal_extract__compose` | `Start-CodexGoalRun` / `Set-CodexThreadGoal` | プロンプト注入ではなく Goal API へ |
| `libexec/goal-router.sh` | （未移植） | Goal Router は次段階 |

---

## 3. 実測で判明した設計制約（重要）

これらは推測ではなく、`codex app-server` を実際に往復させて確認した事実である。

### 3.1 スレッドは app-server **プロセス**が所有する

`thread/start` したプロセスを閉じたあと、**別プロセス**から
`thread/goal/set` を呼ぶと `thread not found` になる。
一方、`thread/goal/clear` は thread id だけで成功する（goals DB を直接引くため）。

→ 対策:
- 新規作成 + Goal 設定は **1 セッション内**で完結させる（`Start-CodexGoalRun`）
- 既存スレッドへ設定する場合は先に **`thread/resume`** する（`Set-CodexThreadGoal`）

### 3.2 強制 Kill はスレッドを汚す

`Process.Kill()` で app-server を落とすと、スレッドに **`active writer`** が残り、
後続セッションが同じスレッドを開けなくなる（`thread ... already has an active writer`）。

→ 対策: `Close-CodexGoalSession` は **stdin を閉じて EOF を送り正常終了**を待つ。
3 秒で終わらない場合のみ Kill する。

### 3.3 `max_goal_token_budget` は既定値かつ設定可能な上限

`goals.max_goal_token_budget = 500000` を設定すると、
**tokenBudget を指定せずに作った Goal に 500000 が自動で入る**（実測。
`12345` を設定すれば 12345 が入る）。

→ これは「予算未設定のまま 35 万トークン消費して blocked になる」問題への直接の対策になる。

2026-09-12 の追加検証では、設定が 500000 のまま `tokenBudget: 1000000` を
`thread/goal/set` に送ると `exceeds the maximum allowed goal token budget of 500000` で拒否された。
既定値の検証だけでは上限制約を否定できず、以前の「上限ではない」という説明は誤りだった。
ユーザーが増額を承認した場合は、更新用 app-server に
`codex -c goals.max_goal_token_budget=1000000 app-server` のように明示する。
これは起動時だけの設定であり、リポジトリの既定値は変更しない。

既に永続化された今回の Goal は、`thread/resume` なしの `thread/goal/get` / `set` で更新できた。
`objective` を省略して `tokenBudget` と `status: active` を指定し、目的と消費履歴の維持を読み戻して確認した。
実行中スレッドに `thread/resume` すると `already has an active writer` となるため、
予算変更のためにロックを削除したり既存プロセスを強制終了したりしない。
新規スレッドの作成と設定には引き続き同一接続を使う。

### 3.4 `codex exec` に `--goal` は無い

`codex exec --help` に goal 系フラグは存在しない（0.154.0 実測）。
非対話でネイティブ Goal を扱う正規路は **app-server RPC のみ**。

---

## 4. 検証方法

| 種別 | コマンド | 結果 |
|---|---|---|
| 単体 | `Invoke-Pester -Path tests/unit/CodexGoalClient.Tests.ps1` | 30 passed |
| 単体 | `Invoke-Pester -Path tests/unit/Invoke-CodexGoal.Tests.ps1` | 10 passed |
| 実機 E2E | `CODEX_STARTUP_E2E=1 Invoke-Pester -Path tests/unit/CodexGoalClient.Tests.ps1` | 実 `codex app-server` に対し thread 作成 → Goal 設定 → 別プロセスから取得 → 更新 → 削除まで成功 |
| 回帰 | `Invoke-Pester -Path tests/unit` | 全件 pass（ArchitectureCheck 含む） |
| CLI | `Invoke-CodexGoal.ps1 -Action validate -Template <goals/*.md>` | Claude 側 `deep-debug.md` を 1,274 字として受理 |

E2E テストは thread と rollout を実際に生成するため、既定では skip し
`CODEX_STARTUP_E2E=1` を明示したときだけ実行する。

---

## 5. 既知の制約と次の段階

- **app-server は experimental。** 本モジュールは `codex app-server` の stdio インターフェースに依存する。
  破壊的変更があれば `Invoke-CodexGoalSessionRpc` の層で吸収する。
- **`active writer` と stdin EOF。** 強制 Kill はスレッドを汚すため、`Close-CodexGoalSession` は
  stdin を閉じて正常終了を待つ。外部からプロセスを kill すると同じ症状が出る。
- **`codex doctor` の `rollout files are missing from the state DB`** は本件とは無関係の既存の
  データ衛生警告。本移植では触れていない。

---

## 6. 追補（2026-09-12）: 外部駆動・一覧・Goal Router・メニュー統合

初版の「次の段階」に挙げていた項目を実装した。

### 6.1 app-server は Goal を自動継続しない（実測）

`thread/goal/set` → `turn/start` を実行し 100 秒観測した結果:

| 観測 | 結果 |
|---|---|
| `turn/started` | 届く |
| `thread/goal/updated` | 届く（status=active, tokensUsed=7997） |
| `turn/completed` | 届く |
| **自動の継続 turn** | **届かない** |

app-server 単体では Goal は回らない（TUI 側の idle 継続に依存している）。
したがって継続は**外部から駆動する**必要がある。

### 6.2 `Invoke-CodexGoalRun` — セッション保持型ドライバ

`turn/start` → `turn/completed` 待ち → `thread/goal/get` で status 確認 → 継続 turn 送出
というループを **同一 app-server セッションを保持したまま** 回す。
終端 status（`complete` / `blocked` / `usageLimited` / `budgetLimited`）または
`MaxTurns` / `MaxMinutes` / turn タイムアウトで停止する。

`MaxMinutes` はセッション準備開始から計測し、各 RPC とターン待機には残時間を
上限として渡す。期限到達後は追加の状態取得 RPC を送らず、最後に確認した Goal を返す。
タイムアウト指定は秒単位で切り上げるため最大約 1 秒の差があり、終了処理の待機時間は別途必要になる。
stdout の読み取りは無音時にも未完了 Task を保持し、次の待機で再利用する。
stderr は非同期で破棄し、パイプの詰まりを防ぐ。内容は保存・表示しない。

継続プロンプトは Codex ネイティブの継続指示と同じ規律（目的を縮小しない / 証拠で判断 /
progress と verified wait の区別 / 3 ターン連続の同一ブロッカーで blocked）を外部から与える。
`Get-CodexGoalContinuationPrompt` がそれを生成する。

CLI: `Invoke-CodexGoal.ps1 -Action run -Template <goals/*.md> [-MaxTurns N] [-MaxMinutes N]`

**実機検証**: 1 ターンで `finalStatus=complete` / `stopReason=goal-complete` を確認。
モデルが `update_goal status=complete` を呼び、ドライバがそれを検出して停止した。

### 6.3 実装中に踏んだ 2 つの罠（再発防止のため記録）

1. **通知バッファの循環で応答が永久に来ない。** RPC 応答待ちで「応答でない行」を
   バッファへ戻す実装にすると、バッファを巡回し続けて stdout を読まなくなり
   `thread/start` がタイムアウトする。→ RPC 応答待ちは `Read-CodexGoalSessionStdoutLine`
   （バッファを見ない直接読み）を使い、通知は一方向でバッファへ退避する。
2. **`List[object]` を `@()` で包むと `[pscustomobject]` リテラルが失敗する。**
   `Argument types do not match` になる（`List[string]` は問題ない）。→ `.ToArray()` を使う。

### 6.4 Goal 一覧（`Get-CodexGoalList`）

`~/.codex/goals_1.sqlite` の `thread_goals` を読み取り専用で読む。
PowerShell に sqlite が無いため python3 → sqlite3 CLI の順にフォールバックし、
どちらも無ければ `Available=$false` を返して例外にしない（メニューを止めない）。
CLI: `Invoke-CodexGoal.ps1 -Action list`

### 6.5 Goal Router（レーンB）— `scripts/lib/GoalRouter.psm1`

Claude 側 `lib/goal-router.sh`（ClaudeOS v10.1）の判定ロジックを忠実に移植した。

| 機能 | 実装 |
|---|---|
| Primary 5 / Specialized 6 の分類と許可関係 | `Test-GoalRouter*` / `Test-GoalRouterAllows` |
| Evidence 収集（state.json / git / CI / gh / runtime / intent） | `Get-GoalRouterEvidence`（外部 I/O はここに閉じ込め） |
| 13 段階の優先順位ルーティング | `Invoke-GoalRouterRoute`（**純粋関数**） |
| session lock（既定 720 分）と reroute 条件 | `Invoke-GoalRouterRoute` 内 |
| fail-safe（必ず 1 つの Goal を返す） | 同上 |
| state.json の `goal_router` ブロックへの原子的永続化 | `Save-GoalRouterState` |
| Goal テンプレート解決（プロジェクト優先 → mvp-release フォールバック） | `Get-GoalTemplatePath` |

Router の出力（`effective`）を `Get-GoalTemplatePath` → `Get-CodexGoalObjectiveFromTemplate`
→ `Invoke-CodexGoalRun` へ渡すことで、「どの Goal を選ぶか」と「どう回すか」が繋がる。

### 6.6 Goal テンプレート 11 本（`config/goals/*.md`）

Primary 5 + Specialized 6 を Codex 向けに書き起こした（Claude 側から移植・適応）。
各テンプレートは `/goal "` 〜 閉じ `"` 規約で objective を埋め込み、実測 1,067〜1,409 字
（Codex の上限 4,000 字以内）。Claude 固有の機構（DynamicWorkflows / AgentTeams /
CodeRabbit 等）は Codex の相当物（サブエージェント / `.codex/agents/*.toml` / `codex review`）へ置換した。

**ループ条件（`- or stop after N turns`）は意図的に書いていない。** 継続は Codex ハーネス側の
no-progress 判定と本ドライバが担うため、二重管理になると衝突する。

### 6.7 メニュー統合（A3）

`StartupMenu.psm1` に `14. Goal 管理` を追加（`Invoke-GoalManagementAction`）。

1. Goal Router の判定を **`-NoPersist -SkipGitHub -SkipRuntime`** で表示（メニュー操作だけで
   state.json を書き換えたりネットワークを使ったりしない）
2. `Get-CodexGoalList` で現在の Goal 一覧（thread / status / tokens / objective）を表示
3. 11 テンプレートから番号選択し、`yes` 確認後にのみ `-Action start` を実行

### 6.8 レーンC — Agents API の dry-run 契約

`scripts/lib/AgentsApiPayload.psm1` + `config/agents-api.json.template`。
詳細は `docs/migration/openai-agents-api-dryrun.md` を参照。

### 6.9 検証結果（追補分）

| 種別 | 結果 |
|---|---|
| Pester 全件 | **394 passed / 0 failed / 1 skipped**（追補前は 289） |
| ArchitectureCheck | CheckedFiles 55 / TotalViolations 0 / Passed true |
| GoalRouter 単体 | 58 件（分類・intent 優先順位・13 ルール・lock/reroute・fail-safe・永続化・テンプレート整合） |
| CodexGoalClient 単体 | 44 件（うち実機 E2E 1 件は opt-in） |
| AgentsApiPayload 単体 | 33 件 |
| 実機ドライバ | 1 ターンで `complete` を検出、検証用 Goal は削除済み |
