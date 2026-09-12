# Goal: Security Emergency（Specialized Goal）

Critical 脆弱性・漏洩・侵害への緊急対応。秘匿を最優先し、通常の開発フローを止める。
Parent Primary: `deep-debug` / `assessment`。

/goal "
■ Goal
Critical なセキュリティ問題を封じ込め、影響範囲を確定し、安全に修正する。秘密情報を出力・コミット・ログに残さない。

■ Use When
Critical 脆弱性、認証認可の破綻、秘密情報の漏洩、依存の重大 CVE、侵害の疑い。Router: kpi.security_critical > 0、または intent が「脆弱性・漏洩・侵害・CVE」。

■ Priority
1 秘匿の維持（二次漏洩防止）→ 2 封じ込め → 3 影響範囲の確定 → 4 修正 → 5 再発防止

■ Success Criteria
- 問題の種類・影響範囲・悪用可能性が証拠付きで示されている
- 秘密情報がコード・ログ・出力・コミット履歴に残っていない
- 修正が適用され、悪用シナリオが成立しないことが確認されている
- 再発防止（テスト・検査・設定）が入っている
- 公開・報告の要否が判断されている

■ Scope
対象: 当該脆弱性とその直接影響範囲、および封じ込めに必要な最小変更
対象外: 無関係な機能改修、全面的な作り直し

■ Execution Strategy
Contain → Assess impact → Fix → Verify exploit is closed → Prevent recurrence → Report (sanitized)
証拠を集めるときも秘密情報そのものを出力に含めない（値は伏せ、所在と種別のみ記録する）。

■ Agent Strategy
`.codex/agents/` の security-reviewer（分析）/ code-reviewer（修正の妥当性）/ incident-triager（切り分け）。
分析と修正を分離し、修正は単一エージェントに集約する。

■ Validation
- 悪用シナリオが修正前に成立し、修正後に成立しないことを確認する
- 秘密情報のスキャンを実行し、検出が 0 であることを確認する
- 依存関係の監査を実行する

■ Evidence Output
- 脆弱性の種別（CVE / CWE 等）と影響範囲
- 修正コミット SHA / 検出を防止するテスト名
- 秘密情報スキャン結果（値は記載しない）
- 未解決のリスクと推奨対応

■ Constraints
- 秘密情報の実値を出力・ログ・コミットに含めない（マスクまたは所在のみ）
- 証拠収集を理由に攻撃コードを実行しない
- 影響を広げる可能性のある検証は隔離環境で行う

■ Stop Conditions
正常終了: 封じ込め・修正・検証・再発防止が完了
異常終了: 影響範囲が不明 / 権限不足 / 外部調整が必要 → blocked とし、判明した事実とリスクを秘匿に配慮して報告する
"
