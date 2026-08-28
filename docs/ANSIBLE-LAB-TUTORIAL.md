# Ansible 平台部署教學 — MIS 三台 Ubuntu Lab 實戰手冊

> **對象**：拿到 MIS 建好的三台 Ubuntu 實體機（或 VM），想把 `ansible/` 這套平台
> 一個服務一個服務啟動起來、搞懂每一步在做什麼的人。
> **前提**：讀過 `ansible/CONVENTIONS.md`（介面契約）與 README §8（部署指南）更好，
> 但本文自成一體，會在每一步指回契約出處。
> **怎麼用**：§1 先選路線 → §2 把需求丟給 MIS → §3 準備控制節點 →
> §4/§6 照路線操作，每個階段的細節查 §5 → 想請 AI 幫忙寫/改 role 時看 §7。

---

## 目錄

1. [三台機器的現實：先選路線](#1-三台機器的現實先選路線)
2. [給 MIS 的需求清單（機器、網路、開通事項）](#2-給-mis-的需求清單)
3. [控制節點準備](#3-控制節點準備)
4. [路線 A：Docker Lab 全鏈實戰（主線）](#4-路線-adocker-lab-全鏈實戰主線)
5. [逐階段部署手冊（00 → 99）](#5-逐階段部署手冊00--99)
6. [路線 B：三台實體機「一次一個組件」輪練](#6-路線-b三台實體機一次一個組件輪練)
7. [與 AI 協作產生 Playbook 的方法](#7-與-ai-協作產生-playbook-的方法)
8. [常用指令速查](#8-常用指令速查)

---

## 0. 開始前：這套 repo 的部署模型（5 分鐘版）

四個心智模型，貫穿全文：

1. **inventory 群組 = 組件選單**。兩套 inventory（`prod`/`lab`）永遠宣告
   *全部* 平台群組；不用的組件留空群組（`kong: hosts: {}`），對應 play 自動
   skip。**留空、不要刪**——群組不存在時模板裡的 `groups['kong']` 直接爆
   undefined（CONVENTIONS §1）。
2. **site.yml 的順序就是依賴**（CONVENTIONS §9）：

   ```
   00 基線 → 05 資料碟 → 08 Docker → 10 PKI
     → 20 NFS → { 30 PG, 31 MQ, 32 KeyDB, 33 Scylla }
     → 34 SeaweedFS（依賴 30：filer 元資料在 PG）
     → 35 Kong → 40 邊界 LB → 41 Egress
     → 50 各專案應用 → 60 監控 → 99 全鏈驗收
   70 GitLab 獨立（只依賴 00/10）
   ```

3. **CONVENTIONS.md 是介面契約**：變數名、埠號、路徑、PKI、專案層 schema
   全部以它為準。改任何一項 = 先改契約走 PR，再改程式碼。
4. **防呆方向**：`ansible.cfg` 預設 `inventory=prod`、`become=true`。
   打 **lab 才要多打參數**（`-i inventories/lab/hosts.yml`），打 prod 不用——
   「預設值必須是需要最謹慎的那個」。vault 兩把鑰匙也自動分流：
   `prod@.vault_pass`（不進 Git）、`lab@lab/vault_pass.txt`（刻意進 Git，佔位值）。

---

## 1. 三台機器的現實：先選路線

### 1.1 為什麼 3 台不能直接跑完整平台

prod 拓撲是 23 台 VM / 13 個群組。把多個群組疊在同一台機器上，會踩到
四個「同名相撞」的 group_vars 變數——Ansible 同深度群組按**字母序合併、
後載者靜默全贏**，部署期零報錯、功能無聲消失：

| 相撞變數 | 定義它的群組 | 疊在同機的後果 |
|---|---|---|
| `haproxy_profile` | lb / postgres / rabbitmq / seaweedfs | 單一 `/etc/haproxy/haproxy.cfg` 只剩一種面孔，輸方的 VIP 分流整個消失 |
| `keepalived_instances` | kong / lb / postgres / rabbitmq / seaweedfs | 單一 list 不合併，輸方 VIP 從 keepalived.conf 消失 |
| `pki_certificates` | gitlab / kong / lb / postgres / rabbitmq / scylladb / seaweedfs / app_email_proxy | 輸方的憑證清單消失，服務起不來（**最緊的約束：8 個群組都定義它**） |
| `storage_volumes` | gitlab / monitoring / nfs / postgres / rabbitmq / scylladb / seaweedfs | 輸方的資料碟掛載宣告消失，資料落 OS 碟 |

repo 內建的三對同居（lb+egress、postgres+etcd、app+keydb）全靠
「相撞變數只由一邊持有」才成立。結論：**不重構變數，3 台機器
最多同時承載 1 個 pki 定義群組 + 若干無相撞變數的群組**。

### 1.2 Ubuntu 24 的套件現實

這套 repo 的鐵律是「不加第三方 apt repo」，systemd 原生服務全部用
**Ubuntu 26.04 官方 archive** 的版本：

| 組件 | 來源 | Ubuntu 24.04 實體機直跑？ |
|---|---|---|
| PostgreSQL **18** + Patroni | 26.04 archive（`roles/patroni/defaults` 檔頭） | ❌ noble archive 沒有 PG 18 |
| RabbitMQ **4.0.5** + Erlang 27 | 26.04 archive | ❌ noble 是 3.12 系 |
| etcd 3.5.16 / PgBouncer ≥1.21 | 26.04 archive | ⚠️ 版本較舊，未驗證 |
| ScyllaDB / SeaweedFS / Kong / KeyDB / 監控堆疊 | **Docker 映像（pin 版）** | ✅ 與宿主 OS 無關 |
| HAProxy / Keepalived / Squid / NFS / node_exporter | distro 套件（版本不敏感） | ✅ |
| GitLab CE / Runner | 上游 repo，`gitlab_apt_codename: noble` | ✅ 24.04 本來就是 noble |

**Docker lab 完全不受影響**——lab 容器映像是 `ubuntu:26.04`，宿主是
Ubuntu 24 沒關係，只要有 Docker。

### 1.3 兩條路線

| | 路線 A：Docker Lab 全鏈（主線） | 路線 B：實體機輪練（進階） |
|---|---|---|
| 用幾台 | 1 台（RAM ≥ 16GB 那台） | 3 台 |
| 拓撲 | **完整 21 節點、5 VLAN、VIP/TLS/quorum 全有**——與 prod 1:1 | 一次練 1 個組件（3 節點 quorum 可保留） |
| 學到什麼 | 全鏈依賴、每階段行為、failover 演練 | 真實 kernel/磁碟/網路行為（sysctl、block_storage、VRRP 真 L2） |
| Ubuntu 24 限制 | 無 | 30/31 階段需要 26.04（§1.2） |
| 已驗證程度 | 16 節點時代全鏈全綠；**2026-08 平台化（21 節點）後尚未重跑全鏈**，static 檢查全綠——你跑的時候踩到問題是預期中的，修好它就是貢獻 | 你是第一個 |

**建議：先 A 後 B。** 先在一台機器上用 Docker lab 把 00→99 走一遍、
搞懂每個階段（§4 + §5），再用三台實體機輪練你最關心的組件（§6）——
實體機上 `is_container=false`，你會看到 lab 跳過的 kernel 級行為
（sysctl、swapoff、block_storage 認碟）。

---

## 2. 給 MIS 的需求清單

把這一節直接轉給 MIS。

### 2.1 機器與 OS

| 項目 | 需求 | 理由 |
|---|---|---|
| OS | Ubuntu 24.04 可用；**若要練 PostgreSQL/RabbitMQ 原生部署，其中三台請裝 26.04** | §1.2 套件版本 |
| 規格 | 至少一台 **4 vCPU / 16GB RAM / 100GB+ 系統碟**（跑 Docker lab；21 容器約 10–11GB RAM）；其餘 2 台 4C/8G 起 | `ansible/lab/docker-compose.yml` 資源註記 |
| 資料碟（選配，路線 B 用） | 每台額外掛 1 顆裸碟（不分割、不格式化），**三台容量互異或與系統碟明顯不同**，例如 100G / 120G / 150G | `block_storage` 以「容量 ±12%」認碟，同機碟容量必須互異，否則 assert 拒跑 |
| 帳號 | 建一個 `ansible` 使用者：塞入我的 SSH 公鑰 + `sudoers NOPASSWD` | repo 的 `become_ask_pass=False`、sshd 強化會關密碼登入 |

### 2.2 網路開通

| 項目 | 需求 | 理由 |
|---|---|---|
| L2 | **三台在同一個 L2 網段**（同 VLAN、同廣播域） | VRRP 心跳（IP proto 112 單播）+ VIP 漂移靠 GARP 更新鄰居 ARP |
| 機器間防火牆 | 三台之間**全開**（或至少放行 §2.3 矩陣） | 東西向流量；平台 role 不管理主機防火牆（存取控制做在服務綁定與 NFS ACL） |
| 備用 IP | 同網段**至少 6 個未使用 IP** 給 VIP（服務/egress/kong/pgbouncer/rabbitmq/s3） | keepalived 掛 /32 VIP |
| 對外 | 三台可直連網際網路（NAT 即可），或給我可用的 HTTP proxy | apt / Docker Hub / GitHub release 下載；lab 模式 `use_egress_proxy=false` 直連 |
| DNS | 不需要 | 名稱解析由 Ansible 管 `/etc/hosts`（ADR-5） |
| VRRP 注意 | 若網段上有其他設備也在跑 VRRP，告知已使用的 vrid | 平台用 vrid 10/12/20/30/31/40，同 L2 不可重複 |

### 2.3 東西向埠矩陣（節選；完整見 README §4.3）

三台互通全開就不用管這張表；若 MIS 堅持最小開放，核心項：

| 流向 | Port | 用途 |
|---|---|---|
| client → 服務 VIP | 443, 465 | 對外入口 |
| 節點互相 | 22 | Ansible |
| pg ↔ pg | 5432, 8008, 2379/2380 | 複寫 + Patroni REST + etcd |
| mq ↔ mq | 25672, 4369 | Erlang 叢集 |
| scylla ↔ scylla | 7001 | internode mTLS（明文 7000 不監聽） |
| sw ↔ sw | 9333/19333, 8380/18380, 8888/18888 | master raft / volume / filer |
| app/pg → nfs | 2049 | NFSv4.1 唯一埠（免 rpcbind） |
| app → VIP | 6432/6433, 5671, 8443, 8333 | PG / MQ / Kong / S3 |
| mgmt → 全部 | 9100, 8008, 8404, 9180, 15692, 8100, 9327, 2381, 9121 | Prometheus 抓取 |
| 節點互相 | VRRP（IP protocol 112） | keepalived 單播心跳 |

---

## 3. 控制節點準備

### 3.1 路線 A（Docker lab）：只需要 Docker

lab 的 `ansible-playbook` 全部在 `platform-mgmt-01` 容器**裡面**執行
（repo bind mount 到 `/work`），宿主機完全不需要裝 Ansible：

```bash
# 在 RAM 最大那台（假設 lab-host）
sudo apt-get update && sudo apt-get install -y git make docker.io docker-compose-v2
sudo usermod -aG docker $USER   # 重登生效
git clone <repo-url> onpremis_gitops && cd onpremis_gitops
```

### 3.2 路線 B（實體機）：venv 裝 Ansible 工具鏈

24.04 archive 的 ansible-core 偏舊，用 venv 裝新版（repo 慣例）：

```bash
sudo apt-get install -y python3-venv git make
python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install ansible-core ansible-lint yamllint
cd onpremis_gitops
make deps BIN=~/ansible-venv/bin/          # ansible-galaxy 裝 6 個 collections 到 ansible/collections/
make lint BIN=~/ansible-venv/bin/          # 確認工具鏈可用（production profile）
```

Makefile 所有 ansible 指令都吃 `BIN=` 前綴；之後手打 `ansible-playbook`
時記得用 `~/ansible-venv/bin/ansible-playbook`（或把 venv 加進 PATH）。

### 3.3 vault：接手的第一件事

lab inventory 用 repo 內建的 lab 鑰匙（佔位機密），**開箱即用、不用動**。
只有要打 prod（或你自建的 mislab 若選用 prod 鑰匙）才需要：

```bash
cd ansible
openssl rand -base64 24 > .vault_pass && chmod 600 .vault_pass      # 產新鑰匙（不進 Git）
ansible-vault rekey --new-vault-id prod@.vault_pass inventories/prod/group_vars/all/vault.yml
ansible-vault edit  inventories/prod/group_vars/all/vault.yml       # 逐項換掉 CHANGEME
# 專案機密同理：vault_prj_email_proxy.yml；範本見 *.example
```

注意 example 檔的兩條規則：VRRP 密碼**正好 8 字元**（協定截斷）、
Scylla 密碼**避免引號、建議純英數**（cqlsh 指令引號結構）。

---

## 4. 路線 A：Docker Lab 全鏈實戰（主線）

### 4.1 四個 make 指令做了什麼

```bash
make lab-build    # 產 SSH 金鑰（lab/.ssh/id_lab）+ build 基底/controller 映像（ubuntu:26.04 + systemd）
make lab-up       # docker compose up 21 個容器（5 個 bridge = 5 個 VLAN、IP 與 prod 完全相同）
                  # + lab-wait-ready.sh：等 systemd 就緒 → ssh-keyscan 收指紋 → ansible ping 全通
make lab-deploy   # 在 mgmt-01 容器內跑 site.yml（約 20–25 分鐘）
make lab-verify   # 只跑 99-verify 全鏈驗收
```

其他：`make lab-sh` 進 mgmt-01、`make lab-destroy` 銷毀（含 volume）。
容器版拓撲 = prod 拓撲 1:1（TLS/quorum/VIP 一個不少），只降資源規格
（`zz_lab_overrides.yml`）；gitlab/runner 群組留空不部署。

### 4.2 教學主線：不要一鍵，分階段跑

`lab-deploy` 是一鍵全站。**學習時改用分階段**——進 mgmt-01，
一次跑一個 playbook，跑完就用 §5 對應階段的驗證指令觀察它：

```bash
make lab-up && make lab-sh          # 進 platform-mgmt-01，已在 /work/ansible
# 以下全部在容器內執行；lab 一律要明打 -i（預設是 prod，防呆設計）
ansible-playbook -i inventories/lab/hosts.yml playbooks/00-bootstrap.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/05-block-storage.yml   # lab 是空操作（容器無裸碟）
ansible-playbook -i inventories/lab/hosts.yml playbooks/08-docker.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/10-pki.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/20-storage.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/30-postgres.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/31-rabbitmq.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/32-keydb.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/33-scylladb.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/34-seaweedfs.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/35-kong.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/40-lb.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/41-egress.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/50-apps.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/60-monitoring.yml
ansible-playbook -i inventories/lab/hosts.yml playbooks/99-verify.yml
```

每個階段跑完，做三件事：

1. 跑該階段的 **99-verify 單一 tag**（例 `--tags verify-pg`）。
2. 挑 §5 該階段的 2–3 條手動驗證指令，親手看服務狀態。
3. **重跑同一個 playbook 一次**——預期 `changed=0`（冪等是這個 repo 的
   硬規格；不是 0 就值得追）。

### 4.3 必做練習

```bash
# 練習 1：Patroni failover 演練（宿主機執行）
docker stop platform-pg-01                # 模擬 leader 整機死亡
make lab-verify                           # ~40 秒內新 leader 上任、全鏈仍綠
docker start platform-pg-01               # 舊 leader pg_rewind 後以 replica 回歸

# 練習 2：VIP 漂移（mgmt-01 內）
ansible -i inventories/lab/hosts.yml lb-01 -m ansible.builtin.systemd_service -a 'name=haproxy state=stopped'
ansible -i inventories/lab/hosts.yml lb   -m ansible.builtin.command -a 'ip -4 addr show'
#   → 4–7 秒內 10.20.10.10/32 應出現在 lb-02；egress VIP .20 留在 lb-01（Squid 沒死）
ansible -i inventories/lab/hosts.yml lb-01 -m ansible.builtin.systemd_service -a 'name=haproxy state=started'

# 練習 3：憑證輪替全流程
ansible-playbook -i inventories/lab/hosts.yml playbooks/10-pki.yml -e pki_leaf_force_renew=true
ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml    # 各服務靠 pki_certs_changed 自動 reload
ansible-playbook -i inventories/lab/hosts.yml playbooks/99-verify.yml --tags verify-pki
```

### 4.4 資源不夠 / 已知狀態

- RAM 吃緊：`docker compose stop scylla-01 scylla-02 scylla-03`（或 sw-0x）
  單獨關掉——空群組語意下 99-verify 對應段自動 skip。**不可只關 1–2 台
  quorum 成員**，要關就整組關。
- Makefile 註解仍寫「16 節點」，實際是 21 節點（歷史殘留）。
- **21 節點版尚未全鏈實測**（README §12 末尾警告）。踩到問題先查
  README §17 的 21 條踩雷實錄——特別是 Scylla 的 #18（`scylla_memory`
  與瞬時 MemFree）與 #19（`fs.aio-max-nr` 全 kernel 計數器）。

---

## 5. 逐階段部署手冊（00 → 99）

每階段固定格式：**目的 → 指令 → 網路/埠 → 注意 → 驗證**。
指令以 prod/實體機寫法為準（在 `ansible/` 目錄執行、免 `-i`）；
打 lab 一律自行補 `-i inventories/lab/hosts.yml`。

### 5.0 先背這張表：serial 語意速查（最重要的一張表）

「首次成形」與「已運行變更」的並行語意**不同**，搞反會卡死或全斷：

| 服務 | 首次成形 | 已運行後的計畫性變更（改設定/換憑證） |
|---|---|---|
| etcd | **三台同時**（serial:1 會等 quorum 卡死） | `--limit` 逐台，等健康再下一台 |
| Patroni | 三台同時（role 內建等待條件排序，首任 leader 必為 pg-01） | `--limit` 逐台；動 leader 前先 `patronictl switchover` |
| RabbitMQ | **三台同時**（4.x peer discovery 互相協商；單獨先起會卡滿 10 分鐘被 systemd 砍） | `--limit` 逐台（quorum queue 容忍單節點離線） |
| ScyllaDB | 三台同時（Raft 自動序列化加入） | `--limit` 逐台 + 每台之間 `nodetool status` 全 UN 才動下一台 |
| SeaweedFS | **三台同時**（master raft 選主） | `--limit` 逐台 + 確認 `/cluster/status` Leader 存在 |
| KeyDB | 全起 + run_once `--cluster create` | `--limit` 逐台（handler 是 recreate，三台同動 = 快取層全滅） |
| HAProxy / Keepalived / Kong / compose 應用 | playbook 內建 `serial: 1` | 同左（**切勿改成全平行**） |

> 為什麼重跑全群組危險：這些 role 的 handler 多半是 `recreate`/`restart`，
> 設定或憑證變更會讓**三台同時**重啟——quorum 短暫失守、服務全斷。
> 所以：**首跑放心全並行；之後的變更一律 `--limit` 逐台滾動。**

---

### 階段 00 + 05 + 08：系統基線、資料碟、Docker

**目的**：00 對 *全部主機* 收斂基線（時區/chrony/`/etc/hosts`/proxy/
sysctl/swapoff/limits/journald/sshd 強化）；05 把裸資料碟格式化成 XFS
掛到服務目錄（**必須在服務安裝前**，否則碟掛上去會遮蔽已寫入 OS 碟的
資料）；08 只在跑容器的主機裝 Docker（08 排 05 之後：mgmt 的
`/var/lib/docker` 要先掛上大碟）。

```bash
cd ansible
ansible-playbook playbooks/site.yml --tags bootstrap        # 三個階段一次跑完（00/05/08 都掛 bootstrap tag）
# 或分開跑：
ansible-playbook playbooks/00-bootstrap.yml
ansible-playbook playbooks/05-block-storage.yml
ansible-playbook playbooks/08-docker.yml
```

**網路/埠**：不開任何監聽埠。`use_egress_proxy=true` 時 apt/dockerd/get_url
全部走 `egress-proxy:3128`。

**注意**
- **雞生蛋**：prod 首跑時 Squid（41 階段）還不存在，而 00 已把 apt 指向
  proxy → 首次全新部署用 `-e use_egress_proxy=false`，等 41 跑完再重跑 00
  收斂 proxy 設定。lab 直連 NAT 天然無此問題（overrides 已設 false）。
- `/etc/hosts` 由 Ansible 接管一個 blockinfile 區塊（ADR-5）：全 inventory
  主機名 + VIP 別名。手改必被覆蓋；接公司 DNS 時關 `manage_etc_hosts`。
- `block_storage` **用容量認碟**（±12% 容差）：裸碟認出 0 顆或多顆同容量
  → assert 直接失敗，這是資料安全底線不是 bug。fstab 用 UUID、
  filesystem 不帶 force（碟上已有 FS 絕不誤抹）。
- 三個 role 都不管防火牆（ufw/iptables 一概不碰）。
- `is_container=true`（lab）跳過：chrony 啟動、sysctl、swapoff、整個
  block_storage。

**驗證**
```bash
ansible all -m ansible.builtin.command -a 'timedatectl show -p Timezone --value'   # Asia/Taipei
ansible all -m ansible.builtin.command -a 'swapon --noheadings --show=NAME'        # 空輸出
ansible postgres -m ansible.builtin.command -a 'findmnt -no SOURCE,FSTYPE /var/lib/etcd'   # UUID=... xfs
ansible 'compose_apps:scylladb:seaweedfs:kong:monitoring:gitlab_runner' -m ansible.builtin.command -a 'systemctl is-active docker'
ssh mgmt-01 'docker run --rm hello-world'    # 端到端驗證出網路徑
```

---

### 階段 10：單一信任根 PKI

**目的**：兩層 CA（Root 20 年 → Issuing 5 年，都在 mgmt-01 生成）→
為每台主機簽 397 天葉憑證。之後**所有** TLS 服務的憑證都出自這裡。
安全模型：**私鑰在目標主機本地生成、永不離開**；controller 只經手
CSR 與簽好的憑證。

```bash
ansible-playbook playbooks/10-pki.yml
ansible-playbook playbooks/10-pki.yml --tags leaf --limit pg-01     # 只重簽單機
ansible-playbook playbooks/10-pki.yml -e pki_leaf_force_renew=true  # 季度輪替：強制重簽全部葉憑證
```

**注意**
- 每個群組要簽哪些憑證由 `group_vars/<group>.yml` 的 `pki_certificates`
  宣告（CONVENTIONS §5 對照表）。
- 憑證先以 root:root 落地（服務帳號還不存在），之後各服務 role 自己 chown。
- **輪替後必接著跑 site.yml**：`pki_certs_changed` fact → 服務 reload 的
  橋接只在「同一次執行」生效，只跑 10-pki 收工 = 服務抱著舊憑證。
- Root 私鑰首建後應 gpg 加密備份兩支 USB、驗證可還原後 `shred -u` 離線
  （role 註解有 runbook）；之後重跑會自動跳過 Root 層，這是日常狀態。
- 重跑 = `changed=0`（有效憑證不重簽）。

**驗證**
```bash
ssh mgmt-01 'sudo openssl verify -CAfile /opt/platform-ca/root-ca.crt /opt/platform-ca/issuing-ca.crt'   # OK
ansible pg-01 -m ansible.builtin.command -a 'openssl verify /etc/platform/pki/etcd.crt'                  # 系統信任庫已收錄 → OK
ansible pg-01 -m ansible.builtin.command -a 'openssl x509 -in /etc/platform/pki/etcd.crt -noout -ext subjectAltName'
ansible-playbook playbooks/99-verify.yml --tags verify-pki          # 全站葉憑證 30 天效期掃描
```

---

### 階段 20：NFS 儲存層

**目的**：nfs-01 部署 **NFSv4.1-only**（單一埠 2049，免 rpcbind）；
app 節點掛共享附件、pg 節點掛 pgBackRest 備份庫。exports 從 `projects`
登記簿推導，不寫死專案。

```bash
ansible-playbook playbooks/20-storage.yml
ansible-playbook playbooks/20-storage.yml --tags nfs-server   # 或 nfs-client
```

**網路/埠**：2049/tcp（nfs-01）。存取控制 = exports 的 clients 網段 ACL
（「儲存層的防火牆第一道」）。

**注意**
- 容器 lab 限定：宿主機先 `sudo modprobe nfsd`（kernel module 共用宿主）。
- 權限模型：`all_squash` + 數字 `anonuid/anongid=1000`——NFS 只看數字
  UID，兩邊建同名帳號但 UID 不同是最經典的地雷。
- 葉匯出有 self bind-mount、pseudo-root 顯式 `fsid=0`（overlayfs/選項
  繼承兩個實測雷，role 已處理，別「清理」它們）。
- client 是 `hard` mount：伺服器失聯 IO 會阻塞等待而非回傳壞資料——
  這是資料安全特性。

**驗證**
```bash
ansible nfs -m ansible.builtin.command -a 'exportfs -v'                      # /export(fsid=0) + 兩個資料匯出
ansible nfs -m ansible.builtin.command -a 'cat /proc/fs/nfsd/versions'      # -3 +4.1（v4-only 生效）
ansible compose_apps -m ansible.builtin.command -a 'mountpoint /mnt/attachments'
ansible-playbook playbooks/99-verify.yml --tags verify-nfs   # app-01 寫、其餘節點讀（使用者視角行為）
```

---

### 階段 30：PostgreSQL HA 資料層（一台 pg 節點五個角色）

**目的**：etcd×3（Patroni 的 DCS）→ Patroni/PG18（同步複寫 RPO=0）→
PgBouncer（transaction pooling）→ pgBackRest（WAL 歸檔 + 每日 full/diff
備份、zstd 壓縮、至少保留 7 天到 NFS）→ 本地 HAProxy+Keepalived 提供 `pgbouncer-vip` 的 RW(6432)/RO(6433)
分流。app 一律走 VIP，絕不直連 5432。

```bash
ansible-playbook playbooks/30-postgres.yml                   # 全套（首跑：三台同時，不要 --limit）
ansible-playbook playbooks/30-postgres.yml --tags etcd       # 分層跑：etcd / patroni / pgbouncer / backup / pg-lb
ansible-playbook playbooks/99-verify.yml --tags verify-etcd,verify-pg,verify-pgbouncer,verify-pg-ext,verify-pgbackrest
```

**網路/埠**：2379/2380（etcd, mTLS）、2381（etcd metrics 明文）、
8008（Patroni REST）、5432（PG，僅節點+loopback）、6432（PgBouncer，
節點 IP）、VIP:6432/6433（HAProxy）、8404（stats）、VRRP vrid 30。
**埠共存原則**：PgBouncer 綁節點 IP、HAProxy 綁 VIP、同埠不相撞，
靠全站 `net.ipv4.ip_nonlocal_bind=1`。

**注意**
- **首跑不可 serial**（§5.0）；已運行叢集的變更 `--limit` 逐台，leader
  那台先 `patronictl switchover --candidate pg-0x --force` 再動。
- **設定的兩層真相**：`bootstrap.dcs` 區塊只在第一次 initdb 寫入 etcd，
  之後改檔案無效——改叢集參數用 `patronictl edit-config`。role 刻意
  **沒有 restart handler**（leader restart = failover），只有 reload。
- **不可逆變更**：`pg_cluster_scope`（改 = 全新叢集）、`pgbackrest_stanza`
  （改 = 備份鏈斷代）。
- `archive_command` 在 stanza 建好前會失敗、WAL 暫積——**預期行為**，
  stanza-create 後自動追上。
- 首次部署尾聲會自動做第一次全備；之後每日 01:30 timer，備份腳本
  執行當下自判 leader（failover 後零維運）。週日是 full、其餘日是 diff；
  repo 使用 zstd level 3，時間型 retention 至少保留 7 天。

**驗證**
```bash
ansible pg-01 -m ansible.builtin.command -a "sudo -u postgres patronictl -c /etc/patroni/config.yml list"
curl -s http://10.20.30.11:8008/cluster | python3 -m json.tool        # 恰 1 leader + 2 streaming
# RW/RO 分流（用某租戶 db 帳密；RW 應回 f、RO 應回 t）
PGPASSWORD=<pw> psql "host=10.20.30.10 port=6432 dbname=<db> user=<user> sslmode=verify-full sslrootcert=/etc/platform/pki/ca.crt" -tAc 'SELECT pg_is_in_recovery()'
ansible pg-01 -m ansible.builtin.command -a 'sudo -u postgres pgbackrest --stanza=pg-main info'   # 至少 1 份 full
ansible pg-01 -m ansible.builtin.command -a 'systemctl list-timers pgbackrest-backup.timer --no-pager'
ansible pg-01 -b -m ansible.builtin.command -a "grep -E '^(compress-type|compress-level|repo1-retention-full-type|repo1-retention-full)=' /etc/pgbackrest/pgbackrest.conf"
# 手動觸發一次（只會由當下 leader 執行，replica 會正常 skip）
ansible pg-01 -b -m ansible.builtin.systemd_service -a 'name=pgbackrest-backup.service state=started'
ansible pg-01 -b -m ansible.builtin.command -a 'journalctl -u pgbackrest-backup.service -n 80 --no-pager'
# HAProxy 語意：http://10.20.30.11:8404/stats → pg_rw 恰 1 台 UP；pg_ro 中 leader 顯示 DOWN 是「設計」不是故障
```

---

### 階段 31：RabbitMQ 佇列層

**目的**：mq×3 的 RabbitMQ 4.x 叢集（AMQPS-only、quorum queue），
依 `projects` 冪等建立各租戶 vhost/user/DLX/佇列；第二個 play 以
serial:1 佈 HAProxy+Keepalived（VIP:5671）。

```bash
ansible-playbook playbooks/31-rabbitmq.yml            # 首跑三台同時
ansible-playbook playbooks/31-rabbitmq.yml --tags mq-lb
ansible-playbook playbooks/99-verify.yml --tags verify-mq
```

**網路/埠**：5671（AMQPS，節點 IP）、明文 5672 **整個關閉**、
15672（管理 UI）、25672/4369（叢集內部）、15692（metrics）、VRRP vrid 31。

**注意**
- **首跑鐵律**：4.x virgin 節點要同時起來互相協商 seed；單獨先起會
  無限重試（防裂腦）直到 systemd 逾時砍掉——實驗室實測卡滿 10 分鐘。
- **erlang cookie 必須先於首次啟動落地**：role 用 policy-rc.d 擋住 apt
  自啟。若部署中途失敗，policy-rc.d 可能殘留擋住本機其他服務——重跑
  playbook 會自動清除。
- cookie = 叢集 root 權限（同 cookie 可互相執行任意 Erlang 呼叫），
  0400 + no_log。
- listener 綁節點 IP 不綁 wildcard（HAProxy 要綁 VIP:5671 同埠）。

**驗證**
```bash
ansible mq-01 -m ansible.builtin.command -a 'rabbitmqctl cluster_status --formatter json'   # running_nodes == 3
ansible mq-01 -m ansible.builtin.command -a 'rabbitmqctl list_queues -p <vhost> name type --formatter json'  # 全是 quorum
# 99-verify 會真的 publish + get 一則訊息（自我清理），比看服務狀態可信
```

---

### 階段 32：KeyDB 快取層

**目的**：app-01..03 各跑 1 master + 1 replica 容器（host network、
TLS-only + mTLS + requirepass），`--cluster-replicas 1` 的 anti-affinity
保證 replica 不與自己的 master 同機（3M+3R 跨機備援）。KeyDB 是
email_proxy 的**私有**快取，不是共用服務（CONVENTIONS §10.6）。

```bash
ansible-playbook playbooks/32-keydb.yml
ansible-playbook playbooks/99-verify.yml --tags verify-keydb
```

**網路/埠**：6379（master）/6380（replica），cluster bus = +10000；
明文 `port 0` 全關。

**注意**
- handler 是 **recreate 不是 restart**（conf/tls 是掛載檔，compose 偵測
  不到內容變更）且會同時重建本機 master+replica——已運行後的變更
  **務必 `--limit app-0x` 逐台**，三台同動 = 快取層瞬間全滅。
- 映像內建 UID **999**：conf/tls/data 擁有者都要 999（exporter 也要降權
  999，否則讀不到 0640 的 client key——實測雷 #17）。
- `cluster-announce-ip` 必設：host network 多網卡下不宣告會 gossip 錯 IP。

**驗證**
```bash
ansible app-01 -m ansible.builtin.shell -a "docker exec keydb-master keydb-cli --tls --cacert /tls/ca.crt --cert /tls/keydb-client.crt --key /tls/keydb-client.key -a '<keydb_password>' --no-auth-warning cluster info | grep -E 'cluster_state|known_nodes'"
# → cluster_state:ok、cluster_known_nodes:6；99-verify 另做跨節點 set/get
```

---

### 階段 33：ScyllaDB 寬欄資料層

**目的**：scylla×3（Docker、pin `scylladb/scylla:2026.1.1`、host network、
internode mTLS + CQL TLS、NTS RF=3）。拓撲承襲 MIS 的 setuc2 叢集並修正
其反模式（`:latest`、developer mode 上 prod、`rpc_address: 0.0.0.0`、
出廠帳號未刪、aio-max-nr 過低）。

```bash
ansible-playbook playbooks/33-scylladb.yml            # 首跑三台同時；首啟含磁碟 IO 基準測試（1–2 分鐘）
ansible-playbook playbooks/99-verify.yml --tags verify-scylladb
# 已運行叢集的變更：逐台 + 每台之間確認全 UN
ansible-playbook playbooks/33-scylladb.yml --limit scylla-01
ansible scylla-01 -m ansible.builtin.command -a 'docker exec scylladb nodetool status'   # 3 行 UN 後才動下一台
```

**網路/埠**：9042（CQL TLS，節點 IP）、7001（internode mTLS；明文
7000 不監聽）、10000（REST API **僅 127.0.0.1**——無認證）、9180
（原生 metrics）。

**注意**
- **首次部署放在維護窗**：叢集成形到 DROP 出廠 `cassandra` 帳號之間
  有數分鐘窗口（含 IO 基準可到 ~10 分鐘），出廠帳密可從 VLAN 登入。
  部署尾聲的角色審計會抓窗口內被植入的持久角色。
- `fs.aio-max-nr` 是**全 kernel 單一計數器**，是唯一「容器也要設」的
  sysctl（實測雷 #19）；lab 另有 `scylla_memory=400M`（Seastar 看瞬時
  MemFree，實測雷 #18）與 developer mode——**這三個 lab 覆寫絕不帶回 prod**。
- 密碼純英數（cqlsh 指令是 shlex 解析，引號會壞）。
- `scylla_admin` 自己的密碼輪替**沒有自動路徑**：先用舊密碼手動
  `ALTER ROLE` 再改 vault（順序反了 play 會中止）。
- DC/rack/cluster_name 是出生證明，首次加入後不可改；cluster_name 沿用
  `setuc2` 是刻意的（保留日後加 DC 線上遷移選項）。

**驗證**
```bash
ansible scylla-01 -m ansible.builtin.command -a 'docker exec scylladb nodetool status'        # 恰 3 行 UN
ansible scylladb -m ansible.builtin.command -a 'sysctl fs.aio-max-nr'                          # 1048576
ansible scylla-01 -m ansible.builtin.command -a 'ss -tln'   # 節點IP:9042/7001/9180、127.0.0.1:10000；無 0.0.0.0:9042、無 7000
# 出廠帳號必須登入失敗：
ansible scylla-01 -m ansible.builtin.command -a "docker exec -e SSL_CERTFILE=/etc/scylla/certs/ca.crt scylladb cqlsh 10.20.30.31 9042 --ssl -u cassandra -p cassandra -e 'SELECT now() FROM system.local'"
```

---

### 階段 34：SeaweedFS S3 物件儲存層

**目的**：sw×3 各跑一個 `weed server` all-in-one 容器（master raft +
volume + filer + S3），filer 元資料存 Patroni PG（**依賴 30 階段**，
「組件依賴組件」第一例）；HAProxy+Keepalived 提供 S3 VIP:8333
（TCP passthrough，TLS 由 weed 自持）。

```bash
ansible-playbook playbooks/34-seaweedfs.yml           # 首跑三台同時（raft 選主）
ansible-playbook playbooks/99-verify.yml --tags verify-seaweedfs
```

**網路/埠**：8333（S3 TLS，唯一契約口）、9333/19333（master）、
8380/18380（volume；上游預設 8080 撞 app 契約故改）、8888/18888
（filer）、9327（metrics）、VRRP vrid 40。master/volume/filer 走
VLAN 內部明文（防火牆隔離的刻意取捨）。

**注意**
- **先跑 30**：`database=seaweedfs` 不存在 filer 起不來。
- 三台同時 recreate = S3 全斷 + raft quorum 失守——變更一律 `--limit`
  逐台 + 確認 `/cluster/status` 的 Leader 存在再動下一台。
- `replication=010` = 每物件跨節點 2 副本（可用容量 = 原始 ÷ 2）；
  每節點自成一個 rack（`-rack=主機名`）是它能保證「跨節點」的前提。
- **架構鐵律**：S3 只能當 pgBackRest 的次要 repo2，PG 還原主路徑必須
  是 NFS repo1——否則循環依賴（還原 PG 要讀 S3、讀 S3 要 PG）。
- S3 客戶端用 path-style（/etc/hosts 做不了 wildcard 解析）。

**驗證**
```bash
curl -s http://10.20.40.21:9333/cluster/status | python3 -m json.tool    # Leader 非空、三成員到齊
# S3 端到端（curl 8.x 內建 SigV4，免裝 awscli）：
curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/platform/pki/ca.crt \
  --aws-sigv4 'aws:amz:on-prem:s3' --user "$AK:$SK" -X PUT https://s3.ptc-nec.com.tw:8333/verify-bucket   # 200 或 409
openssl s_client -connect 10.20.40.10:8333 -CAfile /etc/platform/pki/ca.crt </dev/null 2>/dev/null | grep Verification   # OK
```

---

### 階段 35：Kong API Gateway

**目的**：kong×2（DB-less、Docker）。北向：邊界 HAProxy 443 → kong:8000
（明文，TLS 已在邊界終止）；東西向：`https://kong-vip:8443`（Kong 自持
憑證 + keepalived VI_KONG）。DB-less = 路由真值在 Git 的 `projects`
宣告，改路由 = PR → 重跑 → `kong reload` 熱換零斷線。

```bash
ansible-playbook playbooks/35-kong.yml                # 內建 serial: 1
ansible-playbook playbooks/99-verify.yml --tags verify-kong
```

**網路/埠**：8000（proxy HTTP）、8443（proxy TLS：節點 IP + **VIP**
+ loopback）、8001（admin **僅 127.0.0.1**，DB-less 下唯讀）、8100
（/status 健檢 + /metrics）、VRRP vrid 20。

**注意**
- Kong 是全站唯一「服務本體直接綁 VIP」的組件 → `ip_nonlocal_bind=1`
  是硬前提（BACKUP 節點沒有它會永久 crash-loop）。
- 宣告檔有「先 parse 再上線」閘門（staged → `kong config parse` →
  正式檔），壞設定到不了正式路徑。
- reload vs restart 分工：kong.yml/憑證 → reload（零斷線）；
  compose/env → recreate（reload 讀不到新 env）。
- host network 容器**不吃宿主 /etc/hosts**：upstream targets 一律渲染
  成節點 IP。
- oauth2 plugin 不支援 DB-less（JWT/key-auth/ACL/CORS/rate-limiting 都支援）。

**驗證**
```bash
ssh kong-01 'curl -fsS http://127.0.0.1:8100/status'                          # 200；DB-less = 回應無 database 欄位
ssh kong-01 'curl -s -m 3 http://10.20.20.21:8001/ ; echo exit=$?'            # 必須連不上（負向斷言）
curl -s -o /dev/null -w '%{http_code}' --cacert /etc/platform/pki/ca.crt https://kong-vip.ptc-nec.com.tw:8443/   # 404 = TLS+路由引擎正常
```

---

### 階段 40 + 41：邊界 LB 與 Egress

**目的**：lb×2 是唯一南北向入口（443 TLS 終止 / 465 passthrough，
frontends 從 projects 組裝）與唯一合法出網通道（Squid 顯式白名單，
預設拒絕 + CONNECT 只准 443）。VIP：服務 .10（VI_SVC vrid 10）、
egress .20（VI_EGRESS vrid 12）。

```bash
ansible-playbook playbooks/40-lb.yml       # serial: 1；必須先於 41（VI_EGRESS 定義在 lb.yml、由 40 套用）
ansible-playbook playbooks/41-egress.yml   # serial: 1
ansible-playbook playbooks/99-verify.yml --tags verify-edge,verify-egress
```

**注意**
- **41 不是自足的**：keepalived 一台主機一份設定檔，egress VIP 的
  instance 由 40 佈——只跑 41 會有 Squid 沒有 VIP。
- 一律 reload 不 restart（HAProxy expose-fd 零掉包；keepalived restart
  會先釋放 VIP 瞬斷；Squid reload 不斷既有 CONNECT）。
- 單播 VRRP（ADR-7）：`unicast_peer` 由群組展開——多播在交換器/雲網路
  常被擋、會腦裂成雙 MASTER。VRRP 密碼只取前 8 字元。
- keepalived 網卡自動偵測（找 IPv4 == ansible_host 的網卡）；bond/VLAN
  子介面偵測不準時在 host_vars 設 `keepalived_interface` 覆寫。
- 白名單語法：開頭帶 `.` = 含子網域；GitHub release 要 `github.com` +
  `.githubusercontent.com` 兩條（兩段式下載鏈，實測過）。

**驗證**
```bash
ansible lb -m ansible.builtin.command -a 'ip -4 addr show'    # MASTER 有 .10/32 與 .20/32；BACKUP 沒有（兩台都有=腦裂）
curl --cacert /etc/platform/pki/ca.crt https://svc-api.ptc-nec.com.tw/health -o /dev/null -w '%{http_code}\n'   # 200
# egress 白名單（注意被拒看 %{http_connect}，%{http_code} 會是 000）：
curl -sS -o /dev/null -w '%{http_connect}\n' -x http://egress-proxy.ptc-nec.com.tw:3128 https://www.example.com/   # 403
```

---

### 階段 50：各專案應用堆疊

**目的**：把 `projects` 登記簿中宣告 `compose_app` 段的每個專案，部署成
`/opt/<project>/{.env,docker-compose.yml}` 並以 host network 啟動。
role 不含任何專案名——全部宣告驅動。serial:1 + 兩道閘門
（wait_ports + /health 200）零停機滾動。

```bash
ansible-playbook playbooks/50-apps.yml
ansible-playbook playbooks/50-apps.yml -e app_image_tag=<git-sha>   # CI 部署慣例
```

**注意**
- **首次部署的雞生蛋**：prod 模式只 pull 不 build，但 registry（70 階段
  的 GitLab）此時可能還沒有映像——先把專案列入
  `compose_app_mock_projects` 走 mock 模式驗鏈路（lab 即此作法），
  GitLab+CI 就緒後再正式部署。
- `.env` 只在容器「建立」時讀 → handler 是 recreate；任一專案變更會
  recreate 本機**全部**專案（保守爆炸半徑）。
- `--check --diff` 看不到 `.env` 內容是刻意的（no_log 防機密上終端）。

**驗證**
```bash
ansible app_email_proxy -m ansible.builtin.uri -a 'url=http://127.0.0.1:8080/health status_code=200'
ansible lb-01 -m ansible.builtin.shell -a 'echo QUIT | timeout 5 nc 10.20.10.10 465 | head -1'   # 220 開頭
```

---

### 階段 60：可觀測性

**目的**：全主機 node_exporter + mgmt-01 的 Prometheus/Grafana/
Alertmanager/Blackbox（compose）。抓取清單**由 inventory 展開**
（static_configs），機器增減 = 改 hosts.yml 重跑 `--tags prometheus`；
blackbox 探測從 projects 展開。

```bash
ansible-playbook playbooks/60-monitoring.yml
ansible-playbook playbooks/99-verify.yml --tags verify-monitoring
```

**注意**
- 資料層 metrics 端點沒就緒也能部署（target 顯示 down，等該層上線轉綠）。
- 剛部署完**所有 target 短暫 down 是暖機**（首輪抓取未完成），99-verify
  已用輪詢處理（實測雷 #21）。
- Grafana admin 密碼只在 volume **首次初始化**時生效；之後改密碼要
  `grafana-cli admin reset-admin-password`。
- Alertmanager 目前是空 receiver 佔位（P0 缺口：critical 告警沒人收得到，
  見 docs/PLATFORM-GAPS.md）。

**驗證**
```bash
ssh mgmt-01 'curl -s http://127.0.0.1:9090/-/ready'      # Prometheus Server is Ready.
ssh mgmt-01 "curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' | python3 -c 'import json,sys; ts=json.load(sys.stdin)[\"data\"][\"activeTargets\"]; print(sum(1 for t in ts if t[\"health\"]==\"up\"),\"/\",len(ts))'"
# 瀏覽 http://<mgmt-ip>:3000（admin / vault 的 grafana 密碼）與 :9090/targets
```

---

### 階段 70：GitLab DevOps 層（獨立階段）

**目的**：gitlab-01 裝 GitLab CE Omnibus（HTTPS 443 + Registry 5050，
內部 CA 憑證）、runner-01 裝 GitLab Runner（docker executor）。
只依賴 00/10；lab 不部署（群組留空，8GB 記憶體塞不下）。

```bash
ansible-playbook playbooks/70-gitlab.yml               # 首次 reconfigure 最長等 10 分鐘
# Runner 註冊是兩步：GitLab UI（Admin → CI/CD → Runners）拿 glrt- token 後：
ansible-playbook playbooks/70-gitlab.yml --tags runner -e gitlab_runner_registration_token=glrt-xxxx
```

**注意**
- 憑證必須**先於**裝 gitlab-ce 落地（https external_url 首次 reconfigure
  立刻要憑證）。
- root 密碼只在首次安裝生效（之後 apt no-op）。
- `gitlab_apt_codename: noble`——上游對最新 LTS 支援較晚；在 Ubuntu 24.04
  上這本來就是原生 codename。
- Runner 註冊冪等（已註冊自動跳過）；重複 register 會在 GitLab 端堆殭屍。

**驗證**
```bash
curl -s https://gitlab.ptc-nec.com.tw/-/readiness       # 200（來源 IP 要在 monitoring_whitelist）
ssh gitlab-01 'sudo gitlab-ctl status'                  # 全部 run:
ssh runner-01 'sudo systemctl is-active gitlab-runner'
```

---

### 階段 99：全鏈驗收

**目的**：驗「使用者視角的行為」不是「程序活著」——NFS 驗 A 寫 B 讀、
MQ 真的 publish+get、S3 經 VIP 上傳從另一節點讀回、Scylla 用租戶帳號
QUORUM 跨節點讀寫。全部唯讀或自我清理，**隨時可重複執行**。

```bash
ansible-playbook playbooks/99-verify.yml               # 全鏈
ansible-playbook playbooks/99-verify.yml --tags verify-pg        # 單一子系統
# tags 全集：verify-etcd / verify-pg / verify-pgbouncer / verify-pg-ext / verify-mq / verify-keydb /
#           verify-scylladb / verify-seaweedfs / verify-kong / verify-nfs / verify-edge /
#           verify-egress / verify-monitoring / verify-pki
```

**注意**：空群組的 play 自動 skip；零專案宣告 = 租戶迴圈 0 次（不是失敗）。
帶密碼的檢查全掛 no_log，失敗時只有 label——除錯要自己手打等效 CLI
（§5 各階段的驗證指令就是等效版）。

---

## 6. 路線 B：三台實體機「一次一個組件」輪練

### 6.1 設計原則

1. **自建 `inventories/mislab/`**，永遠宣告全部群組、只填要練的組件
   （組件選單語意）。**不動 prod/lab 兩套 inventory。**
2. **一台實體機可以有多個 inventory 身分**：machine-1 同時是 `mgmt-01`
   （monitoring 群組、控制節點）與 `pg-01`（postgres 群組）——兩個
   inventory 主機指向同一台機器。因為相撞變數是跟著 *inventory 主機*
   合併的，雙身分**完全避開 §1.1 的變數相撞**。這比「把 mgmt-01 加進
   postgres 群組」乾淨得多。
3. **一次只開一個「pki 定義群組」**（§1.1 表）：練完一個組件、清乾淨
   （或請 MIS 重灌快照）再換下一個。
4. 拓撲不降規：quorum 組件永遠 3 節點（machine-1..3），這正是 3 台機器
   的價值。

### 6.2 mislab inventory 骨架（以 postgres 輪為例）

假設 MIS 給的三台機器 IP 是 `192.168.50.11/12/13`，同網段備用 IP
`192.168.50.20-25` 給 VIP。

```
ansible/inventories/mislab/
├── hosts.yml                       # 全部群組都宣告；本輪只填 monitoring + postgres/etcd
├── host_vars/
│   ├── pg-01.yml  pg-02.yml  pg-03.yml
│   └── mgmt-01.yml
└── group_vars/
    ├── <group>.yml → ../../prod/group_vars/<group>.yml     # 全部 symlink（單一事實來源，做法同 lab）
    └── all/
        ├── vars.yml / projects.yml / project_email_proxy.yml → ../../../prod/group_vars/all/ 同名檔
        ├── vault.yml / vault_prj_email_proxy.yml → ../../../lab/group_vars/all/ 同名檔（沿用 lab 鑰匙與佔位機密）
        └── zz_mislab_overrides.yml                          # 字母序最後 → 覆寫生效
```

`hosts.yml`：

```yaml
all:
  vars:
    ansible_user: ansible
    ansible_ssh_private_key_file: ~/.ssh/id_mislab
  children:
    lb: {hosts: {}}
    egress: {hosts: {}}
    kong: {hosts: {}}
    app_email_proxy: {hosts: {}}
    compose_apps:
      children:
        app_email_proxy:
    keydb: {hosts: {}}
    postgres:
      hosts:
        pg-01: {ansible_host: 192.168.50.11}
        pg-02: {ansible_host: 192.168.50.12}
        pg-03: {ansible_host: 192.168.50.13}
    etcd:
      hosts: {pg-01: {}, pg-02: {}, pg-03: {}}
    rabbitmq: {hosts: {}}
    scylladb: {hosts: {}}
    nfs: {hosts: {}}
    seaweedfs: {hosts: {}}
    gitlab: {hosts: {}}
    gitlab_runner: {hosts: {}}
    monitoring:
      hosts:
        mgmt-01:
          ansible_host: 192.168.50.11    # 與 pg-01 同一台實體機（雙身分）
          ansible_connection: local      # 控制節點就是它自己
```

`group_vars/all/zz_mislab_overrides.yml`（核心：把「環境事實」換成
MIS lab 的真實網路）：

```yaml
---
# ===== mislab 環境覆寫（做法同 zz_lab_overrides：只換環境事實，不降拓撲）=====
use_egress_proxy: false            # 直連 NAT；41 階段本輪不練
# VIP 全部換成 MIS 網段的備用 IP（用不到的照樣要有值——模板會求值）
service_vip:   192.168.50.20
egress_vip:    192.168.50.21
kong_vip:      192.168.50.22
pgbouncer_vip: 192.168.50.23
rabbitmq_vip:  192.168.50.24
s3_vip:        192.168.50.25
# 網段 ACL / pg_hba 的來源網段（原值是 10.20.x VLAN，必換否則 TLS/掛載/複寫全被拒）
vlan_app_cidr:     192.168.50.0/24
vlan_data_cidr:    192.168.50.0/24
vlan_storage_cidr: 192.168.50.0/24
internal_cidr:     192.168.50.0/24
```

`host_vars/pg-01.yml`（pg-02/03 同構，priority 遞減；keepalived 需要）：

```yaml
---
keepalived_state: MASTER          # pg-02/03 用 BACKUP
keepalived_priority: 150          # pg-02=120、pg-03=100
# 資料碟：依 MIS 實際掛的裸碟容量改；沒掛碟就整個留空 list 跳過 05 階段
storage_volumes: []
# 有碟的寫法（容量務必對到 lsblk 看到的實碟 ±12% 內）：
# storage_volumes:
#   - {name: disk1-pgdata, size_gb: 100, mountpoint: /var/lib/postgresql/18/main}
```

> host_vars 優先於 group_vars，所以 `storage_volumes` 在這裡覆寫
> 不會動到 symlink 的 prod group_vars——單一事實來源不破。

### 6.3 執行順序（postgres 輪，機器需 Ubuntu 26.04）

```bash
cd ansible
export INV='-i inventories/mislab/hosts.yml'
# 0) 指紋收錄（host_key_checking=True 是刻意的）
ssh-keyscan 192.168.50.11 192.168.50.12 192.168.50.13 >> ~/.ssh/known_hosts
ansible $INV all -m ansible.builtin.ping

# 1) 基線——machine-1 有雙身分（mgmt-01 + pg-01），為避免兩個身分同時 apt/改檔互撞，拆兩步：
ansible-playbook $INV playbooks/00-bootstrap.yml --limit mgmt-01
ansible-playbook $INV playbooks/00-bootstrap.yml --limit 'all:!mgmt-01'
ansible-playbook $INV playbooks/05-block-storage.yml      # storage_volumes 空 = 無動作
ansible-playbook $INV playbooks/08-docker.yml             # 本輪只有 mgmt-01（monitoring 群組）會裝

# 2) PKI → 3) PG 全套 → 4) 驗收
ansible-playbook $INV playbooks/10-pki.yml
ansible-playbook $INV playbooks/30-postgres.yml
ansible-playbook $INV playbooks/99-verify.yml --tags verify-etcd,verify-pg,verify-pgbouncer,verify-pgbackrest

# 5) 練維運（這才是實體機的價值）：
#    - 滾動變更：--limit pg-03 → verify → pg-02 → switchover → pg-01（README §15.3）
#    - failover：直接關 pg-01 電源/服務，看 patronictl list 與 VIP 行為
#    - 憑證輪替：10-pki -e pki_leaf_force_renew=true → 30-postgres --limit 逐台
```

> 20-storage 本輪跳過的代價：30 階段**不會失敗**，但 pgBackRest 的
> `repo1-path=/mnt/pgbackup/pgbackrest` 會被建成 pg 節點的**本機目錄**，
> 備份安靜地落在本機碟（無異地、失去備份意義）；即使已設定 zstd 與 7 天
> retention，也只是本機備份保留，並不等於 DR——教學環境可接受，
> 知道就好。想連備份一起練，把 machine-3 加開 `nfs` 身分（`nfs-01:
> {ansible_host: 192.168.50.13}`，nfs 群組只定義 `storage_volumes` 一個
> 相撞變數，host_vars 覆寫掉即可與 pg-03 同機），順序改為 10 → 20 → 30。

### 6.4 各組件輪練菜單

| 輪 | 開啟的群組（身分） | Ubuntu 24 可跑？ | 特別注意 |
|---|---|---|---|
| PKI + NFS | monitoring、nfs | ✅ | 最輕量的第一輪；nfs 只撞 `storage_volumes` |
| PostgreSQL 全套 | monitoring、postgres、etcd | ❌ 需 26.04 | 上面的 worked example |
| RabbitMQ | monitoring、rabbitmq | ❌ 需 26.04 | 首跑三台同時；cookie 先落地 |
| ScyllaDB | monitoring、scylladb | ✅（Docker） | 實體機看真的 aio/XFS 行為（lab 看不到）；首跑放維護窗 |
| SeaweedFS | monitoring、seaweedfs（+postgres） | ⚠️ 依賴 PG | filer 要 PG——與 postgres 輪合併跑（sw 與 pg 都定義 4 個相撞變數 → 必須用雙身分：sw-0x 與 pg-0x 是不同 inventory 主機、同實體機） |
| Kong + 邊界 | monitoring、kong、lb、egress | ✅ | kong 與 lb 各有 keepalived → 雙身分隔開；體驗真 L2 的 VRRP/GARP |
| KeyDB + mock app | monitoring、app_email_proxy、keydb、compose_apps | ✅ | `compose_app_mock_projects: [email_proxy]` 加進 overrides |
| 監控 | monitoring | ✅ | 任何輪都可以最後加跑 60，看 Prometheus 抓自己 |

換輪之前：請 MIS 回滾快照（最乾淨），或至少手動清掉前一輪的服務
（repo 沒有 teardown playbook——`apt purge` + 刪 `/opt/<service>`、
`/var/lib/<service>`、`/etc/platform/pki` 保留即可）。

---

## 7. 與 AI 協作產生 Playbook 的方法

這一節回答：「每個服務如果我要請 AI 幫我產 ansible playbook，
該怎麼給 prompt？」核心答案先講：

> **AI 需要的不是需求描述，是「介面契約 + 非顯而易見的設計決策」。**
> 這個 repo 的每個 role 都埋著十幾條「不明講 AI 一定做錯」的決策
> （serial 語意、埠共存、handler 分工、no_log 紀律……）。你的 prompt
> 品質 = 你把這些決策講清楚的程度。裁判不是你的眼睛，是
> `make lint` → `make syntax` → lab 實測 → 99-verify。

### 7.1 通用 prompt 骨架

每次請 AI 寫/改 role 都用這個結構（【】內換成實際內容）：

````markdown
## 角色
你是資深 Ansible 工程師，為一個地端多專案基礎平台 monorepo 寫 production 等級的 role。

## 介面契約（必須遵守，附上原文）
【貼上 ansible/CONVENTIONS.md 的相關章節：§1 群組表、§3 埠號表、
§5 PKI 契約、§8 Role 撰寫規範。整份貼也可以，它就是為此而寫的】

## 環境事實
- 目標 OS：Ubuntu 26.04（套件一律用官方 archive，禁止第三方 apt repo）
- inventory 群組：【群組名】= 【節點/IP】；跨 role 變數在 group_vars/all/vars.yml：【貼相關段】
- 這個 role 消費的 vault 別名：【例 rabbitmq_admin_password（role 內不直接碰 vault_*）】
- lab 是 systemd 容器（is_container=true 時跳過 kernel 級 sysctl/swapoff/磁碟操作）

## 任務
【要什麼：例「寫 roles/xxx：defaults/tasks/handlers/templates/meta，
與 playbooks/NN-xxx.yml」。附上要部署的軟體、pin 的版本、拓撲】

## 硬性規範（缺一即退件）
1. 冪等：重跑 changed=0；command/shell 必配 creates/changed_when/前置檢查
2. 模組一律 FQCN；ansible-lint production profile 過關（role 變數必須 role 名前綴；
   跨 role 契約變數用 # noqa: var-naming[no-role-prefix]）
3. 每個非自明 task 上方要有「為什麼」的中文註解（不是翻譯 task name）
4. 機密：含密碼的 task no_log: true、檔案 0600；迭代 projects 的 loop 一律 loop_control.label
5. 埠共存原則：服務綁「節點 IP + 127.0.0.1」、HAProxy/VIP 持有者綁 VIP，絕不綁 0.0.0.0
6. 不硬編主機名/IP：一律 groups['xxx'] + hostvars[h].ansible_host 展開；跨群組解引用 | default([])
7. handler 名稱「restart <service>」小寫；meta dependencies 留空（順序由 site.yml 保證）
8. 首次成形語意：【全節點同啟 or serial:1，理由】

## 這個服務的特殊決策（非明講必錯）
【貼 §7.3 對應服務的 prompt 卡】

## 交付物
1. role 完整檔案 2. playbook 3. 部署後驗證指令（具體 CLI + 預期輸出）
4. 一段 99-verify 風格的驗收 play（驗使用者視角行為、可重複執行、自我清理）
5. 你做了哪些契約之外的假設——逐條列出等我確認
````

最後一項（列出假設）最重要：AI 的錯誤大多藏在它沒說出口的假設裡。

### 7.2 每服務 prompt 卡（「非明講必錯」清單）

以下每張卡直接貼進骨架的【特殊決策】段。內容全部萃取自現有 role 的
實測註解——它們就是「AI 第一次寫必錯、人類踩雷後才寫下來」的清單。

**PKI（internal_ca / pki_leaf）**
- 私鑰在目標主機本地生成、永不離開；CSR/憑證用 slurp/copy content 走記憶體，不 fetch 落地 controller
- 簽發 delegate_to 簽發主機；簽出路徑 = `issued/<host>-<name>.crt` 一檔兩用（稽核副本）
- Root 私鑰離線是合法日常：Root 層 task 用 when 整層跳過而非報錯；唯一無解態（Issuing 不存在且 Root 已離線）要 assert 出人話
- PEM 串接必須 YAML literal block（`|`）——Jinja 表達式串 `'\n'` 會落地成字面反斜線+n（踩雷 #2）
- `pki_certs_changed` fact：只設 true 絕不設 false，下游 `| default(false)` 讀；不能用 handler（要跨 play）
- update-ca-certificates 要 inline 當下執行（noqa no-handler）——後續 task 立刻依賴信任庫
- 憑證先落 root:root（服務帳號不存在），用 getent 解析「有效擁有者」防所有權乒乓假 changed

**PostgreSQL（etcd / patroni / pgbouncer / pgbackrest）**
- etcd 與 patroni play **禁止 serial:1**（首跑要同時湊 quorum）；只有 haproxy/keepalived play serial:1——AI 直覺會給資料庫加 serial，首跑直接卡死
- Patroni bootstrap 順序不是靠 play 排序：首節點等自己 /leader=200、副本 delegate_to 首節點探測後才起；`patroni_first_boot` 必須在佈署 config *之前* stat
- 先裝 postgresql-common → 關 create_main_cluster → 才裝 postgresql-18（順序反了 postinst 搶佔 5432）
- 設定兩層真相：bootstrap.dcs 只在首次 initdb 寫入 DCS，之後 patronictl edit-config；handler 只准 reload、絕不給 restart（leader restart = failover）
- 隱形依賴：python3-etcd（缺 = DCS fatal）、python3-systemd（缺 = Type=notify 無限重啟）
- pgBackRest：repo 目錄以 postgres 身分建（NFS root_squash）+ run_once；archive_command 在 stanza 前失敗是預期、check 要 retry；備份腳本執行當下自判 leader（replica exit 0）
- extension .so 裝全部節點、CREATE EXTENSION 只在 leader run_once

**RabbitMQ**
- 禁止 serial:1、禁止「seed 先起」：4.x virgin 節點同時啟動互相協商，單獨先起無限等（實測卡 10 分鐘被 systemd 砍）
- apt 安裝前先放 policy-rc.d（exit 101）擋自啟——否則自產隨機 erlang cookie、三台各自成單機叢集；cookie 0400 + no_log、先於首次啟動
- listener 綁 `{{ ansible_host }}` 不綁 wildcard；API 模組 login_host 也用 ansible_host（loopback 連不到）
- 租戶資源全部 run_once + delegate_to `groups['rabbitmq'][0]`；期望節點數用 `groups['rabbitmq'] | length` 不硬編 3

**KeyDB**
- 單一 template 渲染兩次（master/replica 唯一差異是埠）；`port 0` 關明文、`cluster-announce-ip` 必設
- handler 必須 docker compose recreate（不是 restart：掛載檔內容變更 compose 偵測不到）
- cluster create 端點順序是語意：3 個 :6379 在前、3 個 :6380 在後；冪等靠先查 cluster_known_nodes < 6 才 create
- 映像 UID 999：目錄/tls/conf 全 chown 999；exporter 容器 user: 999:999；healthcheck 必須 grep PONG（NOAUTH 的 exit code 也是 0）

**ScyllaDB**
- seeds = 全員互列 + sort（Raft 時代 seed 只是初始接觸點）；三台同時跑、不需 serial
- `--developer-mode 0` 必須顯式傳（映像預設是 1）；--smp/--memory 與容器 cpus/mem_limit 同組變數推導
- `fs.aio-max-nr` 是唯一「is_container 也要設」的 sysctl（全 kernel 計數器、dev mode 不豁免）且 reload: false
- cqlsh 輸出解析禁用 `is search('\b...')`（Jinja 把 \b 當 backspace，恆 false——踩雷 #20）；用 split('|') 取欄做清單成員判斷
- 出廠帳號流程：probe admin（retries 防 auth 暖機誤判）→ cassandra 建 admin → DROP cassandra → 角色審計（until 等 roles cache）
- flush_handlers 在 compose up **之前**（避免 boot-kill-boot 重跑 IO 基準）；憑證 copy 到 /opt/scylladb/tls chown 999，不直接掛 pki_dir

**SeaweedFS**
- 單容器 `weed server` 四段旗標（不是四個容器）；master.peers 三台互指 + sort；network_mode host（bridge 下 raft 位址錯亂）
- `-rack={{ inventory_hostname }}` 是 replication=010 能保證跨節點副本的前提
- filer store 用 `[postgres2]`、指 pgbouncer-vip、sslmode=require；identity（宣告式 s3.json + recreate）與 bucket（weed shell run_once 冪等補建）是分離的兩條路
- 旗標名以鎖定版本 `weed server -h` 實測為準（部署前查證清單）

**Kong**
- 全站唯一服務本體直接綁 VIP 的組件 → `ip_nonlocal_bind=1` 寫在 kong role 自己的 tasks（35 不跑 haproxy role）
- 宣告檔「staged → kong config parse → 正式檔」閘門必須 inline（handler 太晚）
- handler 分工：kong.yml/憑證 → `kong reload`；compose/env → recreate（reload 讀不到新 env）
- upstream targets 渲染成節點 IP（host network 容器不吃宿主 /etc/hosts）
- keepalived track 用 curl 127.0.0.1:8100/status 不用 pgrep（行程名是 nginx）

**HAProxy / Keepalived / Squid（邊界）**
- haproxy「一份 role 多種面孔」：模板 = `haproxy-{{ haproxy_profile }}.cfg.j2`；profile 刻意無預設（缺變數硬爆）+ 白名單 assert
- edge frontends 從 projects selectattr 組裝 + 部署前埠唯一性 assert；backend 由 groups[...] 展開，模板永不出現專案名
- template 一律帶 validate（haproxy -c / squid -k parse）；allowlist 檔必須先於 squid.conf 落地（parse 會開引用檔）
- handler 一律 reload；flush_handlers 必須在 wait_for 之前（apt 裝完會以 Debian 預設組態自啟——假通過）
- keepalived：單播 VRRP（unicast_peer 由群組 difference 展開）、auth_pass 只取 8 字元、|track weight| 嚴格大於主備 priority 差、網卡偵測要把介面名的 `-.:` 正規化成 `_` 再查 facts、keepalived.conf 0600+no_log
- 一台主機一份 keepalived.conf：同居組件的 VIP instance 集中定義在持有者的 group_vars

**compose_app（50-apps）**
- projects 聚合器鐵律：hash_behaviour=replace → 全 repo 只有 projects.yml 定義 `projects`，專案檔只定義 `project_<name>`——AI 會直覺在每個專案檔各寫一個 projects: 段，必錯
- handler recreate + set_fact 累積已部署佇列（handler 吃不到 loop 參數）；自驗前 flush_handlers
- mock 模式語意完整講：build ./mock、command 覆寫選角色、與真 app 吃同一份 .env；prod 絕不產 build 段
- .env 0600 + no_log；docker-compose.yml 刻意 0644 不 no_log（保留 --diff 可讀）——兩者差異要講明

**monitoring / gitlab**
- Prometheus 全部 static_configs 由 inventory 展開（for h in groups[...] | default([]) | sort + instance label）；禁止硬編 IP、禁止 service discovery
- blackbox 目標從 projects 展開、與 99-verify 共用同一份展開式（單一事實來源）；容器不吃 /etc/hosts → compose extra_hosts 灌入
- Grafana/GitLab root 密碼都是「僅首次初始化生效」語意
- GitLab 憑證先於安裝落地；omnibus 的 node_exporter 要停用（撞全站 9100）；Runner 註冊冪等靠 grep '[[runners]]'

**99-verify 風格的驗收**
- 每子系統一個 play + 雙 tag（verify、verify-<名>）；空群組自動 skip；迭代 projects 不寫死專案名
- 驗行為不驗存活：跨節點寫讀（run_once + delegate_to groups[...][ -1]）、真的收發訊息
- 全部唯讀或自我清理；暖機用 until+retries 在查詢層輪詢（不是直接 assert）
- 負向斷言用 wait_for state: stopped；Squid 拒絕看 %{http_connect}（uri 模組做不到，這是少數 curl 正確的場合）

### 7.3 完整範例：請 AI 重寫 RabbitMQ role 的 prompt

```markdown
你是資深 Ansible 工程師。為地端平台 monorepo 寫 roles/rabbitmq 與 playbooks/31-rabbitmq.yml。

【介面契約】（貼 CONVENTIONS.md §1/§3/§5/§6/§8 相關段落）
- 群組 rabbitmq = mq-01..03（10.20.30.21-23，VLAN30）；VIP 10.20.30.20（vrid 31）
- 埠：AMQPS 5671（節點 IP）、明文 5672 停用、management 15672、inter-node 25672/4369、prometheus 15692
- 憑證：rabbitmq-server（server profile，SAN 含 rabbitmq-vip），pki_leaf 已落地 /etc/platform/pki，owner 是 root，
  你的 role 要 chown 給 rabbitmq 並消費 pki_certs_changed fact 觸發 restart
- vault 別名：rabbitmq_admin_password、rabbitmq_erlang_cookie（role 不碰 vault_*）
- 租戶：rabbitmq_tenants 由 projects 推導（每項 {vhost,user,password,dlx_exchange,dlq_queue,queues}），可為空

【環境】Ubuntu 26.04 官方 archive（RabbitMQ 4.0.5 + Erlang 27），禁止第三方 repo。
lab 是 systemd 容器（本 role 無 kernel 級操作，不需 is_container 分支）。

【非明講必錯】（貼 §7.2 RabbitMQ 卡全部 4 條）

【硬性規範】（貼骨架第 1–8 條；第 8 條填：首次成形必須全節點同啟，
linear strategy 靠「單一 systemd started task 三台並行」實現，
之後 await_startup + await_online_nodes N，N = groups['rabbitmq'] | length）

【交付物】role 全檔 + playbook（第二個 play 掛 haproxy/keepalived serial:1，tags mq-lb）
+ 驗證 CLI + 99-verify 風格 play + 你的假設清單
```

### 7.4 審查與驗證迴圈

AI 給出的東西照這個順序過關（= repo CI 的 validate 階段 + lab 實測）：

```bash
make lint BIN=~/ansible-venv/bin/       # yamllint + ansible-lint production profile（0 findings 才過）
make syntax BIN=~/ansible-venv/bin/     # 兩套 inventory 的 --syntax-check
make lab-up lab-deploy lab-verify       # lab 全鏈實測是唯一可信驗證（repo 一貫哲學）
# 冪等驗證：同一 playbook 重跑第二次 → changed=0
```

過關後，再開**第二輪對抗式審查**（repo README §16 的做法）——把 AI 產出
貼回去，用這個 prompt：

```markdown
你現在是對抗式 reviewer。逐條攻擊這個 role：
1. 首次成形 vs 重跑：哪個 task 在「叢集已運行」時重跑會造成服務中斷？serial 語意對嗎？
2. 冪等：哪個 task 第二次跑會假 changed？哪個 command 缺 changed_when/creates？
3. 機密：哪個 task 會把密碼印上終端（loop 輸出、--diff、error message）？
4. 埠共存：有沒有 0.0.0.0 綁定會撞掉同機 VIP 持有者？
5. 憑證輪替：10-pki 重簽後（只有 pki_certs_changed fact、檔案內容變了但
   本 role 的 template 沒變），這個 role 會 reload 嗎？
6. --check 模式：哪個後續 task 會因 register 是 skipped 而炸？
7. 空群組/零租戶：groups['x'] 不存在或 projects 為空時哪裡爆 undefined？
每一條要指出具體行號，並給修正 diff。
```

### 7.5 新專案 onboarding 的 prompt

新專案（例如 `crm`）不寫 role、不寫 play，只寫**宣告**。給 AI 的 prompt：

```markdown
依 CONVENTIONS.md §10.3 的 schema 與 §10.5 的 onboarding 清單，為新專案 crm
（用到 pg + rabbitmq + edge，app 節點共用既有 app_email_proxy 主機）產出：
1. inventories/prod/group_vars/all/project_crm.yml（宣告檔；密碼引用 vault_prj_crm_* 別名）
2. projects.yml 要加的那一行
3. vault_prj_crm.yml.example 範本段 + lab 佔位密文檔的建立指令
4. lab symlink 指令
5. edge 埠與 DNS 名要登記進 CONVENTIONS §2/§3 的表格 diff
6. 驗證流程：make lint → syntax → lab 全鏈 → 99-verify 哪些 tag 會自動覆蓋到新專案
禁止：新增 play、新增 role、在專案檔定義 projects:、硬編 IP。
```

---

## 8. 常用指令速查

```bash
# ── 靜態檢查（改任何東西之後）──
make lint            # yamllint + ansible-lint（production profile）
make syntax          # 兩套 inventory 語法檢查
make check-all       # = CI validate 階段

# ── Docker lab ──
make lab-up          # 起 21 節點
make lab-sh          # 進 mgmt-01（/work/ansible，改 code 即時生效——bind mount）
make lab-deploy      # site.yml 全鏈（20–25 分）
make lab-verify      # 99-verify
make lab-destroy     # 銷毀（含 volume）

# ── 部署（ansible/ 內；prod 免 -i，lab/mislab 要 -i）──
ansible-playbook playbooks/site.yml                          # 一鍵全站
ansible-playbook playbooks/30-postgres.yml                   # 單一階段
ansible-playbook playbooks/99-verify.yml --tags verify-pg    # 單一子系統驗收
ansible-playbook playbooks/XX-xxx.yml --check --diff         # 乾跑（首跑參考性有限）
ansible-playbook playbooks/XX-xxx.yml --limit <host>         # 已運行叢集的滾動變更

# ── vault ──
ansible-vault view inventories/prod/group_vars/all/vault.yml
ansible-vault edit inventories/lab/group_vars/all/vault.yml    # lab 鑰匙在 Git，直接編

# ── 維運 runbook（README §15）──
# 憑證輪替：10-pki -e pki_leaf_force_renew=true → site.yml → verify-pki
# 滾動重啟資料層：--limit 逐台；leader 先 patronictl switchover
# 新機納管：Terraform → hosts.yml → ssh-keyscan → site.yml --limit 新機,mgmt-01
# 密碼輪替：ansible-vault edit → site.yml（冪等收斂）
```

---

*本文件對應 2026-08 平台化後的 repo 狀態（21 節點 lab、projects 專案層、
Kong/SeaweedFS/pgvector/pg_search）。已知狀態：21 節點版尚未重跑 lab 全鏈
（static 檢查全綠）；README §17 收錄 21 條實測踩雷，部署卡關先查它。*
