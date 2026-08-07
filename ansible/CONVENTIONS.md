# CONVENTIONS — 全平台跨 Role 契約（變數 / 埠號 / 路徑 / PKI / 專案層）

> **這份文件是本 repo 的「介面契約」**。所有 role、playbook、template 都必須遵守這裡定義的
> 變數名稱、埠號、路徑。改任何一項 = 先改這份文件 → PR review → 再改程式碼。
> 假想讀者：第一次接手本平台的 junior 架構師。
>
> **平台 vs 專案（§10 詳述）**：本 repo 是「多專案共用的地端基礎平台」。
> 平台層 = 可選組件選單（inventory 群組 = 開關）；專案層 = 純資料宣告
> （`projects` 登記簿）。email_proxy 是第一個登記的專案，不再是 repo 的主體。

---

## 1. 主機與群組（inventory groups = 組件選單）

| 群組 | 成員 | 角色 | 可空？ | 附註 |
|---|---|---|---|---|
| `lb` | lb-01, lb-02 | 邊界 HAProxy + Keepalived + Squid egress | 可 | VLAN 10 |
| `egress` | = lb | Squid 顯式白名單正向代理 | 可 | 與 lb 同居（ADR-3） |
| `kong` | kong-01, kong-02 | Kong API Gateway（DB-less、Docker） | 可 | VLAN 20 |
| `app_email_proxy` | app-01..03 | email_proxy 專案的 compose 應用節點 | 可 | VLAN 20；`compose_apps` 的 child |
| `compose_apps` | children: app_email_proxy… | 全部「VM+Compose 型專案」節點的 parent 群組 | 可 | 50-apps.yml 的 hosts 目標 |
| `keydb` | = app_email_proxy | KeyDB 3 master + 3 replica（email_proxy 私有快取） | 可 | 同專案 app 主機（§10.6） |
| `postgres` | pg-01..03 | Patroni/PG18 + PgBouncer + HAProxy + Keepalived | 可 | VLAN 30 |
| `etcd` | = postgres | etcd 3 節點（同居 pg） | 可 | 同 pg 主機 |
| `rabbitmq` | mq-01..03 | RabbitMQ 4.x + HAProxy + Keepalived | 可 | VLAN 30 |
| `scylladb` | scylla-01..03 | ScyllaDB 2026.1 3 節點（Docker、TLS、NTS RF=3） | 可 | VLAN 30 |
| `nfs` | nfs-01 | NFSv4 檔案共享 + PG 備份庫 | 可 | VLAN 40 |
| `seaweedfs` | sw-01..03 | SeaweedFS S3 物件儲存（Docker；filer store 在 PG） | 可 | VLAN 40；**依賴 postgres 組件** |
| `monitoring` | mgmt-01 | Ansible 控制 + PKI 簽發 + Prometheus/Grafana | **不可空** | VLAN 99；平台核心 |
| `gitlab` | gitlab-01 | GitLab CE + Container Registry | 可 | VLAN 50（lab 不部署） |
| `gitlab_runner` | runner-01 | GitLab Runner（docker executor） | 可 | VLAN 50（lab 不部署） |

**組件選單的開關語意（junior 必讀）**：

1. 兩套 inventory **永遠宣告全部平台群組**；不用的組件留「空群組」（`kong: hosts: {}`），
   對應 play 會自動 skip（*no hosts matched*）。**不要刪群組**——群組不存在時，
   模板裡的 `groups['kong']` 是 undefined key 直接爆錯。
2. 所有跨群組解引用一律 `groups['xxx'] | default([])`（雙保險）。
3. `monitoring` 是唯一不可拆卸的核心（Ansible 控制節點 + Issuing CA + 監控）。
4. 組件依賴：`seaweedfs` 需要 `postgres`（filer 元資料庫）；`compose_apps` 型專案
   依賴其宣告用到的資料層組件；其餘組件彼此獨立。

**慣例**：role 內**永遠不可硬編主機名/IP**，一律用 `groups['xxx']` + `hostvars[h].ansible_host` 展開。

## 2. IP / VLAN 配置（prod 與 lab 完全相同，這是刻意的）

