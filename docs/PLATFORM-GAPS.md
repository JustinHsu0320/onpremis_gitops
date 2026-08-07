# 地端基礎平台缺口分析與補齊路線圖

> 2026-08 平台化改造時的專業盤點：以「多專案共用地端平台」的完整度為基準，
> 現有組件（邊界 HA、Kong、資料層 quorum ×4、NFS、SeaweedFS S3、PKI、監控、
> GitLab、Terraform/vSphere）之外還缺什麼、為什麼會痛、建議選型與落點。
> 優先級：**P0 = 不補有明顯運營風險 / P1 = 多專案化後很快會需要 / P2 = 成熟度提升**。

## 總表

| 級 | # | 缺口 | 主推選型 | 備選 | 落點 / 資源 |
|---|---|---|---|---|---|
| P0 | 1 | 告警通知落地 + 監控自監控 | Alertmanager email/webhook + ntfy + deadman switch | Grafana Alerting | mgmt-01（零新 VM） |
| P0 | 2 | 集中式日誌（現在只有 metrics！） | Grafana Loki + Alloy | VictoriaLogs + vector | VLAN 99 / log-01（4c/8G/500G） |
| P0 | 3 | 備份完整性（Scylla/SeaweedFS/GitLab/mgmt-01）+ DR 文件 | restic（S3 後端 = SeaweedFS）+ 原生工具 timer | BorgBackup | 既有 nfs-01 / SeaweedFS + 異地 |
| P1 | 4 | 內部 DNS（/etc/hosts 的天花板） | CoreDNS ×2 + VIP（zone 檔由 inventory 產生） | PowerDNS | 同居 lb（零新 VM）或 VLAN 99 |
| P1 | 5 | 機密管理 | OpenBao（Raft ×3；Vault 本尊已改 BUSL，商用地端跳過） | Infisical | VLAN 99 / bao-01..03（2c/2G） |
| P1 | 6 | SSO / IdP | Keycloak（DB 用既有 Patroni PG） | Authentik | VLAN 50 / sso-01（4c/8G） |
| P1 | 7 | apt / 映像快取代理（封閉供應鏈） | apt-cacher-ng + Harbor proxy cache | GitLab dependency proxy | VLAN 50 / harbor-01 同居 |
| P1 | 8 | 映像與漏洞掃描 | Harbor（內建 Trivy）；CI 內 Trivy job 先行 | Grype/Syft | VLAN 50 / harbor-01（4c/8G/500G） |
| P1 | 9 | K8s 叢集實作（VLAN 60 目前只是 ArgoCD 藍圖） | RKE2（airgap 一級公民）+ kube-vip | kubeadm | VLAN 60 / 3 cp + 2-3 worker |
| P1 | 10 | mgmt-01 故障域集中 | 觀測性拆到 log-01 是第一刀；Issuing CA 納入 restic + 重建 runbook | — | VLAN 99 |
| P2 | 11 | 分散式追蹤 / OTel | OTel Collector + Tempo（後端存 SeaweedFS S3） | Jaeger | 同居 log-01 |
| P2 | 12 | IPAM / 資產對帳 | NetBox（先做 hosts.yml ↔ terraform ↔ NetBox 三方 diff CI） | phpIPAM | VLAN 50，可同居 |
| P2 | 13 | 跳板 / 特權存取稽核 | 強化 bastion + tlog session 錄影 → Loki | JumpServer（Teleport CE 有 100 人商用限制） | VLAN 99 |
| P2 | 14 | 憑證自動化演進 | step-ca（ACME 前端接既有 Issuing CA；pki_certificates 資料結構可直翻） | OpenBao PKI engine | mgmt-01 同居 |
| P2 | 15 | 狀態頁 | Gatus（config-as-code，貼合 GitOps 紀律） | Uptime Kuma（UI 操作=drift，與哲學相斥） | 容器 |
| P2 | 16 | 帶外/實體層監控（IPMI、UPS、vSphere datastore） | ipmi_exporter + NUT + telegraf vsphere | govc 排程 | mgmt-01 同居 |

