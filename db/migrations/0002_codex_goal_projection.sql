-- Codex Goal Shadow Projection（additive, 後方互換）
-- 対象: AGENTS.md/CLAUDE.md §11、docs/architecture/local-postgresql-control-plane.md §2
-- Codex内部状態（~/.codex/goals_*.sqlite）からの読み取り専用投影を保存する。
-- ここへの書き込みはAdapter経由のみ。Codex内部SQLiteへは一切書き込まない。

CREATE TABLE IF NOT EXISTS codex_goal_projections (
    thread_id           TEXT PRIMARY KEY,
    goal_id             TEXT NOT NULL,
    objective           TEXT NOT NULL,
    status              TEXT NOT NULL,
    token_budget        BIGINT,
    tokens_used         BIGINT NOT NULL DEFAULT 0,
    time_used_seconds   BIGINT NOT NULL DEFAULT 0,
    codex_updated_at_ms BIGINT NOT NULL,
    synced_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_codex_goal_projections_status ON codex_goal_projections(status);
CREATE INDEX IF NOT EXISTS idx_codex_goal_projections_synced_at ON codex_goal_projections(synced_at DESC);