| VLAN | 網段 | 成員 |
|---|---|---|
| 10 邊界 | 10.20.10.0/24 | 服務 VIP `.10`、egress VIP `.20`、lb-01 `.11`、lb-02 `.12` |
| 20 應用 | 10.20.20.0/24 | kong VIP `.20`、kong-01/02 `.21-.22`、app-01..03 `.11-.13` |
| 30 資料 | 10.20.30.0/24 | PgBouncer VIP `.10`、pg-01..03 `.11-.13`、RabbitMQ VIP `.20`、mq-01..03 `.21-.23`、scylla-01..03 `.31-.33` |
| 40 儲存 | 10.20.40.0/24 | S3 VIP `.10`、nfs-01 `.11`、sw-01..03 `.21-.23` |
| 50 DevOps | 10.20.50.0/24 | gitlab-01 `.11`、runner-01 `.12` |
| 99 管理 | 10.20.99.0/24 | mgmt-01 `.11` |

**IP 取號紀律（多專案後的稀缺資源）**：VIP = 族首 `x0`、節點從 `x1` 起、
第二個叢集族從 `.21` 起。新專案要 IP 先改本表（PR），再改 hosts.yml 與 terraform。

DNS 名稱（由 `common` role 寫入 `/etc/hosts`，ADR-5）：
`svc-api.{{ domain }}`→10.20.10.10、`egress-proxy.{{ domain }}`→10.20.10.20、
`kong-vip.{{ domain }}`→10.20.20.20、`pgbouncer-vip.{{ domain }}`→10.20.30.10、
`rabbitmq-vip.{{ domain }}`→10.20.30.20、`s3.{{ domain }}`→10.20.40.10、
`gitlab.{{ domain }}` 與 `registry.{{ domain }}`→10.20.50.11、每台主機 `<host>.{{ domain }}` + 短名。

## 3. 埠號總表（唯一事實來源）

