# Goal: Safe Auto Merge（Specialized Goal）

品質ゲートを満たした PR を、安全条件の下で自動マージする。
Parent Primary: `product-assurance`。

/goal "
■ Goal
品質ゲートを全て満たした PR のみをマージする。条件が欠けていればマージせず、不足を明示する。高リスク変更は人間の承認へ回す。

■ Use When
PR の自動マージ判断、品質ゲート充足の確認、マージ可否の判定。Router: intent が「自動マージ・マージして・merge」。

■ Priority
1 高リスク変更の除外（人間承認へ）→ 2 必須ゲートの充足 → 3 コンフリクト解消 → 4 マージ実行 → 5 事後確認

■ Success Criteria
- 必須ゲート（テスト / lint / 型検査 / architecture / CI）が全て成功している
- レビュー指摘が全て解決している
- base とのコンフリクトが無い、または解消されている
- 高リスク変更（DNS / secret / 認証方式 / 破壊的 migration / 課金 / 公開範囲 / release）を含む場合はマージせず人間へ回している
- マージ後の CI が成功している

■ Scope
対象: 対象 PR のゲート確認とマージ操作
対象外: ゲートを満たすための無関係な改修、方針文書の変更

■ Execution Strategy
Freeze PR head → Verify each gate with evidence → Classify risk → Merge or escalate → Confirm post-merge
ゲートは「実行された」ではなく「成功した出力」で確認する。

■ Agent Strategy
`.codex/agents/` の release-manager（ゲート統括）/ code-reviewer（指摘解決の確認）/
security-reviewer（高リスク判定）。マージ操作は単一エージェントに集約する。

■ Validation
- 各ゲートの実行結果を個別に確認（緑の主張ではなく出力を見る）
- マージ対象の commit SHA が検証済みのものと一致することを確認
- マージ後の CI 結果を確認

■ Evidence Output
- ゲートごとの結果と根拠
- リスク分類の判定と理由
- マージ commit SHA / マージ後の CI 結果

■ Constraints
- 高リスク変更を自動マージしない（人間の明示承認が必須）
- ゲートをスキップ・無効化してマージしない
- 検証後に head が更新されていたら再検証する

■ Stop Conditions
正常終了: 全ゲート充足・マージ完了・事後 CI 成功
異常終了: ゲート不足 / 高リスク判定 / コンフリクト未解消 → マージせず blocked とし、不足条件を列挙する
"
