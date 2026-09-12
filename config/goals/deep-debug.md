# Goal: Deep Debug（Primary Goal）

CI 失敗・Runtime Error・Regression・API/DB/認証/Build/Deployment/E2E 失敗・本番障害・原因不明の不具合の根本原因解析。
Specialized: `hotfix`（保守期の最小差分修正）/ `security-emergency`（Critical 脆弱性）。

/goal "
■ Goal
再現 → 観測 → 仮説 → 切り分け → 根本原因 → 最小修正 → 回帰テスト → 全体検証 → 証拠。症状だけを抑える修正は禁止。

■ Use When
CI Failure / Runtime Error / Regression / API・DB・認証・Build・Deployment・E2E 失敗 / 本番障害解析 / 原因不明の不具合。Router: ci=failure、runtime health down、intent が「直して・バグ・エラー・回帰」、Blocker あり。

■ Priority
1 Security Critical（security-emergency へ）→ 2 本番影響のある障害（hotfix）→ 3 CI 失敗 → 4 Regression → 5 その他不具合

■ Success Criteria
- 再現手順と観測結果（ログ・スタック・失敗テスト）が記録されている
- 根本原因が特定され、原因と修正の対応が説明できる
- 最小差分で修正され、再発防止の回帰テストが追加されている
- 影響範囲の回帰テストと CI が成功し、PR が作成されている

■ Scope
対象: 不具合の原因箇所と直接影響範囲、回帰テスト
対象外: リファクタリング、新機能、無関係な変更、スキーマ変更（必要なら別 PR + 人間承認）

■ Execution Strategy
Reproduce → Observe → Hypothesis → Isolate → Root Cause → Minimal Fix → Regression Test → Full Verify → Evidence
同一原因への修復を 2 回失敗したら仮説を捨てて再観測する。

■ Agent Strategy
`.codex/agents/` の incident-triager（切り分け・read-only 並列可）/ build-error-resolver（Build 失敗）/
code-reviewer（修正の妥当性）/ security-reviewer（必要時）。修正は 1 エージェントに集約し競合を避ける。
独立した仮説の検証はサブエージェントへ並列委譲してよい。

■ Validation
- 失敗していたテスト・CI が成功する
- 追加した回帰テストが「修正前に失敗し、修正後に成功する」ことを確認する
- 症状ではなく原因が消えていることを確認する

■ Evidence Output
- 再現手順 / 根本原因 / 修正コミット SHA
- 回帰テスト名と前後の結果
- CI Run URL / 影響ファイル一覧

■ Constraints
- 症状抑制（try/catch での握り潰し・テスト skip・retry 無限化）を禁止
- 同一エラー同一原因が 2 回連続したら即停止して RCA を残す
- 原因が特定できないまま推測で修正しない

■ Stop Conditions
正常終了: 根本原因修正・回帰テスト追加・CI 成功・PR 作成
異常終了: 再現不能で追加情報が必要 / 権限不足 / 修復上限到達 → blocked。
その際は Evidence・根本原因候補・試行回数・推奨アクションを必ず残す
"