| 服務 | 埠 | 綁定位置 | 說明 |
|---|---|---|---|
| 邊界 HTTPS | 443 | lb: 服務 VIP（`*:443`） | TLS 終止於 HAProxy；專案 edge frontends 由 §10 宣告 |
| 邊界 SMTPS | 465 | lb: `*:465` | TCP passthrough → app:2525（email_proxy 專案宣告） |
| app HTTP | 8080 | app_email_proxy 節點 | `/health` 為健康檢查端點 |
| app SMTP | 2525 | app_email_proxy 節點 | smtp-receiver |
| Kong proxy HTTP | 8000 | kong 節點 IP + 127.0.0.1 | 北向：僅收邊界 HAProxy 轉入（TLS 已在邊界終止） |
| Kong proxy HTTPS | 8443 | kong 節點 IP + VIP + 127.0.0.1 | 東西向 API 入口（kong-server 憑證；BACKUP 靠 ip_nonlocal_bind 預綁） |
| Kong admin | 8001 | kong: **僅 127.0.0.1** | DB-less 下唯讀；絕不外露 |
| Kong status/metrics | 8100 | kong 節點 IP + 127.0.0.1 | `/status` 健檢 + `/metrics`（Prometheus） |
| HAProxy stats/metrics | 8404 | 各 haproxy 節點 IP | `/stats` 頁面 + `/metrics`（Prometheus） |
| PgBouncer | 6432 | 各 pg 節點「節點 IP + 127.0.0.1」 | client TLS required；**不可綁 0.0.0.0**（埠共存原則，見下） |
| PG RW VIP | 6432 | pg: PgBouncer VIP | HAProxy → leader 的 PgBouncer |
| PG RO VIP | 6433 | pg: PgBouncer VIP | HAProxy → replica 的 PgBouncer |
| PostgreSQL | 5432 | pg 節點（含 127.0.0.1） | 僅本機 PgBouncer / 節點間複寫 |
| Patroni REST | 8008 | pg 節點 IP | GET 健康端點開放；寫入端點 basic auth |
| etcd client / peer | 2379 / 2380 | pg 節點 IP + 127.0.0.1 | 全 TLS + 雙向驗證 |
| AMQPS | 5671 | mq 節點 IP；VIP 由 HAProxy 綁 | 停用明文 5672 對外 |
| RabbitMQ inter-node / epmd | 25672 / 4369 | mq 節點 | 叢集內部 |
| RabbitMQ management | 15672 | mq 節點 IP（VIP 經 HAProxy） | HTTP，僅 VLAN 30 |
| RabbitMQ prometheus | 15692 | mq 節點 IP | |
| KeyDB master | 6379（bus 16379） | app_email_proxy 節點 IP | TLS-only（`port 0`） |
| KeyDB replica | 6380（bus 16380） | app_email_proxy 節點 IP | TLS-only |
| Scylla CQL | 9042 | scylla 節點 IP | TLS；gocql 另自動使用 19042 shard-aware |
| Scylla internode | 7001 | scylla 節點 IP | 節點間 mTLS（明文 7000 不監聽） |
| Scylla REST API | 10000 | scylla: 127.0.0.1 | nodetool 後端；無認證故僅本機 |
| Scylla metrics | 9180 | scylla 節點 IP | 原生 Prometheus 端點，免 exporter |
| SeaweedFS S3 | 8333 | sw 節點 IP；VIP 由 HAProxy 綁 | TLS（seaweedfs-server 憑證）；唯一對外契約口 |
| SeaweedFS master | 9333（gRPC 19333） | sw 節點 IP | raft 叢集 + volume 配置；僅 VLAN 40 內部 |
| SeaweedFS volume | 8380（gRPC 18380） | sw 節點 IP | 資料讀寫；僅叢集內部（預設 8080 與 app 契約衝突，改 8380） |
| SeaweedFS filer | 8888（gRPC 18888） | sw 節點 IP | S3 gateway 的後端；僅叢集內部 |
| SeaweedFS metrics | 9327 | sw 節點 IP | weed server 統一 metrics 端點 |
| NFSv4.1 | 2049 | nfs-01 | v4-only，不開 rpcbind |
| Squid | 3128 | lb 節點；VIP 10.20.10.20 | 顯式白名單 |
| node_exporter | 9100 | 全部主機 | |
| Prometheus / Grafana / Alertmanager / Blackbox | 9090 / 3000 / 9093 / 9115 | mgmt-01 | compose |
| GitLab HTTPS / Registry | 443 / 5050 | gitlab-01 | 內部 CA 憑證 |

**埠共存原則**：VIP 所在的主機群上，「後端服務」與「綁 VIP 的 HAProxy/服務」常常同埠
（PgBouncer 6432 vs VIP:6432、AMQPS 5671 vs VIP:5671、SeaweedFS 8333 vs VIP:8333、
Kong 8443 節點口 vs VIP:8443）。Linux 上 wildcard（0.0.0.0）LISTEN socket 會讓另一
行程綁同埠的特定 IP 直接 EADDRINUSE——**規則：服務綁「自己的節點 IP（+ 127.0.0.1）」，
HAProxy（或 Kong 對 VIP 的預綁）綁「VIP」**，兩者永不相撞；全站已開
`net.ipv4.ip_nonlocal_bind=1` 讓 BACKUP 節點可預綁 VIP 埠。

**埠登記紀律**：專案的 edge frontends（§10）用到的埠必須先登記進本表；
haproxy role 對 edge profile 有「埠不得跨專案重複」的部署前 assert 兜底。

## 4. 路徑契約

