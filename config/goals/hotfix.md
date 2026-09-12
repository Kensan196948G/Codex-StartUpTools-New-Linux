# Goal: Hotfix（Specialized Goal）

保守期・本番障害時の最小差分修正。原因究明より復旧を優先する。
Parent Primary: `deep-debug` / `development`。

/goal "
■ Goal
本番影響を最短で止める。原因の完全解明は後回しにし、最小差分で復旧し、回帰を防ぐテストを残す。

■ Use When
本番障害対応、保守期の緊急修正、稼働中システムの最小修正。Router: phase_mode=maintenance/released かつ CI 失敗・runtime incident・blocker あり。

■ Priority
1 影響の停止（復旧）→ 2 データ整合の確認 → 3 最小差分の修正 → 4 回帰テスト → 5 根本原因の記録

■ Success Criteria
- 本番影響が停止または緩和されている
- 変更が最小差分に留まり、無関係な改変が含まれていない
- 修正に対する回帰テストが追加されている
- 根本原因の候補と、恒久対応の必要性が記録されている
- 緊急のため省略した検証が明示されている

■ Scope
対象: 障害の直接原因に対する最小の修正と、その回帰テスト
対象外: リファクタリング、設計改善、無関係な修正（恒久対応として別途実施）

■ Execution Strategy
Stop the bleeding → Confirm data integrity → Minimal fix → Regression test → Record root cause
「今止める」と「正しく直す」を分離する。今の Goal では止めることを優先する。

■ Agent Strategy
`.codex/agents/` の incident-triager（切り分け）/ build-error-resolver（Build 起因）/
code-reviewer（最小差分の妥当性）。修正は 1 エージェントに集約する。

■ Validation
- 復旧の確認（失敗していた導線が動く）
- 最小差分であることの確認（diff の範囲）
- 回帰テストの追加と成功

■ Evidence Output
- 復旧を確認した手順と結果
- 修正コミット SHA / diff の範囲
- 根本原因候補と恒久対応の提案

■ Constraints
- 原因を理解しないまま広範囲を書き換えない
- テストを skip / 削除して緑にしない
- 本番 DB の破壊的変更は人間承認を要する

■ Stop Conditions
正常終了: 復旧確認・回帰テスト追加・最小差分の記録
異常終了: 復旧不能 / 影響拡大のおそれ → 直ちに停止し、現状と推奨アクション（Rollback 含む）を報告する
"
