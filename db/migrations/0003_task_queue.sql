-- Task Queue対応（additive, 後方互換）
-- 対象: AGENTS.md/CLAUDE.md §11、Phase 3 オーケストレーション基盤

ALTER TABLE orchestration_tasks ADD COLUMN IF NOT EXISTS priority INTEGER NOT NULL DEFAULT 0;
ALTER TABLE orchestration_tasks ADD COLUMN IF NOT EXISTS leased_until TIMESTAMPTZ;
ALTER TABLE orchestration_tasks ADD COLUMN IF NOT EXISTS leased_by TEXT;

CREATE INDEX IF NOT EXISTS idx_orchestration_tasks_queue
    ON orchestration_tasks(status, priority DESC, created_at ASC);