| 用途 | 路徑 | 所在主機 |
|---|---|---|
| 葉憑證/私鑰/CA chain | `/etc/platform/pki/`（變數 `pki_dir`） | 全部 |
| CA 私鑰與簽發庫 | `/opt/platform-ca/`（變數 `ca_root`，0700） | 僅 mgmt-01 |
| 系統信任內部 CA | `/usr/local/share/ca-certificates/platform-internal-ca.crt` | 全部（pki_leaf 安裝） |
| NFS 匯出：PG 備份（平台資源） | `/export/pgbackup` | nfs-01 |
| NFS 匯出：專案檔案共享 | `/export/<project-kebab>/…`（專案層宣告，§10） | nfs-01 |
| email_proxy 附件匯出 | `/export/email-proxy/attachments`（project_email_proxy.yml） | nfs-01 |
| email_proxy 附件掛載點 | `/mnt/attachments`（app 容器內 `/data/attachments`） | app_email_proxy |
| PG 備份掛載點 | `/mnt/pgbackup` | pg |
| PG data dir | `/var/lib/postgresql/18/main`（變數 `pg_data_dir`） | pg |
| etcd data dir | `/var/lib/etcd`（prod 掛獨立 VMDK） | pg |
| 專案 compose 目錄 | `/opt/<project-kebab>/`（§10 compose_app.home） | 各專案 app 節點 |
| keydb compose 專案 | `/opt/keydb/` | app_email_proxy |
| scylladb compose 專案 | `/opt/scylladb/` | scylla |
| kong compose 專案 | `/opt/kong/` | kong |
| seaweedfs compose 專案 | `/opt/seaweedfs/` | sw |
| SeaweedFS 資料碟 | `/var/lib/seaweedfs`（獨立 VMDK、XFS） | sw |
| Scylla data dir | `/var/lib/scylla`（變數 `scylla_data_root`，獨立 VMDK、XFS） | scylla |
| monitoring compose 專案 | `/opt/monitoring/` | mgmt-01 |

> **歷史相容注意**：2026-08 平台化改名前，`pki_dir=/etc/email-proxy/pki`、
> `ca_root=/opt/email-proxy-ca`、stanza=email-proxy、PG data dir 尾碼 email-proxy。
> 本 repo 的 prod（10.20.x）當時尚未部署，改名零成本；若你面對的是「用舊值
> 部署過」的環境，改名 = 全站重簽派送 + 服務 reload + NFS 資料搬遷，請按
> README §15 的維護窗流程處理，不要直接重跑 site.yml。

## 5. PKI 契約（最重要的跨 role 介面）

兩層 CA：Root（20 年，離線）→ Issuing（5 年，mgmt-01）→ 葉憑證（397 天）。
CA CN：`PTC-NEC Internal Root CA` / `PTC-NEC Internal Issuing CA`（internal_ca defaults）。

`pki_leaf` role 由變數 `pki_certificates`（各群組 group_vars 定義）驅動，每個項目：

```yaml
pki_certificates:
  - name: etcd                    # 檔名基底 → /etc/platform/pki/etcd.{key,crt}
    profile: peer                 # server=serverAuth / client=clientAuth / peer=兩者
    owner: root                   # 檔案擁有者（服務執行身分）
    group: etcd
    key_mode: "0640"
    extra_sans: ["IP:127.0.0.1"]  # 預設 SAN = DNS:fqdn + DNS:短名 + IP:ansible_host，此處追加
    bundle_pem: false             # true 時額外產出 <name>.pem（crt+chain+key，HAProxy 用）
```

簽發流程（**CSR 不落地 controller、私鑰絕不離開目標主機**）：
目標主機產 key+CSR → `slurp` CSR → `delegate_to: groups['monitoring'][0]` 用 Issuing CA 簽（397d）
→ 簽好的 crt 寫回目標主機。`ca.crt`（chain）派送到 `pki_dir` 並加入系統信任庫。

**落地權限語意**：pki_leaf 一律以 root:root 落地（10-pki 先於服務安裝，服務帳號尚不存在）；
各服務 role 裝完套件後負責把自己的 key chown 給服務帳號。
**輪替語意**：重跑 10-pki 對「未到期憑證」不重簽（冪等）；主動輪替用
`-e pki_leaf_force_renew=true`。憑證更新時 pki_leaf 會設 host fact `pki_certs_changed=true`
（只設 true、從不設 false），消費憑證的 role 據此 notify 自家 reload/restart。

各群組的憑證清單（定義於 `inventories/*/group_vars/<group>.yml`）：

