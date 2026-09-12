# Goal: Production Release（Specialized Goal）

本番リリースの実行と事後確認。deploy.ready と Runbook が前提。
Parent Primary: `product-assurance` / `mvp-release`。

/goal "
■ Goal
承認済みの変更を本番へ段階的に反映し、健全性を確認し、問題があれば安全に戻す。人間の承認無しに本番操作を開始しない。

■ Use When
本番リリース、デプロイ準備、release candidate、署名/signoff 待ち。Router: deploy.ready=true、execution.phase=Release、intent が「本番リリース・デプロイ準備・signoff」。

■ Priority
1 承認と Rollback 手段の確保 → 2 データ整合 → 3 段階反映 → 4 健全性確認 → 5 記録

■ Success Criteria
- 本番操作の前に人間の明示承認が得られている
- Rollback 手順が用意され、実行可能であることが確認されている
- 段階的デプロイの各段で健全性が確認されている
- リリース後に主要導線のスモークテストが成功している
- 実施内容・結果・ロールバック可否が記録されている

■ Scope
対象: 承認済み変更の本番反映、スモークテスト、監視確認
対象外: 未承認の変更、計画外の設定変更、本番 DB の破壊的 migration（個別承認が必要）

■ Execution Strategy
Confirm approval → Verify rollback plan → Stage deploy → Health check each stage → Smoke test → Record
各段で「次へ進む条件」を先に決める。条件を満たさなければ止める。

■ Agent Strategy
`.codex/agents/` の release-manager（手順統括）/ e2e-runner（スモーク）/ security-reviewer（本番露出確認）。
本番操作は単一エージェントに集約する。

■ Validation
- 各段のヘルスチェック結果
- 主要導線のスモークテスト
- ログ・メトリクスに異常が無いこと
- Rollback 手順のドライラン（可能な場合）

■ Evidence Output
- 承認記録 / デプロイ ID または URL
- 各段の健全性確認結果
- スモークテスト結果
- Rollback 実施の有無と結果

■ Constraints
- 人間の承認無しに本番デプロイ・本番 DB migration を実行しない
- 失敗時に自動で本番を壊す操作（強制上書き・削除）を行わない
- 秘密情報をログや出力に残さない

■ Stop Conditions
正常終了: 本番反映完了・健全性確認・記録完了
異常終了: 承認が無い / 健全性が回復しない / Rollback が必要と判断 → 直ちに停止し、状況と推奨アクションを報告する
"
