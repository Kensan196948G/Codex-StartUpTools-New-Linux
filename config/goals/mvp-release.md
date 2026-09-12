# Goal: MVP Release（Primary Goal）

新規 / Prototype / PoC / MVP を、実際に利用可能な最小構成まで立ち上げる。
Specialized: `production-release`（本番公開まで進める場合）。

/goal "
■ Goal
最小限だが実際に動作し利用できる成果物を作り、動かして証拠を示す。完成度の作り込みより「実際に使える」ことを優先する。

■ Use When
新規プロジェクト、PoC、Prototype、MVP、ゼロからの立ち上げ。Router: state.json 不在、CI・テスト未整備、commit が少数。

■ Priority
1 主要導線が実際に動く → 2 起動・実行手順が再現可能 → 3 最低限のテスト → 4 文書と運用

■ Success Criteria
- 主要な利用導線が end-to-end で動作する（実機またはE2Eで確認）
- セットアップ手順が README にあり、第三者が再現できる
- 主要ロジックに最低限のテストがある
- 失敗時に原因が分かるエラー出力がある
- 既知の制限が明示されている

■ Scope
対象: MVP の主要導線、起動手順、最小のテストと文書
対象外: 網羅的なテスト、性能最適化、多環境対応、管理画面の作り込み（次フェーズ）

■ Execution Strategy
Define smallest usable path → Scaffold → Implement core → Run it → Fix what breaks → Document
「動く最小」を先に通し、その後に厚みを足す。動かないまま機能を足さない。

■ Agent Strategy
`.codex/agents/` の planner（スコープ確定）/ architect（構成決定）/ tdd-guide（主要ロジック）/
doc-updater（README）を使う。広い調査はサブエージェントへ委譲する。

■ Validation
- セットアップ手順を実際に実行して成功を確認
- 主要導線を実行し、期待結果を確認
- テストを実行し成功を確認

■ Evidence Output
- 動作確認の実行コマンドと結果
- 作成物の一覧 / 既知の制限
- commit SHA / PR URL

■ Constraints
- 動かない機能を「実装済み」と報告しない
- 過剰な抽象化・将来要件の先取りをしない
- 秘密情報をコミットしない

■ Stop Conditions
正常終了: 主要導線が動作し、手順が文書化され、テストが成功
異常終了: 外部依存や権限で主要導線が検証不能な場合は blocked とし、何が検証できていないかを明示する
"
