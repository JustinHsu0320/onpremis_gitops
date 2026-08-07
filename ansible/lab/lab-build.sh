#!/usr/bin/env bash
# =============================================================================
# lab-build.sh — 實驗室建置前置作業
#   1. 產生實驗室專用 SSH 金鑰（不進 Git；等同 prod 的 ~/.ssh/id_platform）
#   2. build 兩個映像 target（base / controller）
# 冪等：金鑰存在就跳過；映像靠 Docker layer cache
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .ssh/id_lab ]]; then
  echo ">>> 產生實驗室 SSH 金鑰 (.ssh/id_lab)"
  mkdir -p .ssh
  ssh-keygen -t ed25519 -f .ssh/id_lab -N '' -C 'ansible@platform-lab' >/dev/null
  chmod 600 .ssh/id_lab
fi

echo ">>> build 節點映像（ubuntu:26.04 + systemd + sshd）"
docker compose build

echo ">>> lab-build 完成"
