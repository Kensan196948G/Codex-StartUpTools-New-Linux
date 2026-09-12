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

### 3.3 `max_goal_token_budget` は「上限」ではなく「既定値」

`goals.max_goal_token_budget = 500000` を設定すると、
**tokenBudget を指定せずに作った Goal に 500000 が自動で入る**（実測。
`12345` を設定すれば 12345 が入る）。

→ これは「予算未設定のまま 35 万トークン消費して blocked になる」問題への直接の対策になる。

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
- **`Start-CodexGoalRun` はスレッドを「登録」するが駆動はしない。**
  Goal の自動継続はスレッドが app-server にロードされている間だけ働く。
  継続させるには `codex resume <threadId>` で接続するか、セッションを保持し続ける必要がある。
  CLI は終了時にその案内を表示する。
- **Goal Router は未移植。** どの Goal を選ぶかの自動決定（Evidence → Primary/Specialized、
  session lock、reroute）は本移植の範囲外。`docs/analysis/openai-agents-api-codex-goal-adoption-study.md`
  のレーンB を参照。
- **OpenAI Agents API（Managed Plane）は未着手。** 同ドキュメントのレーンC を参照。
