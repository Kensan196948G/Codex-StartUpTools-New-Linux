# OpenAI Agents API dry-run 契約 移植メモ

対象: OpenAI Agents API（OpenAI がホストする Codex ハーネス、公開ベータ）
実装日: 2026-09-12
比較対象: `Claude-StartUpTools-New-Linux` の Managed Agents P0（Anthropic 版）

---

## 1. 何を作ったか

| ファイル | 役割 |
|---|---|
| `config/agents-api.json.template` | 実行可能な設定契約（ID 記録用プレースホルダではない） |
| `scripts/lib/AgentsApiPayload.psm1` | config 検証 / payload 生成 / curl 生成 / live 前提判定 / dry-run |
| `tests/unit/AgentsApiPayload.Tests.ps1` | 33 テスト（ネットワーク・実 config 不要） |

`.gitignore` に `config/agents-api.json` を追加（承認 ID を含むためコミットしない）。

---

## 2. 公式仕様に基づく payload（推測でフィールドを足していない）

使用フィールドは 2026-09-12 取得の公式docに**実例があるものだけ**:

| フィールド | 出典 |
|---|---|
| `agent.model` / `agent.instructions` | Agents API overview の examples |
| `agent.tools[].type` = `programmatic_tool_calling` \| `mcp` \| `web_search` | 同上 |
| `agent.tools[].server_label` / `.transport{type,server_url}` | 同上（mcp） |
| `agent.multi_agent{enabled,max_concurrent_subagents}` | Multi-agent ガイド |
| `environment.type` = `none` \| `openai_hosted` \| `self_hosted` | Architecture ガイド |
| `environment.workspace_directory` | 同上 |
| `environment.capability_directories` | Skills ガイド（最大 32、絶対パス、`.`/`..` 不可） |
| `input[{role,content[{type:"input_text",text}]}]` | overview の examples |
| `POST /v1/agents/sessions` + `OpenAI-Beta: agents=v1` | overview の curl 例 |

生成される payload は公式の curl 例と同型であることを実測で確認した。

---

## 3. 予算について — Anthropic 版との決定的な差

**OpenAI Agents API には session budget フィールドが存在しない。**
公式doc（overview / architecture / multi-agent / configuration / observability）を検索しても
`budget` / `max_list_cost` / `spend` に相当する記載は無い。

Anthropic の Managed Agents は `budget: {type:"limit", max_list_cost:{amount,currency}}` が
**Session 作成時に必須**（後付け不可）であり、Claude 側 P0 はこれを契約として強制している。
OpenAI 側にはその受け皿が無いため、同じ「予算必須」を API に渡す形では実装できない。

したがって本実装では、予算統制を **API ではなくローカルゲート** として持つ:

```json
"localCostGuard": {
  "requireExplicitApproval": true,
  "approvalId": "",          // 空のまま live にしない
  "maxEstimatedUsd": null
}
```

`Test-AgentsApiLiveAllowed` は次がすべて揃わない限り live を拒否する（fail-safe 既定拒否）:

1. `enabled = true`
2. `mode = live`
3. `localCostGuard.approvalId` が非空（人間の課金承認）
4. `dataResidency.approved = true`（米国所在のみ・ZDR 非対応の明示承認）
5. 設定契約が有効

実コストは モデル API レート + ツール標準レート + hosted sandbox のコンテナレートで発生する。
`maxEstimatedUsd` は現時点では**記録項目**であり、自動停止の実装は次段階（予算の実測手段が
必要）。ここを「実装済み」と偽らないために明記しておく。

---

## 4. データ所在・保持

- Agents API のデータ所在は**米国のみ**、**ZDR 非対応**。
- `self_hosted` sandbox を選んでも ZDR 適格にはならない（公式docに明記）。
- したがって本番障害ログ等の投入可否は `dataResidency.approved` で人間が明示管理する。
  既定は `false`。

---

## 5. Skills の相互運用

Agents API の skills は `SKILL.md` + front matter（agentskills.io 仕様）で、
本リポジトリの `.agents/skills`（67 本）と**同じ形式**である。
`environment.capability_directories` に skills の親ディレクトリを登録すると
ハーネスが `SKILL.md` を探索し、name/description をコンテキストへ載せる。

- 最大 32 ディレクトリ
- 絶対パスであること、`.` / `..` を含まないこと、**既存ディレクトリ**であること
- ローカルシェルでは `skill_reference` 添付が使えず、パス指定のみ

`Test-AgentsApiConfig` は上記制約を機械的に検証する。

---

## 6. 検証

| 種別 | コマンド | 結果 |
|---|---|---|
| 単体 | `Invoke-Pester -Path tests/unit/AgentsApiPayload.Tests.ps1` | 33 passed |
| 手動 | `Invoke-AgentsApiDryRun -RepoRoot . -InputText "..."` | 公式例と同型の payload を生成、live は `config-disabled` で拒否 |
| 回帰 | `Invoke-Pester -Path tests/unit` | 全件 pass |
| 静的 | `Invoke-ArchitectureCheck` | 0 violations |

---

## 7. 実装しないと決めたこと

| 項目 | 理由 |
|---|---|
| API へ budget を渡す | 公式docにフィールドが存在しない（推測実装はしない） |
| live 呼び出し | 課金の人間決裁が前提。既定は `disabled` |
| `maxEstimatedUsd` による自動停止 | コストの実測手段が未確立。記録項目に留める |
| Anthropic 版 `managed-agents.json.template` の流用 | エンドポイント・イベント名・budget 形式が別物。契約は別ファイルに分離 |
| Webhook Gateway / self_hosted executor の実装 | 次段階（`TypeScript` ではなく PowerShell で実装する方針は維持） |

> 補足: Claude 側は `scripts/tools/managed-session-payload.js`（Node）で実装しているが、
> 本リポジトリは PowerShell ツールチェーン（Pester / ArchitectureCheck）で統一されているため、
> 同じ契約を **PowerShell モジュール**として実装した。相互参照は可能だが、コードは共有しない。
