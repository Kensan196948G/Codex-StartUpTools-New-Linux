# Goal: Product Assurance（Primary Goal）

Release 前の総合品質保証。Contract・E2E・性能・A11y・Security・DB 復旧・監査を横断確認する。
Specialized: `production-release` / `safe-auto-merge` / `pr-babysit`。

/goal "
■ Goal
出荷可否を、機能・契約・データ・性能・安全・運用品質の各面から証拠に基づいて判定する。未確認を「問題なし」と扱わない。

■ Use When
リリース前判定、総合テスト、受入テスト、Contract / E2E / 性能 / A11y / Security / DB 復旧 / 監査。Router: deploy.ready=true、execution.phase=Release、stable_achieved=true。

■ Priority
1 データ破壊・セキュリティ → 2 契約破壊・後方互換 → 3 主要導線の機能不全 → 4 性能・A11y → 5 監査証跡

■ Success Criteria
- 対象範囲と各品質面の確認結果が表形式で示されている
- 各面について「確認済み / 未確認 / 不合格」が明示され、未確認を残さない
- 不合格項目は修正され、再検証されている
- DB migration と rollback が検証されている（該当する場合）
- 出荷可否の判定と、その根拠が示されている

■ Scope
対象: リリース対象の全変更と、その品質面（機能・契約・データ・性能・安全・運用）
対象外: 新機能追加、範囲外のリファクタリング

■ Execution Strategy
Freeze scope → Enumerate quality dimensions → Verify each with evidence → Fix failures → Re-verify → Judge
各面について「何が証拠になれば合格か」を先に決めてから検証する。

■ Agent Strategy
`.codex/agents/` の e2e-runner（E2E）/ code-reviewer（横断品質）/ security-reviewer（安全）/
database-reviewer（DB・migration）/ release-manager（出荷判定）。独立した品質面は
サブエージェントへ並列委譲し、最終判定は 1 エージェントに集約する。

■ Validation
- 主要導線を E2E または実機で実行
- API / DB 契約の後方互換を確認
- migration と rollback を検証環境で実行
- 性能・A11y は基準値を決めて計測

■ Evidence Output
- 品質面ごとの確認結果表（確認方法・結果・証拠）
- 未確認項目とその理由
- migration / rollback の検証結果
- 出荷可否の判定と根拠

■ Constraints
- 「テストが通った」を「品質が保証された」と同一視しない。検証範囲と要件の範囲を一致させる
- 未検証項目を合格として扱わない
- 本番デプロイ・本番 DB migration は人間の承認を要する

■ Stop Conditions
正常終了: 全品質面が確認済みで出荷可否を判定できる
異常終了: 検証環境や権限が無く確認できない面が残る場合は blocked とし、未確認面を列挙する
"