| 群組 | name | profile | 用途 |
|---|---|---|---|
| postgres | `etcd` | peer | etcd server+peer（SAN 加 127.0.0.1） |
| postgres | `patroni-etcd-client` | client | Patroni → etcd |
| postgres | `postgres-server` | server | PG `ssl=on` |
| postgres | `pgbouncer-server` | server | PgBouncer client-side TLS |
| rabbitmq | `rabbitmq-server` | server | AMQPS 5671 |
| app_email_proxy | `keydb-server` | peer | KeyDB TLS + cluster bus（雙向） |
| app_email_proxy | `keydb-client` | client | app / keydb-cli 連線 |
| scylladb | `scylla-server` | peer | internode 7001 mTLS + 9042 客戶端 TLS（SAN 加 127.0.0.1） |
| kong | `kong-server` | server | 東西向 8443 終止（SAN：kong-vip 名稱、VIP、127.0.0.1） |
| seaweedfs | `seaweedfs-server` | server | S3 8333 TLS（SAN：s3 名稱、VIP、127.0.0.1） |
| lb | 各專案 edge cert（§10 組裝，如 `svc-api`） | server + `bundle_pem` | 443 終止（SAN：服務名、VIP） |
| gitlab | `gitlab-server` | server | GitLab/Registry HTTPS |

## 6. Vault 機密變數命名

全部以 `vault_` 前綴；role **一律引用非 vault 別名**（平台機密別名在
`group_vars/all/vars.yml`，專案機密別名在 `group_vars/all/project_<name>.yml`），
role 內不直接碰 `vault_*`。

**平台機密**（`inventories/*/group_vars/all/vault.yml`）：

```
vault_postgres_superuser_password   vault_postgres_replicator_password
vault_pgbouncer_auth_password       vault_pgbouncer_admin_password
vault_patroni_restapi_password      vault_rabbitmq_admin_password
vault_rabbitmq_erlang_cookie        vault_keydb_password
vault_scylla_admin_password
    （↑ Scylla 密碼避免含單引號與雙引號——會破壞 cqlsh 指令的引號結構，建議純英數）
vault_seaweedfs_pg_password         （filer 元資料庫的 PG 帳號）
vault_seaweedfs_s3_admin_access_key vault_seaweedfs_s3_admin_secret_key
vault_vrrp_pass_svc  vault_vrrp_pass_egress  vault_vrrp_pass_pg
vault_vrrp_pass_mq   vault_vrrp_pass_kong    vault_vrrp_pass_s3
    （↑ VRRPv2 PASS 驗證只取前 8 字元，超長會被靜默截斷——請直接產 8 字元）
vault_grafana_admin_password        vault_pgbackrest_cipher_pass
vault_gitlab_root_password
```

**專案機密**（每專案一檔：`inventories/*/group_vars/all/vault_prj_<name>.yml`，
同一把環境鑰匙）。命名規約 `vault_prj_<project>_<用途>`。email_proxy 專案：

```
vault_prj_email_proxy_pg_password       vault_prj_email_proxy_mq_password
vault_prj_email_proxy_scylla_password   vault_prj_email_proxy_jwt_secret
vault_prj_email_proxy_encryption_key
vault_prj_email_proxy_microsoft_client_secret
vault_prj_email_proxy_sendgrid_api_key
```

> 2026-08 平台化改名對照（prod vault 由使用者自行 rekey/搬移）：
> `vault_postgres_app_password`→`vault_prj_email_proxy_pg_password`、
> `vault_rabbitmq_app_user_password`→`vault_prj_email_proxy_mq_password`、
> `vault_scylla_app_password`→`vault_prj_email_proxy_scylla_password`、
> `vault_app_jwt_secret`→`vault_prj_email_proxy_jwt_secret`、
> `vault_app_encryption_key`→`vault_prj_email_proxy_encryption_key`、
> `vault_microsoft_client_secret`→`vault_prj_email_proxy_microsoft_client_secret`、
> `vault_sendgrid_api_key`→`vault_prj_email_proxy_sendgrid_api_key`。

## 7. 全域開關 / 共用變數（`group_vars/all/vars.yml`）

