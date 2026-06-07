#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[ERROR] PowerShell 7 (pwsh) が見つかりません。"
  echo "        https://github.com/PowerShell/PowerShell からインストールしてください。"
  exit 1
fi

if [[ ! -f "scripts/main/Start-Menu.ps1" ]]; then
  echo "[ERROR] scripts/main/Start-Menu.ps1 が見つかりません。"
  echo "        リポジトリが正しくクローンされているか確認してください。"
  exit 1
fi

if [[ ! -f "config/config.json" ]]; then
  if [[ ! -f "config/config.json.template" ]]; then
    echo "[ERROR] config/config.json.template が見つかりません。"
    exit 1
  fi
  cp "config/config.json.template" "config/config.json"
  echo "[SETUP] config/config.json を作成しました。"
fi

if [[ ! -f "state.json" && -f "state.json.example" ]]; then
  cp "state.json.example" "state.json"
  echo "[SETUP] state.json を state.json.example から作成しました。"
fi

echo
echo "============================================"
echo " Codex StartUp Tools for Linux"
echo "============================================"
echo
echo "Project: $SCRIPT_DIR"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

exec pwsh -NoLogo -NoProfile -File "scripts/main/Start-Menu.ps1"
