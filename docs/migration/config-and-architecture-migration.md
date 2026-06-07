# Config And Architecture Migration

## Purpose

Migrate the reusable configuration and architecture guard layers from the Claude-oriented source into Codex-first local tooling.

## Source Mapping

- source root: `Claude-StartUp`
- source files:
  - `scripts/lib/Config.psm1`
  - `scripts/lib/ConfigLoader.ps1`
  - `scripts/lib/ConfigSchema.ps1`
  - `scripts/lib/RecentProjects.ps1`
  - `scripts/lib/ArchitectureCheck.psm1`
  - `scripts/lib/LogManager.psm1`
  - `scripts/lib/ErrorHandler.psm1`
  - `scripts/lib/WorktreeManager.psm1`
  - `scripts/lib/MessageBus.psm1`
  - `scripts/lib/StatuslineManager.psm1`
  - `scripts/lib/SessionTabManager.psm1`
  - `scripts/lib/LauncherCommon.psm1`
  - `scripts/lib/McpHealthCheck.psm1`
  - `config/config.json.template`
- source tests:
  - `tests/unit/Config.Tests.ps1`
  - `tests/unit/ConfigSchema.Tests.ps1`
  - `tests/unit/RecentProjects.Tests.ps1`
  - `tests/unit/ArchitectureCheck.Tests.ps1`
  - `tests/unit/LogManager.Tests.ps1`
  - `tests/unit/ErrorHandler.Tests.ps1`
  - `tests/unit/WorktreeManager.Tests.ps1`
  - `tests/unit/MessageBus.Tests.ps1`
  - `tests/unit/StatuslineManager.Tests.ps1`
  - `tests/unit/SessionTabManager.Tests.ps1`
  - `tests/unit/LauncherCommon.Tests.ps1`
  - `tests/unit/McpHealthCheck.Tests.ps1`

## Codex Adaptation Notes

- kept schema validation and recent-project history because they are runtime-agnostic
- changed the config template to `codex` default-first values
- treated Claude launcher and cron-specific settings as optional future extensions rather than target defaults
- kept architecture rules that protect code quality and Git workflow, but did not wire them to Claude-specific boot flows
- kept log rotation and categorized error handling as reusable operational helpers
- simplified some user-facing wording for Codex-first local use
- kept Git worktree lifecycle helpers because they are directly applicable to Codex repository operations
- kept the state.json-backed message bus because it provides a reusable low-friction coordination primitive
- kept statusLine extraction and remote sync primitives, while treating actual rollout policy as Codex-specific follow-up
- kept session.json lifecycle management as reusable persistence, while not carrying over the original Windows Terminal tab assumptions
- kept a small launcher-common subset for path, config, and drive-resolution behavior without carrying over the original full launcher stack
- kept MCP diagnostics as a reduced inspection layer, excluding the original Claude-specific runtime orchestration
- reduced `state.json` / `state.schema.json` to the minimum shape required by migrated Codex modules
- replaced the old multi-tool `Start-*` launcher tree with a Codex bootstrap plus a single Codex entrypoint for local-first startup
- expanded the Codex bootstrap to emit explicit preflight checks and update `state.json.execution` for startup continuity
- connected bootstrap and launcher to `MessageBus` so phase transitions are published into `state.json`
- connected startup scripts to `LogManager` so bootstrap and local launch flows leave standardized session logs
- connected startup scripts to `ErrorHandler` so bootstrap and launcher failures are rendered with shared error categories
- added a bootstrap readiness verdict so preflight results are summarized as `READY`, `READY_WITH_WARNINGS`, or `BLOCKED`

## Verification Method

Run:

```powershell
Invoke-Pester .\tests\unit\TokenBudget.Tests.ps1, .\tests\unit\Config.Tests.ps1, .\tests\unit\ConfigSchema.Tests.ps1, .\tests\unit\RecentProjects.Tests.ps1, .\tests\unit\ArchitectureCheck.Tests.ps1, .\tests\unit\LogManager.Tests.ps1, .\tests\unit\ErrorHandler.Tests.ps1, .\tests\unit\WorktreeManager.Tests.ps1, .\tests\unit\MessageBus.Tests.ps1, .\tests\unit\StatuslineManager.Tests.ps1, .\tests\unit\SessionTabManager.Tests.ps1, .\tests\unit\LauncherCommon.Tests.ps1, .\tests\unit\McpHealthCheck.Tests.ps1, .\tests\unit\StateSchema.Tests.ps1, .\tests\unit\StartCodexBootstrap.Tests.ps1, .\tests\unit\StartCodex.Tests.ps1
```

Expected:

- all migrated unit tests pass
- config template validates under the migrated schema
- architecture checks detect critical and warning cases correctly
- log summary and rotation behavior remain verified
- categorized error detection remains verified
- worktree summary and base-path behavior remain verified
- message publish / consume / status behavior remains verified
- statusLine extraction behavior remains verified
- session metadata persistence behavior remains verified
- launcher path and SSH-drive resolution behavior remains verified
- MCP argument escaping behavior remains verified
- reduced state example remains compatible with `TokenBudget` and `MessageBus`
- bootstrap and Codex entrypoint scripts remain dry-run and local-launch verifiable
