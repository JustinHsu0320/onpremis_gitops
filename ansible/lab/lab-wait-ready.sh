#!/usr/bin/env bash
# =============================================================================
# lab-wait-ready.sh — 等待實驗室就緒並完成控制節點初始化
#   1. 等 21 個容器的 systemd 到達 running（degraded 容忍但會警告）
#   2. 在 mgmt-01 內收錄所有節點的 SSH host key（等同 prod 的「新機納管」程序：
#      host_key_checking=True 是刻意的 MITM 防護，不用 disable 繞過）
#   3. ansible ping 全節點驗證連通
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# lab 容器名前綴 = compose 專案名（docker-compose.yml 的 name:）
PREFIX=platform

NODES=(lb-01 lb-02 kong-01 kong-02 app-01 app-02 app-03
       pg-01 pg-02 pg-03 mq-01 mq-02 mq-03
       scylla-01 scylla-02 scylla-03 nfs-01 sw-01 sw-02 sw-03 mgmt-01)
# 各節點的「主要 IP」（inventory 的 ansible_host，mgmt 由此 ssh 過去）
IPS=(10.20.10.11 10.20.10.12 10.20.20.21 10.20.20.22
     10.20.20.11 10.20.20.12 10.20.20.13
     10.20.30.11 10.20.30.12 10.20.30.13 10.20.30.21 10.20.30.22 10.20.30.23
     10.20.30.31 10.20.30.32 10.20.30.33
     10.20.40.11 10.20.40.21 10.20.40.22 10.20.40.23)

echo ">>> 等待 systemd 開機完成（最多 180s）"
for n in "${NODES[@]}"; do
  c="${PREFIX}-${n}"
  for i in $(seq 1 36); do
    state=$(docker exec "$c" systemctl is-system-running 2>/dev/null || true)
    case "$state" in
      running)  echo "    $n: running"; break ;;
      degraded) echo "    $n: degraded（可接受，失敗單元如下）"
                docker exec "$c" systemctl --failed --no-legend || true
                break ;;
      *)        sleep 5 ;;
    esac
    [[ $i -eq 36 ]] && { echo "!!! $n 開機逾時（state=$state）"; exit 1; }
  done
done

echo ">>> mgmt-01 收錄各節點 SSH host key（known_hosts）"
docker exec "${PREFIX}-mgmt-01" bash -c "
  mkdir -p /root/.ssh && : > /root/.ssh/known_hosts
  for ip in ${IPS[*]}; do
    until ssh-keyscan -T 5 -H \$ip 2>/dev/null | grep -q .; do sleep 2; done
    ssh-keyscan -T 5 -H \$ip >> /root/.ssh/known_hosts 2>/dev/null
  done
  chmod 600 /root/.ssh/known_hosts
  echo '    已收錄' \$(grep -c . /root/.ssh/known_hosts) '筆 host key'
"

echo ">>> ansible ping 全節點"
docker exec "${PREFIX}-mgmt-01" bash -c \
  "cd /work/ansible && ansible -i inventories/lab/hosts.yml all -m ping -o"

echo ">>> 實驗室就緒。下一步：make lab-deploy"
