-- Human Gate対応（additive, 後方互換）
-- 対象: AGENTS.md/CLAUDE.md §7・§11、Phase 3 オーケストレーション基盤
-- decision='pending'（承認待ち）を表現できるよう、requested_atを追加し
-- decided_atの必須制約・既定値を緩和する（既存レコードのdecided_atは変更しない）。

ALTER TABLE orchestration_approvals ADD COLUMN IF NOT EXISTS requested_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE orchestration_approvals ALTER COLUMN decided_at DROP NOT NULL;
ALTER TABLE orchestration_approvals ALTER COLUMN decided_at DROP DEFAULT;

CREATE INDEX IF NOT EXISTS idx_orchestration_approvals_pending
    ON orchestration_approvals(decision, requested_at)
    WHERE decision = 'pending';
