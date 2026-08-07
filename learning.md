# 🗺️ 地端 Terraform × Ansible × GitOps (GitLab) 學習地圖

> **對象**：Junior 架構師（能讀懂本專案程式碼，希望掌握最關鍵的 20% 知識來推動 80% 的日常工作）
>
> **範圍**：完全基於本 `onpremis_gitops` monorepo 的實際技術棧——
> Terraform (vSphere provider)、Ansible (22 roles, vault, lab)、
> GitLab CI/CD (4-stage pipeline, ci-templates, kaniko)、ArgoCD (App-of-Apps)

---

## 目錄

| 階段 | 主題 | 對應專案目錄 |
|---|---|---|
| [§0](#§0-心法gitops-紀律) | 心法：GitOps 紀律 | `.gitlab-ci.yml` 檔頭、README §2 |
| [§1](#§1-terraform--iac-基礎) | Terraform / IaC 基礎 | `terraform/` |
| [§2](#§2-ansible--組態管理) | Ansible / 組態管理 | `ansible/` |
| [§3](#§3-gitlab-cicd-管線) | GitLab CI/CD 管線 | `.gitlab-ci.yml`、`gitlab/ci-templates/` |
| [§4](#§4-argocd--kubernetes-gitops) | ArgoCD / K8s GitOps | `argocd/` |
| [§5](#§5-整合觀串起四層的-20-黏合劑) | 整合觀：串起四層的 20% 黏合劑 | 全 repo |
| [§6](#§6-推薦學習資源) | 推薦學習資源（影片＋文件） | — |

---

## §0. 心法：GitOps 紀律

> 本專案的核心信仰（見 [`.gitlab-ci.yml`](.gitlab-ci.yml) L2-L24 與 [README](README.md) §2）：
> **任何變更都從 Git 開始。禁止 SSH 進機器手改。**

### 你必須內化的 20%

| # | 知識點 | 為什麼重要（對照本專案） |
|---|---|---|
| 0-1 | **宣告式 vs 命令式** | Terraform / Ansible 都是宣告式——你描述「期望狀態」，工具負責收斂。本專案所有 role 追求冪等（重跑 `changed=0`） |
| 0-2 | **plan → review → apply** | `.gitlab-ci.yml` 的四段管線（lint → validate → plan → **manual** apply）就是這個紀律的落地 |
| 0-3 | **唯一事實來源 (Single Source of Truth)** | 本專案的 IP/VLAN 唯一事實來源是 `inventories/prod/hosts.yml`（ADR-1），Terraform 照抄它 |
| 0-4 | **Monorepo vs Polyrepo** | 本 repo 把 Terraform/Ansible/ArgoCD/CI 模板全放一起——改一個 MR 跨層 review |
| 0-5 | **機密零落地** | vault 密文進 Git、`.vault_pass` 不進 Git、CI 用 Protected File variables |

### 🤔 反問自己

> 1. 你能用一句話解釋「宣告式」和「命令式」的差異嗎？如果有人把 `apt install` 寫在 Ansible 的 `shell` module 裡，你會怎麼建議他改？
> 2. 本專案的 `apply` 階段為什麼一定設成 `when: manual`？如果改成自動，最壞情況會發生什麼？
> 3. 如果有人在 `main.tf` 裡硬寫了一個 IP 地址而不是引用 `hosts.yml` 的變數，會違反哪條原則？會造成什麼後果？
> 4. Monorepo 對 code review 有什麼好處？又有什麼壞處（hint: 想想大型專案的 CI 觸發）？
> 5. 如果一個 junior 把 `.vault_pass` 推上了 Git，你的應急處理 SOP 是什麼？（提示：rekey）

---

## §1. Terraform / IaC 基礎

> 對應目錄：[`terraform/`](terraform/) — 本專案用 **vSphere provider** 管理 VMware 環境

### 1.1 最關鍵的 20% 概念

| # | 知識點 | 對照本專案 | 必讀檔案 |
|---|---|---|---|
| 1-1 | **HCL 語法基礎**：`resource`、`data`、`variable`、`output`、`locals` | `main.tf` 裡 18 台 VM 全用 `locals` + `module` 組裝 | [`main.tf`](terraform/environments/prod/main.tf) |
| 1-2 | **Provider 機制** | 本專案用 `hashicorp/vsphere`，連 vCenter API 建 VM/port group | [`providers.tf`](terraform/environments/prod/providers.tf) |
| 1-3 | **Module 拆分** | `modules/vm`、`modules/network`、`modules/anti_affinity` 三個可重用模組 | [`terraform/modules/`](terraform/modules/) |
| 1-4 | **State 管理** | `backend "http" {}` 空宣告 + CI 用 `TF_HTTP_*` 環境變數注入 GitLab-managed state | [`backend.tf`](terraform/environments/prod/backend.tf) |
| 1-5 | **`plan` → `apply` 工作流** | CI 產出 `tfplan` artifact → 人工審閱 → manual apply 消費同一份 plan | `.gitlab-ci.yml` L200-L275 |
| 1-6 | **`terraform fmt` + `validate`** | CI validate 階段 + `make tf-validate` 本機等效 | [`Makefile`](Makefile) L40-43 |
| 1-7 | **Variables + tfvars** | 憑證用環境變數（`TF_VAR_*`）；規格用 `.tfvars`（範例檔進 Git，真檔不進） | [`variables.tf`](terraform/environments/prod/variables.tf)、[`terraform.tfvars.example`](terraform/environments/prod/terraform.tfvars.example) |

### 1.2 本專案特有的模式

```text
terraform/
├── environments/prod/   ← 環境層：main.tf（18 台 VM 清單）、backend、provider、variables
│   └── templates/       ← cloud-init userdata 模板
└── modules/
    ├── network/         ← vDS port group × 6 VLAN
    ├── vm/              ← clone template + cloud-init + 資料碟（PVSCSI 控制器分離）
    └── anti_affinity/   ← 5 組反親和規則（should vs must）
```

**重點模式**：
- **cloud-init = Ansible 的起點**：VM 開機就有 `ansible` 使用者 + SSH 公鑰 + `NOPASSWD` sudoers
- **資料碟設計**：PG 節點 data/WAL/etcd 各一個獨立 PVSCSI 控制器（IO 不互搶）
- **`independent_persistent`**：資料碟排除在 VM 快照外、`terraform destroy` 不刪

### 🤔 反問自己

> 1. `terraform plan` 和 `terraform apply` 的輸出各代表什麼？為什麼本專案的 CI 要把 plan 結果存成 artifact 而不是 apply 時重新 plan？
> 2. 本專案的 `backend "http" {}` 為什麼「刻意留空」？如果你把 address 寫死在裡面，換 GitLab 域名時要改幾個地方？
> 3. `locals` 和 `variable` 的差別是什麼？為什麼 18 台 VM 的定義放在 `locals` 而不是 `variable`？
> 4. 什麼是 Terraform state？如果兩個人同時 `terraform apply` 而沒有 state lock，會發生什麼？本專案用什麼機制防止這個？（提示：看 `TF_HTTP_LOCK_*` + `resource_group`）
> 5. 反親和規則用 `mandatory=false`（should）而非 must，在什麼情境下你該改成 must？改了之後最壞會怎樣？

---

## §2. Ansible / 組態管理

> 對應目錄：[`ansible/`](ansible/) — 22 個 roles、16 個 playbooks、lab 實驗室

### 2.1 最關鍵的 20% 概念

| # | 知識點 | 對照本專案 | 必讀 |
|---|---|---|---|
| 2-1 | **Inventory**（hosts.yml） | `inventories/prod/hosts.yml` 定義所有群組與主機 | [`inventories/`](ansible/inventories/) |
| 2-2 | **Playbook 結構**：`hosts`、`roles`、`tasks`、`handlers` | `site.yml` import 15 個階段 playbook，每個指定 hosts 群組 + roles | [`site.yml`](ansible/playbooks/site.yml) |
| 2-3 | **Role 結構**：`defaults/`、`tasks/`、`templates/`、`handlers/`、`meta/` | 22 個 role 各司其職（common → pki → 服務 → verify） | [`roles/`](ansible/roles/) |
| 2-4 | **Jinja2 模板** | 所有設定檔都是 `.j2` 模板，引用 inventory 變數渲染 | roles 內的 `templates/` |
| 2-5 | **group_vars / host_vars** | `group_vars/all/vars.yml` 放明文變數，`vault.yml` 放機密 | [`inventories/prod/group_vars/`](ansible/inventories/prod/) |
| 2-6 | **ansible-vault** | 加密機密變數；`vault_identity_list` 多把鑰匙管多環境 | [`ansible.cfg`](ansible/ansible.cfg) L27 |
| 2-7 | **冪等性 (Idempotency)** | 重跑 `site.yml` 必須 `changed=0`——本專案踩雷 #13 就是在修非冪等問題 | README §17 |
| 2-8 | **`ansible.cfg` 關鍵設定** | `pipelining=True`（速度 2-5 倍）、`host_key_checking=True`（安全）、`forks=10` | [`ansible.cfg`](ansible/ansible.cfg) |
| 2-9 | **Collections** | 6 個 collection（docker/crypto/posix/general/postgresql/rabbitmq） | [`requirements.yml`](ansible/requirements.yml) |
| 2-10 | **`--check --diff`** | Ansible 版的 `terraform plan`：CI 的 `ansible-deploy-check` job | `.gitlab-ci.yml` L224-245 |

### 2.2 本專案的 Playbook 依賴鏈

```text
00-bootstrap (common)
  └─ 05-block-storage → 08-docker → 10-pki
       ├─ 20-storage (NFS)
       ├─ 30-postgres (Patroni + etcd + PgBouncer + HAProxy + Keepalived)
       ├─ 31-rabbitmq
       ├─ 32-keydb
       ├─ 33-scylladb
       ├─ 40-lb → 41-egress
       └─ 50-app → 60-monitoring → 70-gitlab → 99-verify
```

### 2.3 本專案特有的模式

| 模式 | 說明 | 範例 |
|---|---|---|
| **階段式 playbook** | `site.yml` → `00-bootstrap.yml` → `30-postgres.yml` → ... 可整體跑也可單獨跑 | `ansible-playbook playbooks/30-postgres.yml` |
| **CONVENTIONS.md 契約** | 跨 role 的變數名/埠號/路徑/PKI 約定——改契約先改文件再改程式碼 | [`CONVENTIONS.md`](ansible/CONVENTIONS.md) |
| **lab symlink** | lab inventory 的拓撲 symlink 到 prod = 驗證的就是部署的 | ADR-12 |
| **vault 別名模式** | `vault.yml` 存 `vault_xxx_pass`，`vars.yml` 存 `xxx_pass: "{{ vault_xxx_pass }}"`，role 用 `xxx_pass` | README §11 |
| **PKI 橋接 task** | `pki_certs_changed` host fact 讓 TLS 服務自動 reload | README §6 |
| **serial: 1 滾動** | 資料層更新一台一台來，搭配 verify 確認健康 | README §15.3 |

### 🤔 反問自己

> 1. `ansible-playbook --syntax-check` 和 `ansible-lint` 各檢查什麼？為什麼 CI 兩個都跑？
> 2. 為什麼 `ansible.cfg` 的 `inventory` 預設指向 `prod` 而不是 `lab`？（提示：防呆方向——看 ansible.cfg L6-L8 的註解）
> 3. 什麼是 handler？它跟 task 的差別在哪？為什麼 handler 適合用來 reload 服務？
> 4. 如果你要在 Jinja2 模板裡列出所有 `postgres` 群組的 IP，你會怎麼寫？（提示：`groups['postgres']` + `hostvars`）
> 5. `pipelining = True` 為什麼能加速？它的先決條件是什麼？（提示：sudoers 的 `requiretty`）
> 6. 什麼是 `--check --diff`？本專案的 `ansible-deploy-check` job 為什麼設成 `when: manual` 而不是自動跑？
> 7. 為什麼 `vault_identity_list` 要設兩把鑰匙（prod + lab）？如果只設一把，lab 能跑嗎？
> 8. 本專案踩雷 #10（HAProxy 綁 VIP:6432 EADDRINUSE）的根因是什麼？你能從 CONVENTIONS.md §3 找到「埠共存原則」嗎？

---

## §3. GitLab CI/CD 管線

> 對應檔案：[`.gitlab-ci.yml`](.gitlab-ci.yml)、[`gitlab/ci-templates/`](gitlab/ci-templates/)

### 3.1 最關鍵的 20% 概念

| # | 知識點 | 對照本專案 | 必讀 |
|---|---|---|---|
| 3-1 | **`stages` 定義** | 固定四段：`lint → validate → plan → apply` | `.gitlab-ci.yml` L41 |
| 3-2 | **`workflow:rules`** | 控制整條 pipeline 何時觸發：MR / main push / trigger / web | L34-39 |
| 3-3 | **`rules:changes` 分流** | 只動 `terraform/**` 只跑 terraform jobs（monorepo 基本禮貌） | L88-101, YAML anchor |
| 3-4 | **YAML anchor (`&`) + alias (`*`)** | `.paths-ansible: &paths-ansible` 定義路徑清單，多處 `changes: *paths-ansible` 引用 | L88-101 |
| 3-5 | **hidden key (`.xxx`)** | 以 `.` 開頭的 key 不會被當 job（純定義用） | `.ansible-base`、`.rules-*` |
| 3-6 | **`extends` 繼承** | `ansible-lint` extends `[.ansible-base, .rules-ansible-auto]` 同時繼承工具鏈和觸發規則 | L151-155 |
| 3-7 | **`needs` + `artifacts`** | `terraform-apply` needs `terraform-plan` → 下載 plan artifact | L269 |
| 3-8 | **`when: manual`** | apply 階段一律手動——GitOps 紀律的底線 | L264 |
| 3-9 | **`resource_group`** | 同一時間全 GitLab 只允許一個 job 動 `terraform-prod` 的 state | L272 |
| 3-10 | **Pipeline Trigger API** | app repo CI build 完 → curl trigger 本 repo → 跑 `ansible-deploy-app`（ADR-6） | L338-372 |
| 3-11 | **Protected Variables** | `SSH_PRIVATE_KEY`、`ANSIBLE_VAULT_PASS_FILE` 勾 Protected = 只有 main 的 job 拿得到 | README §9.3 |
| 3-12 | **CI 模板 (`include`)** | `gitlab/ci-templates/` 四套模板供應用 repo include（kaniko/Go/前端） | [`gitlab/ci-templates/`](gitlab/ci-templates/) |

### 3.2 本專案的管線全景

```text
MR pipeline:                     main pipeline:
┌──────────┐                    ┌──────────┐
│ lint     │ yamllint            │ lint     │
│          │ ansible-lint        │          │
├──────────┤                    ├──────────┤
│ validate │ tf validate         │ validate │
│          │ ansible --syntax    │          │
│          │ kubeconform         │          │
├──────────┤                    ├──────────┤
│ plan     │ tf plan (artifact)  │ plan     │ + ansible --check --diff (manual)
│          │                    │          │
└──────────┘                    ├──────────┤
    ↑ review → merge →          │ apply ⚠  │ tf apply (manual)
                                │          │ ansible deploy (manual)
                                │          │ ansible-deploy-app (trigger only)
                                └──────────┘
```

### 3.3 CI 模板（供應用 repo 使用）

| 模板 | 用途 | 交付終點 |
|---|---|---|
| [`docker-build.gitlab-ci.yml`](gitlab/ci-templates/docker-build.gitlab-ci.yml) | kaniko 建映像（無需 privileged/DinD） | registry |
| [`email-proxy-app.gitlab-ci.yml`](gitlab/ci-templates/email-proxy-app.gitlab-ci.yml) | Go app → test → build → image → **trigger 部署** | VM (Compose) |
| [`backend.gitlab-ci.yml`](gitlab/ci-templates/backend.gitlab-ci.yml) | Go 後端 → image → **kustomize bump** | K8s (ArgoCD) |
| [`frontend.gitlab-ci.yml`](gitlab/ci-templates/frontend.gitlab-ci.yml) | Node 前端 → image → bump | K8s (ArgoCD) |

### 🤔 反問自己

> 1. 如果沒有 `workflow:rules`，MR 合併時會同時觸發兩條 pipeline（MR pipeline + branch pipeline），這會造成什麼問題？
> 2. `rules:changes` 用了 `**/*` glob，為什麼不用 `*`？（提示：想想子目錄）
> 3. YAML anchor `&` 和 alias `*` 的差別是什麼？本專案用它來避免什麼重複？
> 4. `terraform-apply` 為什麼用 `needs: [terraform-plan]` 而不是靠 stage 的自然順序？（提示：artifact 下載）
> 5. `resource_group: terraform-prod` 和 `TF_HTTP_LOCK_*` 分別防的是什麼？為什麼需要「雙保險」？
> 6. 為什麼 kaniko 比 Docker-in-Docker (DinD) 更適合地端 runner？（提示：privileged mode、安全性）
> 7. `ansible-deploy-app` job 的 `rules` 只接受 `$CI_PIPELINE_SOURCE == "trigger" && $APP_IMAGE_TAG`——這個設計防的是什麼？
> 8. CI variables 設成 `Protected` 和 `Masked` 各有什麼效果？為什麼 `SSH_PRIVATE_KEY`（File 類型）不能 Mask？

---

## §4. ArgoCD / Kubernetes GitOps

> 對應目錄：[`argocd/`](argocd/) — App-of-Apps 模式、kustomize overlay

### 4.1 最關鍵的 20% 概念

| # | 知識點 | 對照本專案 | 必讀 |
|---|---|---|---|
| 4-1 | **ArgoCD 核心概念**：Application + AppProject | `argocd/apps/` 定義 Application，`argocd/projects/` 定義 Project 的白名單 | [`argocd/`](argocd/) |
| 4-2 | **App-of-Apps 模式** | `bootstrap/root-app.yaml` 是根 Application，它指向 `apps/` 和 `projects/` 目錄 | [`bootstrap/root-app.yaml`](argocd/bootstrap/root-app.yaml) |
| 4-3 | **Sync Policy**：`automated` + `prune` + `selfHeal` | 自動同步 + 刪除多餘資源 + 自癒 | `argocd/apps/*.yaml` |
| 4-4 | **Kustomize** | `argocd/k8s/*/base/` + `overlays/prod/` 分層管理 K8s manifests | [`argocd/k8s/`](argocd/k8s/) |
| 4-5 | **Image tag bump** | CI 用 `kustomize edit set image` 改 overlay 的 tag → commit → ArgoCD 自動同步 | `gitlab/ci-templates/backend.gitlab-ci.yml` |
| 4-6 | **Finalizer 安全** | root-app 刻意不加 finalizer：誤刪不級聯刪底下所有資源 | README §10 |
| 4-7 | **AppProject 安全邊界** | `sourceRepos` 白名單 + `destinations` 限縮 + `clusterResource` 最小化 | `argocd/projects/` |

### 4.2 兩條交付路徑

本專案刻意把兩種工作負載分開管理（ADR-4）：

```text
email_proxy（有狀態依賴多）     公司前後端（無狀態 web）
         │                              │
    VM + Compose                   K8s + ArgoCD
         │                              │
 ansible 50-app.yml              kustomize overlay
   serial:1 滾動              ArgoCD automated sync
```

### 🤔 反問自己

> 1. ArgoCD 的「自癒」（selfHeal）是什麼意思？如果有人手動 `kubectl edit` 改了 deployment，ArgoCD 會怎麼做？
> 2. App-of-Apps 模式的好處是什麼？如果不用它，管理 20 個 Application 要怎麼做？
> 3. 為什麼 root-app 不加 finalizer？加了之後「誤刪 root-app」會發生什麼？
> 4. `kustomize edit set image` 改的是哪個檔案？改完之後 ArgoCD 怎麼知道要同步？
> 5. 本專案為什麼把 email_proxy 留在 VM + Compose 而不上 K8s？（提示：NFS、host network、VIP 拓撲）

---

## §5. 整合觀：串起四層的 20% 黏合劑

### 5.1 四層職責對照

| 層 | 工具 | 產出 | 驗證 |
|---|---|---|---|
| L1 機器的存在 | Terraform | 18 台 VM + VLAN | `terraform validate` |
| L2 機器的內容 | Ansible | OS 基線 + 全部服務 | lab 實驗室 `99-verify` |
| L3 VM 上的工作負載 | Docker Compose | app + 快取 + 監控 | lab 實驗室 |
| L4 變更管線 | GitLab CI | lint → validate → plan → apply | YAML 驗證 |
| L5 K8s 應用交付 | ArgoCD | 前後端自動部署 | kubeconform |

### 5.2 必須理解的跨層契約

| 契約 | 來源 | 消費者 | 斷了會怎樣 |
|---|---|---|---|
| cloud-init 建立 `ansible` 使用者 | Terraform `modules/vm` | Ansible 的 SSH 連線 | Ansible 連不上新 VM |
| `hosts.yml` 是唯一事實來源 | 人手維護 | Terraform `main.tf` 照抄 | IP 不一致 → 部署歪掉 |
| PKI leaf cert 有 SAN 含 VIP | `pki_leaf` role | 所有 TLS 服務 | `verify-full` 驗證失敗 |
| `app_image_tag` 觸發變數 | app repo CI trigger | `ansible-deploy-app` job | 部署 job 不會啟動 |
| `CONVENTIONS.md` 埠號契約 | 人類約定 | 每個 role 的 template | 埠衝突 / 防火牆漏開 |

### 5.3 Lab 實驗室 = 你的練功場

```bash
make lab-up        # 起 16 節點（Docker 容器模擬 VM）
make lab-deploy    # 在 mgmt-01 內跑 site.yml（15-20 分鐘）
make lab-verify    # 99-verify 全鏈驗收
make lab-sh        # 進 mgmt-01 改 code 立刻重跑
make lab-destroy   # 銷毀一切
```

### 🤔 反問自己

> 1. 如果 Terraform 建好 VM 但 cloud-init 沒有正確建立 `ansible` 使用者，你要怎麼除錯？（提示：vCenter console）
> 2. 你能畫出「app repo 工程師 push code → email_proxy 節點完成滾動更新」的完整流程嗎？經過哪些系統？
> 3. lab 和 prod 的「已知差異」列在 README §12，其中哪些差異你認為最可能導致「lab 綠但 prod 紅」？
> 4. `CONVENTIONS.md` 為什麼要求「改契約先改文件 → PR review → 再改程式碼」？不這樣做會怎樣？
> 5. 如果你要加一台新的 VM（例如第二台 NFS），你需要改哪些檔案？（至少三個地方）

---

## §6. 推薦學習資源

### 6.1 Terraform

| 類型 | 資源 | 說明 |
|---|---|---|
| 📹 官方入門 | [HashiCorp: Terraform in 15 mins](https://www.youtube.com/watch?v=tomUWcQ0P3k) | 快速理解 init/plan/apply 工作流 |
| 📹 系統課 | [freeCodeCamp: Terraform Course](https://www.youtube.com/watch?v=SLB_c_ayRMo) | 2.5 小時完整入門（provider、module、state） |
| 📹 中文 | [Bilibili: Terraform 从入门到精通](https://www.bilibili.com/video/BV1fj421Z7Mv/) | 中文系統教學，含 vSphere 場景 |
| 📹 State 管理 | [HashiCorp: Remote State](https://www.youtube.com/watch?v=5_A-v9VLSEM) | 理解 state lock、remote backend |
| 📹 Module 設計 | [HashiCorp: Terraform Modules](https://www.youtube.com/watch?v=XsKdtTMR4UE) | 學會拆 module 重用 |
| 📖 官方文件 | [Terraform Docs — Get Started](https://developer.hashicorp.com/terraform/tutorials/aws-get-started) | 動手教程（換成 vSphere provider 即可套用） |
| 📖 vSphere Provider | [vsphere Provider Docs](https://registry.terraform.io/providers/hashicorp/vsphere/latest/docs) | 本專案直接使用的 provider |

### 6.2 Ansible

| 類型 | 資源 | 說明 |
|---|---|---|
| 📹 官方入門 | [Ansible: Getting Started](https://www.youtube.com/watch?v=3RiVKs8GHYQ&list=PLT98CRl2KxKEUHie1m24-wvHBpC0hVVrk) | Jeff Geerling 的經典系列，業界公認最佳 |
| 📹 中文系統 | [Bilibili: Ansible 自动化运维](https://www.bilibili.com/video/BV1HE411w7Bz/) | 中文完整課程，含 role/vault/inventory |
| 📹 Role 最佳實踐 | [Jeff Geerling: Ansible Roles](https://www.youtube.com/watch?v=FaXVZ60o8L8) | 理解 defaults/vars/tasks/handlers/templates |
| 📹 Vault 加密 | [Learn Linux TV: Ansible Vault](https://www.youtube.com/watch?v=JFweg2dUvqM) | ansible-vault 實操教學 |
| 📹 Jinja2 模板 | [Ansible Jinja2 Deep Dive](https://www.youtube.com/watch?v=yR_2K4nNfPE) | 理解 `{{ }}` / `{% %}` / filters |
| 📖 官方文件 | [Ansible Docs — Getting Started](https://docs.ansible.com/ansible/latest/getting_started/index.html) | 必讀官方文件 |
| 📖 最佳實踐 | [Ansible Best Practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html) | 與本專案的 CONVENTIONS.md 對照閱讀 |

### 6.3 GitLab CI/CD

| 類型 | 資源 | 說明 |
|---|---|---|
| 📹 官方入門 | [GitLab CI/CD Tutorial](https://www.youtube.com/watch?v=qP8kir2GUgo) | 從零理解 stages/jobs/runners |
| 📹 中文 | [Bilibili: GitLab CI/CD 从零到部署](https://www.bilibili.com/video/BV1Gy4y1A7FM/) | 中文 CI/CD 管線實作 |
| 📹 進階 | [TechWorld with Nana: GitLab CI](https://www.youtube.com/watch?v=qP8kir2GUgo) | 包含 rules/variables/artifacts/environments |
| 📹 Kaniko | [GitLab: Build Docker images with kaniko](https://www.youtube.com/watch?v=5rVXb6OGnJo) | 理解為什麼不用 DinD（安全） |
| 📖 官方文件 | [GitLab CI/CD Keyword Reference](https://docs.gitlab.com/ee/ci/yaml/) | **必備**：本專案 `.gitlab-ci.yml` 的所有 keyword 都在這裡 |
| 📖 CI Templates | [GitLab CI/CD Templates](https://docs.gitlab.com/ee/ci/examples/) | 學習 include 模板設計 |

### 6.4 ArgoCD & Kubernetes GitOps

| 類型 | 資源 | 說明 |
|---|---|---|
| 📹 入門 | [TechWorld with Nana: ArgoCD Tutorial](https://www.youtube.com/watch?v=MeU5_k9ssrs) | ArgoCD 核心概念 + 實操 |
| 📹 中文 | [Bilibili: ArgoCD 入门与实战](https://www.bilibili.com/video/BV1BG4y1w7Ka/) | 中文 ArgoCD + App-of-Apps |
| 📹 Kustomize | [TechWorld with Nana: Kustomize](https://www.youtube.com/watch?v=Twtbg6LFnAg) | base + overlay 分層設計 |
| 📹 GitOps 理念 | [CNCF: What is GitOps?](https://www.youtube.com/watch?v=f5EpcWp0THw) | 理解 GitOps 的核心原則 |
| 📖 官方文件 | [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) | 官方入門教程 |

### 6.5 綜合 / DevOps 心法

| 類型 | 資源 | 說明 |
|---|---|---|
| 📹 全景 | [TechWorld with Nana: DevOps Bootcamp](https://www.youtube.com/watch?v=0yWAtQ6wYNM) | 3 小時 DevOps 全景（Docker/K8s/CI/IaC） |
| 📹 中文 | [Bilibili: DevOps 工程师学习路线](https://www.bilibili.com/video/BV1vK411N7wV/) | 中文 DevOps 學習路線圖 |
| 📖 經典 | [Google SRE Book（免費線上）](https://sre.google/sre-book/table-of-contents/) | SRE 聖經——理解 toil、SLO、incident management |

---

## §7. 建議學習順序（90 天計畫）

> 80/20 法則：先吃透下表的「必修」，你就能獨立操作本專案 80% 的日常工作。
> 「進階」是當你遇到邊界問題時再深挖。

### Phase 1：第 1-2 週 — 心法 + 動手起 Lab

| 天 | 動作 | 目標 |
|---|---|---|
| 1-2 | 讀完本 `README.md` §1-§4 + `CONVENTIONS.md` | 理解全貌 |
| 3-4 | `make lab-up && make lab-deploy && make lab-verify` | 體感「一鍵部署 16 台」 |
| 5-7 | `make lab-sh` 進 mgmt-01，手動改一個 role 變數 → 重跑 → 觀察 diff | 理解「改 Git → 跑 playbook → 收斂」 |

### Phase 2：第 3-4 週 — Ansible 深入

| 天 | 動作 | 目標 |
|---|---|---|
| 8-10 | 看完 Jeff Geerling 的 Ansible 入門系列前 10 集 | 理解 playbook/role/handler/template |
| 11-12 | 讀 `common` role 和 `pki_leaf` role 的 tasks/main.yml | 學會讀本專案的 role |
| 13-14 | 自己寫一個小 role（例如：在所有節點安裝 htop） | 從模仿到創造 |

### Phase 3：第 5-6 週 — Terraform 基礎

| 天 | 動作 | 目標 |
|---|---|---|
| 15-17 | 看完 freeCodeCamp 的 Terraform 課程 | 理解 HCL / provider / state |
| 18-19 | 讀本專案 `terraform/environments/prod/main.tf` 前 100 行 | 理解 locals + module 呼叫 |
| 20-21 | 用 `make tf-validate` 驗證你的小改動 | 體感 validate 流程 |

### Phase 4：第 7-8 週 — GitLab CI/CD

| 天 | 動作 | 目標 |
|---|---|---|
| 22-24 | 看完一個 GitLab CI/CD 入門影片 + 讀官方 keyword reference | 理解 stages/jobs/rules |
| 25-26 | **逐行讀** `.gitlab-ci.yml`（373 行，每行都有註解） | 理解本專案的完整管線 |
| 27-28 | 讀 `gitlab/ci-templates/docker-build.gitlab-ci.yml` | 理解 kaniko + include 模板 |

### Phase 5：第 9-10 週 — ArgoCD + 整合

| 天 | 動作 | 目標 |
|---|---|---|
| 29-31 | 看完 Nana 的 ArgoCD 入門 + Kustomize 入門 | 理解 sync / selfHeal / overlay |
| 32-33 | 讀本專案 `argocd/` 目錄結構 + `bootstrap/root-app.yaml` | 理解 App-of-Apps |
| 34-35 | 在 lab 裡做一次 failover 演練（`docker stop email-proxy-pg-02`） | 體感 HA 自動切換 |

### Phase 6：第 11-12 週 — 實戰演練

| 天 | 動作 | 目標 |
|---|---|---|
| 36-40 | 模擬完整變更流程：改 vars → MR → CI 跑通 → merge → manual apply | 走完 GitOps 全流程 |
| 41-42 | 練習密碼輪替 runbook（README §15.6） | 理解 vault rekey + 收斂 |
| 43-45 | 練習憑證輪替 runbook（README §15.2） | 理解 PKI 橋接 task |

---

## §8. 速查：本專案用到的工具版本

> 你只需要學這些版本的文件，不用追最新版。

| 工具 | 版本 | 來源 |
|---|---|---|
| Terraform | 1.9 | `.gitlab-ci.yml` L173, `Makefile` L18 |
| vSphere Provider | latest | `versions.tf` |
| Ansible Core | latest (pip install) | `.gitlab-ci.yml` L136 |
| ansible-lint | production profile | `.ansible-lint` |
| yamllint | default rules 延伸 | `.yamllint` |
| Python | 3.12 | CI image `python:3.12` |
| kubeconform | latest-alpine | `Makefile` L19 |
| Docker/kaniko | — | `gitlab/ci-templates/docker-build.gitlab-ci.yml` |

---

> **最後提醒**：本專案 `.gitlab-ci.yml` 的每一行都有中文註解、每個 role 的 `defaults/main.yml`
> 都寫了「為什麼」——**這些註解本身就是最好的教材**。
>
> 當你能獨立完成以下三件事，代表你已經掌握了 20% 的知識：
> 1. ✅ 獨立起 lab → 改 role → 驗證 → 理解 diff
> 2. ✅ 獨立走完一次 MR → CI 管線 → manual apply 的完整 GitOps 流程
> 3. ✅ 獨立讀懂 `.gitlab-ci.yml` 的任何一個 job 在做什麼

