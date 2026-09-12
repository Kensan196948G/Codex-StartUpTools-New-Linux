# Goal: Refactoring（Specialized Goal）

挙動を変えずに構造・重複・責務・命名を改善する。
Parent Primary: `development`。

/goal "
■ Goal
外部から観測できる挙動を一切変えずに、内部構造を改善する。テストが無い状態で構造を変えない。

■ Use When
リファクタリング、技術的負債の返済、重複排除、責務分離、命名改善。Router: intent が「リファクタ・技術的負債・cleanup」。

■ Priority
1 挙動不変の保証（テストの存在）→ 2 重複と責務の解消 → 3 命名と可読性 → 4 不要コードの削除

■ Success Criteria
- 変更前後でテスト結果が同一である（全件成功を維持）
- 公開インターフェース（API・CLI・設定キー）が変わっていない
- 重複・責務過多・デッドコードが実際に削減されている
- 変更が論理単位に分割され、レビュー可能な差分になっている
- 構造変更の理由が説明できる

■ Scope
対象: 指定された構造上の問題とその直接影響範囲
対象外: 機能追加、仕様変更、挙動の修正（必要なら別 Goal / 別 PR）

■ Execution Strategy
Establish green tests → Small steps → Run tests each step → Commit per logical unit
テストが赤い状態で構造を変えない。まず緑を確保する。

■ Agent Strategy
`.codex/agents/` の refactor-cleaner（重複・デッドコード）/ architect（責務分離の判断）/
code-reviewer（差分の妥当性）。独立した領域はサブエージェントへ並列委譲してよいが、
同一ファイルを触る変更は直列化する。

■ Validation
- リファクタ前後でテスト結果を比較（同一であること）
- 公開インターフェースの差分が無いことを確認
- 変更近傍だけでなく主要フローの回帰を確認

■ Evidence Output
- 前後のテスト結果
- 削減した重複・責務・行数
- 公開インターフェースが不変であることの確認
- commit SHA 一覧

■ Constraints
- 「ついで」の機能変更・バグ修正を混ぜない（混ざったら分離する）
- テストを通すための構造変更（テストに合わせた歪み）をしない
- 過剰な抽象化を持ち込まない

■ Stop Conditions
正常終了: 構造改善完了・テスト結果不変・公開インターフェース不変
異常終了: テストが無く挙動不変を保証できない場合は blocked とし、先に必要なテストを提案する
"
