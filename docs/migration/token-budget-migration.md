# Token Budget Migration

## Purpose

Provide a Codex-native token budget module that can:

- classify budget usage into operating zones
- gate work phases based on the active zone
- update persisted usage in `state.json`
- rebalance phase allocation when conditions change

## Source Mapping

- source repository: `D:\ClaudeCode-StartUpTools-New`
- source module: `scripts/lib/TokenBudget.psm1`
- source tests: `tests/unit/TokenBudget.Tests.ps1`

## Codex Adaptation Notes

- kept the zone model and phase-allocation logic because it is tool-agnostic
- removed the implicit dependency on Git repository detection for normal operation
- default state-file resolution now uses the current working directory when no root is provided
- preserved JSON persistence and Pester-based verification so the migrated behavior stays locally testable in Codex

## Verification Method

Run:

```powershell
Invoke-Pester .\tests\unit\TokenBudget.Tests.ps1
```

Expected:

- all tests pass
- state creation, update, status, and reallocation behaviors remain verified

## Migration Classification

- classification: migrate with adaptation
- rationale: the feature is reusable, but the original repository-root lookup assumed Git context that is not required in the Codex target
