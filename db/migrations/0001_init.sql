-- Orchestration control-plane 初期スキーマ（additive, 後方互換）
-- 対象: AGENTS.md/CLAUDE.md §11 のローカルPostgreSQL制御プレーン
-- 破壊的変更（DROP/型変更/NOT NULL化）はここに含めない。

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orchestration_tasks (
    id          UUID PRIMARY KEY,
    task_type   TEXT NOT NULL,
    status      TEXT NOT NULL,
    payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orchestration_runs (
    id          UUID PRIMARY KEY,
    task_id     UUID NOT NULL REFERENCES orchestration_tasks(id),
    status      TEXT NOT NULL,
    started_at  TIMESTAMPTZ,
    ended_at    TIMESTAMPTZ,
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orchestration_approvals (
    id          UUID PRIMARY KEY,
    run_id      UUID REFERENCES orchestration_runs(id),
    gate        TEXT NOT NULL,
    decision    TEXT NOT NULL,
    decided_by  TEXT,
    reason      TEXT,
    decided_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orchestration_audit_events (
    id          UUID PRIMARY KEY,
    task_id     UUID,
    run_id      UUID,
    event_type  TEXT NOT NULL,
    detail      JSONB NOT NULL DEFAULT '{}'::jsonb,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orchestration_runs_task_id ON orchestration_runs(task_id);
CREATE INDEX IF NOT EXISTS idx_orchestration_approvals_run_id ON orchestration_approvals(run_id);
CREATE INDEX IF NOT EXISTS idx_orchestration_audit_events_task_id ON orchestration_audit_events(task_id);
CREATE INDEX IF NOT EXISTS idx_orchestration_audit_events_occurred_at ON orchestration_audit_events(occurred_at DESC);