| 變數 | prod | lab | 意義 |
|---|---|---|---|
| `domain` | ptc-nec.com.tw | 同 | 內部網域 |
| `is_container` | false | **true** | lab 容器內跳過 kernel 級 sysctl / swapoff / 磁碟分割 |
| `use_egress_proxy` | true | **false** | 主機層 apt/docker/env 是否經 Squid（lab 直連 NAT；Squid 仍會部署並驗證） |
| `manage_etc_hosts` | true | 同 | ADR-5：名稱解析由 Ansible 管 /etc/hosts |
| `service_vip` / `egress_vip` | 10.20.10.10 / .20 | 同 | |
| `kong_vip` | 10.20.20.20 | 同 | 東西向 API gateway VIP（VI_KONG, vrid 20） |
| `pgbouncer_vip` / `rabbitmq_vip` | 10.20.30.10 / .20 | 同 | |
| `s3_vip` | 10.20.40.10 | 同 | SeaweedFS S3 VIP（VI_S3, vrid 40；DNS：s3.{{ domain }}） |
| `app_http_port` / `app_smtp_port` | 8080 / 2525 | 同 | |
| `kong_proxy_port` / `kong_proxy_tls_port` / `kong_admin_port` / `kong_status_port` | 8000 / 8443 / 8001 / 8100 | 同 | |
| `seaweedfs_s3_port` | 8333 | 同 | S3 契約口（master/volume/filer 埠是 role 內部 knob） |
| `internal_ca_host` | `groups['monitoring'][0]` | 同 | 簽發委派對象 |

**vrid 配置表（同 L2 網段內不可重複）**：VI_SVC=10 / VI_EGRESS=12 / VI_KONG=20 /
VI_PG=30 / VI_MQ=31 / VI_S3=40。新 VIP 先在此登記。

**Lab 降規**（`inventories/lab/group_vars/` 覆寫）：PG `shared_buffers=128MB`、KeyDB
`maxmemory=256mb`、RabbitMQ watermark 0.3、Prometheus retention 2d、Kong worker 1 等。
**拓撲絕不降規**（節點數、VIP、TLS、quorum 與 prod 完全一致——lab 的目的就是驗證拓撲）。

## 8. Role 撰寫規範

1. 每個 role 必有：`defaults/main.yml`（所有可調參數 + 註解）、`tasks/main.yml`、
   `handlers/main.yml`（如需 restart）、`meta/main.yml`；template 放 `templates/*.j2`。
2. **冪等**：重跑 0 changed（首次部署除外）。`command/shell` 必配 `creates`/`changed_when`/條件檢查。
3. 模組**一律用 FQCN**（`ansible.builtin.apt`、`community.crypto.x509_certificate`…）。
4. 註解量：每個非自明 task 上方**必須**有「為什麼」的中文註解（不是翻譯 task name）。
5. 機密檔案 `mode: "0600"`、`no_log: true` 用於含密碼的 task。
   **迭代 `projects` 的 task 一律 `loop_control: label`**（避免 loop 預設輸出把
   專案密碼印上終端），實際落密碼者再加 `no_log: true`。
6. handler 名稱格式：`restart <service>`；服務變更用 notify，不在 task 內直接 restart。
7. 滾動變更（haproxy/keepalived/patroni/kong/seaweedfs）playbook 層用 `serial: 1`
   （叢集組建型除外：rabbitmq/seaweedfs 首次成形需全節點同時啟動，見各 role 檔頭）。
8. 介面偵測：keepalived/haproxy 綁 VIP 的網卡**不可寫死 `ens160`**，由
   role 內以「哪張網卡的 IPv4 與 VIP 同網段」自動偵測（可用變數覆寫）。
9. **跨群組解引用防禦**：模板/變數中的 `groups['xxx']` 一律 `| default([])`
   ——組件選單下任何群組都可能不存在或為空。

## 9. 部署順序依賴（site.yml）

```
00-bootstrap → 05-block-storage → 08-docker → 10-pki
  → 20-storage(NFS) → { 30-postgres, 31-rabbitmq, 32-keydb, 33-scylladb }
  → 34-seaweedfs（依賴 30：filer store 在 PG）
  → 35-kong（僅依賴 08/10）
  → 40-lb → 41-egress
  → 50-apps（依賴其專案宣告用到的組件全就緒）→ 60-monitoring → 99-verify
70-gitlab 獨立（僅依賴 00/10）
```

空群組的階段自動 skip——這就是「組件選單」的執行語意。

---

## 10. 專案層契約（`projects` 登記簿）

### 10.1 分層模型

