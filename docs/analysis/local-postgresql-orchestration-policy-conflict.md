# ローカルPostgreSQL制御プレーン導入に伴う方針矛盾の記録

状態: 2026-09-13 記録（ユーザー承知のうえで進行、解消はしていない）
関連: `AGENTS.md` §5・§11、`CLAUDE.md` §5・§11、
`docs/architecture/local-postgresql-control-plane.md`

## 背景

Codex-StartUpTools-New-Linux をAIオーケストレーション基盤（Task／Run／Approval／Audit
を扱う制御プレーン）へ発展させる提案の一環として、内部運用状態の保存先にローカル
（自己ホスト）PostgreSQLを用いる方針を `AGENTS.md`／`CLAUDE.md` §11 に追加した。
これに伴い、既存の §5（Production deployment policy）にあった
「Webサービスの本番基盤はCloudflare（Pages／Workers）とNeon PostgreSQLとする」という
記述からNeonを既定前提として外した。

## 矛盾の内容

組織最上位方針 `/etc/claude-code/CLAUDE.md` §4（Production deployment policy）は次のように
定めている（本セッション時点の記載、要約せず原文の要点のみ引用）。

> Webサービスの場合はCloudflare（Pages／Workers）とNeon PostgreSQLを本番基盤とする。

同ファイル §1 は次を定める。

> 下位の指示が本ファイルと競合する場合は本ファイルを優先する。

つまり、組織方針は全プロジェクト共通の最上位方針であり、プロジェクト側
（本リポジトリの `AGENTS.md`／`CLAUDE.md`）の記述で緩和・上書きすることはできない。
本リポジトリ側の §5 からNeonを既定前提として外したことは、**文言上組織方針と矛盾したまま**
であり、この矛盾は本対応では解消していない。

## 対応方針（今回の判断）

ユーザーへ矛盾を提示したうえで、次の判断を得た。

- 矛盾を承知のうえで、プロジェクト側 (`AGENTS.md`／`CLAUDE.md`) の §5 からNeonを既定前提
  として外す方向で書き換える
- ただし実際に外部公開Webサービスの本番DBを選定する場面では、組織方針が優先されるため
  Neon PostgreSQLを含めて都度ユーザーに確認する（`AGENTS.md`／`CLAUDE.md` §11に明記済み）
- §11で新設したローカルPostgreSQL制御プレーンは、外部公開Webサービスの本番DBではなく、
  このツール自身の内部運用状態（Task／Run／Approval／Audit）を保存する別レイヤーである
  ことを明記し、組織方針の対象（外部公開Webサービスの本番基盤）と混同しないようにした

## 未解消のリスク

- 組織方針 `/etc/claude-code/CLAUDE.md` 自体は本セッションから変更できないため、
  「Webサービス本番基盤=Neon」という最上位方針は今後も有効なまま残る
- 将来、本リポジトリを使って実際に外部公開Webサービスを本番デプロイする場面になった際、
  §5の記述（Neonを既定前提としない）と組織方針（Neonを本番基盤とする）のどちらに従うかで
  混乱しないよう、都度ユーザーに確認する運用を徹底する必要がある
- `GITHUB_POLICY.md` および `docs/architecture/CloudflareNeonGitHub自動化仕様.md`
  （正本は `/home/kensan/Projects/Deep-Seek-Harness-Project` 側の中央配布コピー）は
  今回のスコープでは変更していない。これらにも同様にNeon前提の記述が残っており、
  DeepSeek Harness側リポジトリでの対応が別途必要

## 解消に向けた次の一歩（提案・未着手）

1. 組織方針 `/etc/claude-code/CLAUDE.md` §4 の見直しが必要かどうかをユーザー（環境管理者）
   に確認する
2. 見直す場合は、「Webサービス本番基盤」と「オーケストレーション制御プレーン」を
   組織方針レベルでも明確に区別する形に更新する
3. DeepSeek Harness側の中央配布ファイル（`GITHUB_POLICY.md`、
   `docs/architecture/CloudflareNeonGitHub自動化仕様.md` の正本）も同じ区別を反映し、
   本リポジトリへ再配布する
