# CONVENTIONS — 全專案跨 Role 契約（變數 / 埠號 / 路徑 / PKI）

> **這份文件是本 repo 的「介面契約」**。所有 role、playbook、template 都必須遵守這裡定義的
> 變數名稱、埠號、路徑。改任何一項 = 先改這份文件 → PR review → 再改程式碼。
> 假想讀者：第一次接手本專案的 junior 架構師。

---

## 1. 主機與群組（inventory groups）

| 群組 | 成員 | 角色 | 附註 |
|---|---|---|---|
| `lb` | lb-01, lb-02 | 邊界 HAProxy + Keepalived + Squid egress | VLAN 10 |
| `app` | app-01..03 | api/worker/smtp compose + KeyDB | VLAN 20 |
| `keydb` | = app | KeyDB 3 master + 3 replica（同居 app） | 同 app 主機 |
| `postgres` | pg-01..03 | Patroni/PG18 + PgBouncer + HAProxy + Keepalived | VLAN 30 |
| `etcd` | = postgres | etcd 3 節點（同居 pg） | 同 pg 主機 |
| `rabbitmq` | mq-01..03 | RabbitMQ 4.x + HAProxy + Keepalived | VLAN 30 |
| `nfs` | nfs-01 | NFSv4 附件 + PG 備份庫 | VLAN 40 |
| `monitoring` | mgmt-01 | Ansible 控制 + PKI 簽發 + Prometheus/Grafana | VLAN 99 |
| `egress` | = lb | Squid 顯式白名單正向代理 | 與 lb 同居（ADR-3） |
| `gitlab` | gitlab-01 | GitLab CE + Container Registry | VLAN 50（lab 不部署） |
| `gitlab_runner` | runner-01 | GitLab Runner（docker executor） | VLAN 50（lab 不部署） |

**慣例**：role 內**永遠不可硬編主機名/IP**，一律用 `groups['xxx']` + `hostvars[h].ansible_host` 展開。

## 2. IP / VLAN 配置（prod 與 lab 完全相同，這是刻意的）

| VLAN | 網段 | 成員 |
|---|---|---|
| 10 邊界 | 10.20.10.0/24 | 服務 VIP `.10`、egress VIP `.20`、lb-01 `.11`、lb-02 `.12` |
| 20 應用 | 10.20.20.0/24 | app-01..03 `.11-.13` |
| 30 資料 | 10.20.30.0/24 | PgBouncer VIP `.10`、pg-01..03 `.11-.13`、RabbitMQ VIP `.20`、mq-01..03 `.21-.23` |
| 40 儲存 | 10.20.40.0/24 | nfs-01 `.11` |
| 50 DevOps | 10.20.50.0/24 | gitlab-01 `.11`、runner-01 `.12` |
| 99 管理 | 10.20.99.0/24 | mgmt-01 `.11` |

DNS 名稱（由 `common` role 寫入 `/etc/hosts`，ADR-5）：
`svc-api.{{ domain }}`→10.20.10.10、`egress-proxy.{{ domain }}`→10.20.10.20、
`pgbouncer-vip.{{ domain }}`→10.20.30.10、`rabbitmq-vip.{{ domain }}`→10.20.30.20、
`gitlab.{{ domain }}` 與 `registry.{{ domain }}`→10.20.50.11、每台主機 `<host>.{{ domain }}` + 短名。

## 3. 埠號總表（唯一事實來源）

| 服務 | 埠 | 綁定位置 | 說明 |
|---|---|---|---|
| 邊界 HTTPS | 443 | lb: 服務 VIP（`*:443`） | TLS 終止於 HAProxy |
| 邊界 SMTPS | 465 | lb: `*:465` | TCP passthrough → app:2525 |
| app HTTP | 8080 | app 節點 | `/health` 為健康檢查端點 |
| app SMTP | 2525 | app 節點 | smtp-receiver |
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
| KeyDB master | 6379（bus 16379） | app 節點 IP | TLS-only（`port 0`） |
| KeyDB replica | 6380（bus 16380） | app 節點 IP | TLS-only |
| NFSv4.1 | 2049 | nfs-01 | v4-only，不開 rpcbind |
| Squid | 3128 | lb 節點；VIP 10.20.10.20 | 顯式白名單 |
| node_exporter | 9100 | 全部主機 | |
| Prometheus / Grafana / Alertmanager / Blackbox | 9090 / 3000 / 9093 / 9115 | mgmt-01 | compose |
| GitLab HTTPS / Registry | 443 / 5050 | gitlab-01 | 內部 CA 憑證 |

**埠共存原則**：VIP 所在的主機群上，「後端服務」與「綁 VIP 的 HAProxy」常常同埠
（PgBouncer 6432 vs VIP:6432、AMQPS 5671 vs VIP:5671、management 15672 vs VIP:15672）。
Linux 上 wildcard（0.0.0.0）LISTEN socket 會讓另一行程綁同埠的特定 IP 直接 EADDRINUSE——
**規則：服務綁「自己的節點 IP（+ 127.0.0.1）」，HAProxy 綁「VIP」**，兩者永不相撞。

## 4. 路徑契約

