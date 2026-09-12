# Goal: Development（Primary Goal）

既存 Project の通常開発・継続改善。機能追加、改善、バグ修正（軽微）、UI/UX、API 改善、運用改善。
Specialized: `refactoring`（構造改善）/ `hotfix`（保守期の最小差分修正）。

/goal "
■ Goal
要求された変更を、既存の設計・規約・テストを壊さずに実装し、検証と証拠まで完了させる。調査や計画で止めない。

■ Use When
既存 Project への機能追加・改善・軽微な修正・UI/UX・API 改善・運用改善。Router: phase_mode=maintenance/released、または他に強い Evidence が無い既定経路。

■ Priority
1 既存の破壊を止める → 2 要求された変更の完遂 → 3 テストと文書 → 4 周辺の改善

■ Success Criteria
- 要求された変更が実装され、動作が確認できる
- 変更近傍のテストが追加または更新され、全て成功する
- lint / 型検査 / build が成功する
- 既存機能に回帰が無い
- README / 設計書と実装が一致している
- 作業ブランチに論理単位で commit され、PR が作成される

■ Scope
対象: 要求された変更とその直接影響範囲、および対応するテスト・文書
対象外: 無関係なリファクタリング、依存の大規模更新、スキーマ変更（必要なら別 PR + 人間承認）

■ Execution Strategy
Inspect → Plan → Implement → Test → Review → Document → PR
既存パターンを最優先で踏襲する。新しい抽象化は必要性が証明できたときだけ導入する。

■ Agent Strategy
`.codex/agents/` の planner（計画）/ architect（設計判断）/ tdd-guide（テスト先行）/
code-reviewer（レビュー）を変更規模に応じて使う。独立した調査はサブエージェントへ
委譲し、編集は同一ファイル競合を避けるため 1 エージェントに集約する。

■ Validation
- 変更近傍のテストを実行し成功を確認
- 主要フローに回帰が無いことをテストまたは実機で確認
- `codex review --base <base>` でレビュー観点の抜けを確認

■ Evidence Output
- 変更ファイル一覧 / 追加・更新したテスト名と結果
- 実行した検証コマンドと出力の要約
- commit SHA / PR URL

■ Constraints
- 既存のユーザー変更を破棄しない
- テストを通すためだけの改変（アサーション緩和・skip 追加）を禁止
- 要求を勝手に縮小しない。完了できない場合は未完了であると明示する

■ Stop Conditions
正常終了: 変更実装・テスト成功・文書更新・PR 作成
異常終了: 同一の阻害要因が 3 ターン連続で解消しない場合は blocked とし、原因と次の一手を報告する
"
