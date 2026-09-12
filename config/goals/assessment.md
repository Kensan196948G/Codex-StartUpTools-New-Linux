# Goal: Assessment（Primary Goal）

評価・Readiness・Architecture / Security Review・Gap 分析。指摘で終わらせず、改善実装まで進める。
Specialized: `security-emergency`（Critical 脆弱性を検出した場合）。

/goal "
■ Goal
対象を権威ある証拠に基づいて評価し、Gap を優先順位付きで特定し、実行可能な改善まで到達させる。感想や一般論を書かない。

■ Use When
評価、レビュー、監査、Readiness 判定、Gap 分析、技術的負債の評価、比較検討。Router: intent が「評価・レビュー・監査・比較」、または Security 検出で deep-debug に該当しない場合。

■ Priority
1 Security / 破壊的リスク → 2 正しさの欠陥 → 3 保守性・構造 → 4 性能・運用性

■ Success Criteria
- 評価対象と評価基準が明示されている
- 各指摘に、ファイル・行・コマンド出力などの検証可能な証拠が付いている
- 指摘が重大度順に並び、それぞれ影響と推奨対応がある
- 改善可能なものは実際に実装され、テストで確認されている
- 実装しなかった項目は理由が明示されている

■ Scope
対象: 指定された評価対象とその直接依存
対象外: 無関係な領域の全面改修、好みに基づく書き換え

■ Execution Strategy
Scope → Collect evidence → Analyze → Prioritize → Fix what is fixable → Verify → Report
推測で指摘しない。証拠が取れない場合は「未確認」と明示する。

■ Agent Strategy
`.codex/agents/` の architect（構造）/ security-reviewer（脆弱性）/ code-reviewer（品質）/
database-reviewer（DB）を観点別に使い、独立した観点はサブエージェントへ並列委譲する。

■ Validation
- 指摘ごとに、それを裏付ける証拠（ファイル:行、コマンド出力）を示す
- 実装した改善はテストで前後比較する
- 誤検知（実際には問題でないもの）を除外する

■ Evidence Output
- 評価基準と対象範囲
- 重大度順の指摘一覧（証拠・影響・推奨対応）
- 実装した改善と検証結果
- 未対応項目と理由

■ Constraints
- 証拠の無い断定を禁止
- 網羅性を装うために件数を水増ししない
- 評価ついでの無関係な変更を混ぜない

■ Stop Conditions
正常終了: 評価完了・改善実装・検証済み・報告作成
異常終了: 評価に必要な権限や環境が無く証拠が取れない場合は blocked とし、不足している証拠を列挙する
"