| 用途 | 路徑 | 所在主機 |
|---|---|---|
| 葉憑證/私鑰/CA chain | `/etc/email-proxy/pki/`（變數 `pki_dir`） | 全部 |
| CA 私鑰與簽發庫 | `/opt/email-proxy-ca/`（變數 `ca_root`，0700） | 僅 mgmt-01 |
| 系統信任內部 CA | `/usr/local/share/ca-certificates/email-proxy-internal-ca.crt` | 全部（pki_leaf 安裝） |
| NFS 匯出：附件 | `/export/mail-proxy/attachments` | nfs-01 |
| NFS 匯出：PG 備份 | `/export/mail-proxy/pgbackup` | nfs-01 |
| 附件掛載點 | `/mnt/attachments`（app 容器內 `/data/attachments`） | app |
| PG 備份掛載點 | `/mnt/pgbackup` | pg |
| PG data dir | `/var/lib/postgresql/18/email-proxy`（變數 `pg_data_dir`） | pg |
| etcd data dir | `/var/lib/etcd`（prod 掛獨立 VMDK） | pg |
| app compose 專案 | `/opt/email-proxy/` | app |
| keydb compose 專案 | `/opt/keydb/` | app |
| monitoring compose 專案 | `/opt/monitoring/` | mgmt-01 |

## 5. PKI 契約（最重要的跨 role 介面）

兩層 CA：Root（20 年，離線）→ Issuing（5 年，mgmt-01）→ 葉憑證（397 天）。

`pki_leaf` role 由變數 `pki_certificates`（各群組 group_vars 定義）驅動，每個項目：

```yaml
pki_certificates:
  - name: etcd                    # 檔名基底 → /etc/email-proxy/pki/etcd.{key,crt}
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
| app | `keydb-server` | peer | KeyDB TLS + cluster bus（雙向） |
| app | `keydb-client` | client | app / keydb-cli 連線 |
| lb | `svc-api` | server + `bundle_pem` | 443 終止（SAN：svc-api、VIP） |
| gitlab | `gitlab-server` | server | GitLab/Registry HTTPS |

## 6. Vault 機密變數命名（`inventories/*/group_vars/all/vault.yml`）

全部以 `vault_` 前綴；role **一律引用 `vars.yml` 中的非 vault 別名**（如
`postgres_superuser_password: "{{ vault_postgres_superuser_password }}"`），role 內不直接碰 `vault_*`。

```
vault_postgres_superuser_password   vault_postgres_replicator_password
vault_postgres_app_password         vault_pgbouncer_auth_password
vault_pgbouncer_admin_password      vault_patroni_restapi_password
vault_rabbitmq_admin_password       vault_rabbitmq_app_user_password
vault_rabbitmq_erlang_cookie        vault_keydb_password
vault_vrrp_pass_svc  vault_vrrp_pass_egress  vault_vrrp_pass_pg  vault_vrrp_pass_mq
    （↑ VRRPv2 PASS 驗證只取前 8 字元，超長會被靜默截斷——請直接產 8 字元）
vault_app_jwt_secret                vault_app_encryption_key
vault_microsoft_client_secret       vault_sendgrid_api_key
vault_grafana_admin_password        vault_pgbackrest_cipher_pass
vault_gitlab_root_password
```

## 7. 全域開關 / 共用變數（`group_vars/all/vars.yml`）

| 變數 | prod | lab | 意義 |
|---|---|---|---|
| `domain` | ptc-nec.com.tw | 同 | 內部網域 |
| `is_container` | false | **true** | lab 容器內跳過 kernel 級 sysctl / swapoff / 磁碟分割 |
| `use_egress_proxy` | true | **false** | 主機層 apt/docker/env 是否經 Squid（lab 直連 NAT；Squid 仍會部署並驗證） |
| `manage_etc_hosts` | true | 同 | ADR-5：名稱解析由 Ansible 管 /etc/hosts |
| `service_vip` / `egress_vip` | 10.20.10.10 / .20 | 同 | |
| `pgbouncer_vip` / `rabbitmq_vip` | 10.20.30.10 / .20 | 同 | |
| `app_http_port` / `app_smtp_port` | 8080 / 2525 | 同 | |
| `internal_ca_host` | `groups['monitoring'][0]` | 同 | 簽發委派對象 |

**Lab 降規**（`inventories/lab/group_vars/` 覆寫）：PG `shared_buffers=128MB`、KeyDB
`maxmemory=256mb`、RabbitMQ watermark 0.4、Prometheus retention 2d 等。**拓撲絕不降規**（節點數、
VIP、TLS、quorum 與 prod 完全一致——lab 的目的就是驗證拓撲）。

## 8. Role 撰寫規範

1. 每個 role 必有：`defaults/main.yml`（所有可調參數 + 註解）、`tasks/main.yml`、
   `handlers/main.yml`（如需 restart）、`meta/main.yml`；template 放 `templates/*.j2`。
2. **冪等**：重跑 0 changed（首次部署除外）。`command/shell` 必配 `creates`/`changed_when`/條件檢查。
3. 模組**一律用 FQCN**（`ansible.builtin.apt`、`community.crypto.x509_certificate`…）。
4. 註解量：每個非自明 task 上方**必須**有「為什麼」的中文註解（不是翻譯 task name）。
5. 機密檔案 `mode: "0600"`、`no_log: true` 用於含密碼的 task。
6. handler 名稱格式：`restart <service>`；服務變更用 notify，不在 task 內直接 restart。
7. 滾動變更（haproxy/keepalived/patroni）playbook 層用 `serial: 1`。
8. 介面偵測：keepalived/haproxy 綁 VIP 的網卡**不可寫死 `ens160`**，由
   role 內以「哪張網卡的 IPv4 與 VIP 同網段」自動偵測（可用變數覆寫）。

## 9. 部署順序依賴（site.yml）

```
00-bootstrap → 10-pki → { 20-storage, 30-postgres, 31-rabbitmq, 32-keydb } → 40-lb → 41-egress
                                            ↓
                                50-app（依賴 20/30/31/32/40 全就緒）→ 60-monitoring → 99-verify
70-gitlab 獨立（僅依賴 00/10）
```
