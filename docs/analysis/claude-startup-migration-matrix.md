# Claude-StartUp Migration Matrix

## Source

- source root: `D:\Codex-StartUpTools-New\Claude-StartUp`
- intent: classify all major source areas before Codex-native migration

## Classification Summary

### Migrate directly

- `scripts/lib/TokenBudget.psm1`
- `scripts/lib/RecentProjects.ps1`
- `scripts/lib/ConfigSchema.ps1`
- `scripts/lib/ConfigLoader.ps1`
- `scripts/lib/Config.psm1`
- `scripts/lib/ArchitectureCheck.psm1`
- matching unit tests under `tests/unit`

### Migrate with adaptation

- `config/config.json.template`
  - adapt default tool and examples for Codex-first operation
- `docs/codex/*`
  - keep reusable guidance, remove references to disabled launcher paths
- `scripts/lib/LauncherCommon.psm1`
- `scripts/lib/McpHealthCheck.psm1`
- `state.schema.json`
- `state.json.example`
- `scripts/main/Start-CodexBootstrap.ps1`
- `scripts/main/Start-Codex.ps1`

### Migrate directly (additional completed slice)

- `scripts/lib/LogManager.psm1`
- `scripts/lib/ErrorHandler.psm1`
- `scripts/lib/WorktreeManager.psm1`
- `scripts/lib/MessageBus.psm1`
- `scripts/lib/StatuslineManager.psm1`
- `scripts/lib/SessionTabManager.psm1`

### Reference only

- `Claude/templates/claudeos/**`
- `.claude/claudeos/**`
- `CLAUDE.md`
- `docs/claude/*`
- `docs/copilot/*`
- Linux cron launcher templates and mail scripts

### Do not migrate as-is

- `node_modules/**`
- `.worktrees/**`
- `logs/**`
- generated reports and local runtime state

## Current Codex Target Status

- migrated modules:
  - `TokenBudget`
  - `Config` family
  - `RecentProjects`
  - `ArchitectureCheck`
  - `LogManager`
  - `ErrorHandler`
  - `WorktreeManager`
  - `MessageBus`
  - `StatuslineManager`
  - `SessionTabManager`
  - `LauncherCommon`
  - `McpHealthCheck`
  - `StateSchema`
  - `StartCodexBootstrap`
  - `StartCodex`
- migrated tests:
  - `TokenBudget`
  - `Config`
  - `ConfigSchema`
  - `RecentProjects`
  - `ArchitectureCheck`
  - `LogManager`
  - `ErrorHandler`
  - `WorktreeManager`
  - `MessageBus`
  - `StatuslineManager`
  - `SessionTabManager`

## Next Migration Queue

1. `Start-ClaudeOS` 相当の Codex bootstrap 設計の拡張
2. `CronManager` の要否再評価
3. `Config` と起動エントリポイントの統合検証
4. セッション開始前チェックの標準化
5. 起動後ダッシュボードの最小構成追加