- **平台層**擁有全部 role 與 playbook；每個資料層 role 提供「多租戶資源迭代點」
  （PG 的 db/extensions、MQ 的 vhost/queues、Scylla 的 keyspace、NFS 的 exports、
  S3 的 bucket/identity、edge/Kong 的 route）。
- **專案層是純資料**：一個專案 = 一個 `project_<name>.yml` 宣告檔 +（如需專屬節點）
  一個 inventory 群組。**專案不新增 play、不新增 role。**
- **引用方向單向**：`projects` 是源頭，group_vars 的組件別名（`pg_databases`、
  `rabbitmq_tenants`…）從 projects 推導；絕不反向。

### 10.2 登記簿（聚合器）

`group_vars/all/projects.yml` 是**全 repo 唯一定義 `projects` 之處**
（Ansible `hash_behaviour=replace`：兩處定義 `projects:` 後者整包覆蓋前者，
所以專案檔各自定義 `project_<name>`，由登記簿顯式收編）：

```yaml
projects:
  email_proxy: "{{ project_email_proxy }}"
  # new_project: "{{ project_new_project }}"   ← 新專案在此登記一行
```

### 10.3 專案宣告檔 schema（`group_vars/all/project_<name>.yml`）

只填會用到的組件段；各段的消費者（role）標注於後：

```yaml
project_<name>:
  name: <name>                    # [a-z0-9_]；資源命名的基底
  components: [pg, rabbitmq, scylla, nfs, s3, edge, kong, compose_app]  # 自我文件

  pg:                             # → roles/patroni/tasks/app_db.yml
    db: <name>
    user: <name>
    password: "{{ vault_prj_<name>_pg_password }}"
    extensions: []                # 例 [vector, pg_search]；逐 db 冪等 CREATE EXTENSION

  rabbitmq:                       # → roles/rabbitmq/tasks/main.yml §10
    vhost: <name>
    user: <name>
    password: "{{ vault_prj_<name>_mq_password }}"
    dlx_exchange: <name>_dlx
    dlq_queue: <name>_dlq
    queues:
      - { name: <name>_queue, dlx: <name>_dlx }

  scylla:                         # → roles/scylla/tasks/main.yml §6
    keyspaces: [<ks1>]
    user: <name>_app
    password: "{{ vault_prj_<name>_scylla_password }}"

  nfs:                            # → group_vars/nfs.yml 組裝 nfs_exports
    exports:
      - path: /export/<name-kebab>/<share>
        clients: "{{ vlan_app_cidr }}"
        options: "rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000"
        owner: "1000"
        group: "1000"
        mode: "0770"

  s3:                             # → roles/seaweedfs/tasks/provision.yml
    buckets: [<name>-data]
    user: <name>-app              # S3 identity 名
    access_key: "{{ vault_prj_<name>_s3_access_key }}"
    secret_key: "{{ vault_prj_<name>_s3_secret_key }}"

  edge:                           # → group_vars/lb.yml 組裝 pki_certificates
    cert:                         #   + roles/haproxy/templates/haproxy-edge.cfg.j2
      name: svc-<name>
      profile: server
      owner: root
      group: root
      key_mode: "0600"
      cn: "svc-<name>.{{ domain }}"
      extra_sans: ["DNS:svc-<name>.{{ domain }}", "DNS:svc-<name>", "IP:{{ service_vip }}"]
      bundle_pem: true
    frontends:
      - name: https               # 產 fe_<project>_https / be_<project>_https
        port: 443                 # ★ 埠先登記 §3；haproxy role assert 不得跨專案重複
        mode: http                # http = TLS 終止；tcp = passthrough
        backend_group: app_<name>
        backend_port: 8080
        healthcheck: "GET /health"

  kong:                           # → roles/kong/templates/kong.yml.j2
    services:
      - name: api
        protocol: http
        backend_group: app_<name> # 後端 = inventory 群組展開（不硬編 IP）
        backend_port: 8080
        health_path: /health
        routes:
          - name: public
            hosts: ["svc-<name>.{{ domain }}"]
            paths: ["/api"]
        plugins: []               # 例 [{name: rate-limiting, config: {minute: 600, policy: local}}]

  egress_allowlist: []            # → group_vars/egress.yml 組裝 Squid 白名單

  compose_app:                    # → roles/compose_app（50-apps.yml）
    hosts_group: app_<name>
    home: /opt/<name-kebab>
    services:                     # 每個 service 一個容器（host network）
      api:
        image: "{{ registry_host }}/<name-kebab>/api:{{ app_image_tag }}"
        command: []               # 可選；mock 模式時 role 自動覆寫
        health_port: 8080         # 可選；有值就產容器層 healthcheck
    mounts: []                    # [{src, dest, readonly}]
    env: {}                       # .env 內容（含機密引用；見 project_email_proxy.yml）
    health: { port: 8080, path: /health }
    wait_ports: [8080]
    # mock 模式不在此宣告：全域清單 compose_app_mock_projects（vars.yml，
    # lab 由 zz_lab_overrides 覆寫成 [email_proxy]）

  monitoring:                     # → roles/monitoring templates
    blackbox_probes:
      - { module: http_2xx_internal_ca, target: "https://svc-<name>.{{ domain }}/health" }
```