## P0 重點說明

**P0-1 告警通知**：`alertmanager.yml.j2` 現在是 `ops-null` receiver——全部 critical
告警（PatroniClusterNoLeader、ProbeFailed…）觸發後**沒有任何人會收到**。補 email +
ntfy 推播是「工作量最小、風險消除最大」的一項；另補 deadman switch（一條永遠
firing 的 Watchdog 送自架 Healthchecks）解決「監控本身死了沒人知道」。

**P0-2 集中式日誌**：GitOps 紀律禁止隨意 SSH，但排障目前只能逐台 `journalctl`；
多專案後「哪個專案打爆 PG」沒有日誌關聯查不了；節點死亡時本機日誌陪葬。
Loki + Alloy 與既有 Grafana 無縫；label 契約建議 `project/component/host` 三鍵
（正是 projects 登記簿的查詢主鍵）。不建議 ELK（16GB lab 驗不動）。

**P0-3 備份完整性**：repo 自己記錄的債——Scylla 快照策略 TODO、GitLab backup
runbook TODO（GitLab 死 = 全公司 Git + registry + **Terraform state** 一起消失）、
mgmt-01 的 Issuing CA 私鑰無自動化備份；SeaweedFS 上線後同類。restic 以 SeaweedFS
S3 當後端正好閉環；每個備份 timer 推 metrics + `BackupTooOld` 告警——
「沒演練過的備份 = 沒有備份」延伸為「沒監控的備份 = 沒有備份」。

## 建議補齊順序（考量 16GB lab 可驗證性）

| 波次 | 內容 | 產出判準 |
|---|---|---|
| W1（天級） | P0-1 告警通道 + deadman + Gatus；Scylla snapshot / GitLab backup timer | 殺一台 pg 容器 → 手機收到推播 |
| W2 | P0-2 Loki + Alloy（lab 同居 mgmt；prod 才開 log-01） | lab 內 logcli 查得到全 21 節點 journald |
| W3 | P1-4 CoreDNS（同居 lb）+ `manage_etc_hosts=false` 切換演練 | DNS 模式下 99-verify 全綠——多專案化的基石 |
| W4 | P1-5 OpenBao ×3 + 第一批機密遷移；P0-3 restic 全機鋪開 | 密碼輪替不再全量 site.yml |
| W5 | P1-6 Keycloak + Grafana/GitLab/ArgoCD 接 OIDC | 一個帳號登入兩系統；離職=停一個帳號 |
| W6 | P1-7/8 apt-cacher-ng + Trivy in CI；Harbor（僅 prod，循 gitlab 前例） | CVE CRITICAL 擋 pipeline |
| W7 | P1-9 RKE2 @ VLAN 60；lab 用獨立 k3d profile 驗 ArgoCD 鏈 | ArgoCD 藍圖第一次 sync 到真叢集 |
| W8+ | P2 群：OTel 契約先寫進 CONVENTIONS（零成本）→ 其餘依專案數成長逐項上 | — |

## 授權雷區備忘（地端商用）

- HashiCorp Vault → 已改 BUSL，用 **OpenBao**（MPL-2.0，Linux Foundation）。
- Kong OSS 的官方 OIDC plugin 是 **enterprise-only**——SSO 上 Kong 前先驗證第三方
  kong-oidc plugin，或屆時評估 Apache APISIX（OIDC 內建）。
- Teleport CE 自 2024 起限制 100 人以上公司商用；Boundary 是 BUSL。
- MinIO 社群版已 archive（本平台已改用 SeaweedFS，Apache-2.0）。
- Loki/Tempo 為 AGPLv3：內部使用、不對外提供服務，無傳染疑慮。

## 貫穿性原則

每個新組件 = inventory 群組 + group_vars（含 pki_certificates）+ site.yml 階段 +
99-verify tag + Prometheus target + lab 節點 + terraform VM——這「七件套」已是
repo 的既有模式（CONVENTIONS §10.5 onboarding 清單同構），照抄即可。
