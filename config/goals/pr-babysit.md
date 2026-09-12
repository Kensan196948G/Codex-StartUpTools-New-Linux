# Goal: PR Babysit（Specialized Goal）

PR の CI とレビューを監視し、失敗や指摘に反応して green まで持っていく。
Parent Primary: `product-assurance`。

/goal "
■ Goal
対象 PR を、CI 成功・レビュー指摘解決・コンフリクト無しの状態まで継続的に持っていく。放置せず、変化に反応する。

■ Use When
PR 監視、CI の面倒を見る、レビュー対応の継続、green までの追い込み。Router: intent が「PR 監視・babysit・CI の面倒」。

■ Priority
1 CI 失敗の解消 → 2 レビュー指摘の解決 → 3 コンフリクト解消 → 4 base 追従 → 5 再検証

■ Success Criteria
- 対象 PR の CI が成功している
- 未解決のレビュー指摘が無い
- base とのコンフリクトが無い
- 指摘に対する修正が論理単位で commit されている
- 修正後に必要な再検証が行われている

■ Scope
対象: 対象 PR の CI 失敗とレビュー指摘への対応
対象外: PR のスコープ外の改善、方針変更、無関係な修正

■ Execution Strategy
Observe PR state → On failure: diagnose → Fix → Push → Re-verify → Repeat until green
CI を待つ間は「今生きている実行のハンドル」を確認する。単に時間を空けて再確認するのは進捗ではない。

■ Agent Strategy
`.codex/agents/` の build-error-resolver（ビルド・テスト失敗）/ code-reviewer（指摘の解釈）/
e2e-runner（E2E 失敗）。修正は 1 エージェントに集約する。

■ Validation
- CI の該当 job の失敗ログを確認してから修正する
- 修正後に対象 job を再実行し成功を確認する
- レビュー指摘が実際に解消されたことを差分で確認する

■ Evidence Output
- 対象 PR URL / 各 CI job の最終結果
- 修正コミット SHA と対応する指摘
- 未解決項目と理由

■ Constraints
- 失敗ログを読まずに推測で修正しない
- CI を緑にするためだけのテスト無効化・リトライ増殖をしない
- レビュアーの意図と異なる独自解釈で押し切らない（不明なら確認する）

■ Stop Conditions
正常終了: CI 成功・指摘解決・コンフリクト無し
異常終了: 同一 CI 失敗が 3 回連続で解消しない / レビュー指摘の意図が不明 / base 側の問題 → blocked とし、状況と必要な判断を報告する
"