### 10.4 機密規約

- 專案機密一律 `vault_prj_<name>_*`，放獨立密文檔 `vault_prj_<name>.yml`（§6）。
- `projects` 內嵌密碼引用：**任何 loop 過 projects 的 task 必須 loop label + no_log**
  （§8-5）；嚴禁 `debug: var=projects`。

### 10.5 新專案 Onboarding 清單（假設專案 `crm`，用 pg+mq+edge）

1. **宣告**：`inventories/prod/group_vars/all/project_crm.yml` + `projects.yml` 登記一行。
2. **lab symlink**：`inventories/lab/group_vars/all/project_crm.yml -> ../../../prod/group_vars/all/project_crm.yml`。
3. **機密 ×3**：prod `vault_prj_crm.yml`（prod 鑰匙）、lab 同名檔（佔位值，lab 鑰匙）、
   `vault_prj.yml.example` 補範本段。
4. **專屬 app 節點**（如需）：hosts.yml×2 加 `app_crm` 群組（掛入 `compose_apps` children）
   + §2 IP 表取號 + `group_vars/app_crm.yml`（pki_certificates/nfs_mounts）+ lab symlink
   + `08-docker.yml` hosts 行 + terraform main.tf VM/反親和 + lab compose 節點
   + `lab-wait-ready.sh` NODES/IPS 陣列。共用既有節點則本項全免。
5. **edge/kong**：埠與公開名先登記（§2 DNS、§3 埠表）；新公開名記得加進
   `extra_hosts_entries` 與該 cert 的 SAN。
6. **監控**：blackbox probes / 告警由 projects 自動展開，通常零改動。
7. **CI**：app repo include `gitlab/ci-templates/`（compose-app / backend / frontend 任選）。
8. **文件**：本檔 §2/§3 表格 + README 專案段。
9. **驗證**：`make lint` → `make syntax` → `make lab-up lab-deploy lab-verify` → prod MR。

### 10.6 已知邊界（誠實記錄）

- **KeyDB 是 email_proxy 的私有同居組件**（不是共用快取服務）。第二個要快取的
  專案出現時，預設做法是為它另建 `keydb_<project>` 群組（同居該專案 app 節點），
  不要共用叢集（跨專案爆炸半徑）。
- **`app_image_tag` 目前是全域部署變數**（CI trigger 以 `-e` 覆寫）。多個 compose
  專案獨立部署時需拆成 per-project tag（列為 TODO，見 .gitlab-ci.yml 註解）。
- **Kong oauth2 plugin 不支援 DB-less**：JWT / key-auth / ACL / CORS /
  rate-limiting(local/redis) 都支援。若未來專案必須用 oauth2 才重訪 DB-backed（ADR-14）。
- **SeaweedFS 的 pgBackRest 定位**：filer 元資料在 PG 內 → S3 **永遠只能當 PG 的
  次要備份庫（repo2）**，PG 還原主路徑必須是 NFS repo1（否則循環依賴：還原 PG
  需要讀 S3、讀 S3 需要 PG）。
