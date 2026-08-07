# gitlab/ — CI/CD 模板與管線說明

本目錄存放全公司共用的 GitLab CI 模板。infra monorepo 自己的管線在 repo 根的
[`.gitlab-ci.yml`](../.gitlab-ci.yml)（lint → validate → plan → apply，GitOps 核心流程）。

## 模板一覽

| 檔案 | 給誰用 | 內容 |
|---|---|---|
| `ci-templates/docker-build.gitlab-ci.yml` | 所有要建映像的 repo | kaniko 無特權建映像（無 DinD/privileged）、內部 CA 注入、SHA + semver tag、registry layer cache。提供 `.kaniko-build`（extends 用）與現成 `build-image` job |
| `ci-templates/backend.gitlab-ci.yml` | Go 後端 repo（K8s） | go vet + `go test -race` → build → kaniko image → bump gitops repo 的 kustomize image tag → ArgoCD 自動同步 |
| `ci-templates/frontend.gitlab-ci.yml` | Node 前端 repo（K8s） | lint / test → build（dist/）→ kaniko image → bump gitops image tag（同上） |
| `ci-templates/compose-app.gitlab-ci.yml` | VM+Compose 型專案 repo（如 email_proxy） | test → build → 三映像（api/worker/smtp）推 registry → Trigger API 觸發本 infra repo 的 `ansible-deploy-app`（ADR-6） |

## Repo 佈局建議（誰 include 誰、誰部署誰）

```text
GitLab CE（gitlab.ptc-nec.com.tw，VLAN 50）
│
├── infra/onpremis-gitops          ← 本 monorepo（GitOps 唯一事實來源）
│   ├── .gitlab-ci.yml               ← lint → validate → plan → apply
│   │                                   · terraform plan/apply（GitLab TF state）
│   │                                   · ansible check/deploy（manual, main）
│   │                                   · ansible-deploy-app（Trigger API 專用）
│   ├── gitlab/ci-templates/*.yml    ← 各 app repo 用 include: project 引用
│   ├── argocd/                      ← ArgoCD 監看的 K8s manifests（kustomize）
│   ├── ansible/、terraform/
│   │
│   │   include: project=infra/onpremis-gitops, file=gitlab/ci-templates/...
│   ├──────────────┬─────────────────────┬──────────────────────┐
│                  │                     │                      │
├── apps/web-backend            apps/web-frontend      apps/<compose 專案>
│   （backend 模板）             （frontend 模板）       （compose-app 模板）
│        │ push image                │ push image            │ push image
│        ▼                           ▼                       ▼
│   registry.ptc-nec.com.tw:5050（Container Registry）
│        │                           │                       │
│        │ bump kustomize tag        │ bump kustomize tag    │ Trigger API
│        ▼                           ▼                       ▼   （APP_IMAGE_TAG）
│   infra repo argocd/k8s/web-backend|web-frontend      infra repo pipeline
│        │                                                    │
│        ▼  ArgoCD pull 同步                                  ▼  ansible-playbook
│   K8s 叢集                                            playbooks/50-apps.yml
│                                                        （app VM 滾動更新）
│
└── Runner：runner-01（docker executor，tag: onprem-docker）
```

兩條部署路徑，一個原則——**CI 不直接碰目標環境**：

- **K8s 應用**：CI 只 push 映像 + commit gitops repo；ArgoCD（pull-based）負責同步。
- **VM+Compose 型專案（如 email_proxy）**：CI 只 push 映像 + 觸發 infra 管線；
  SSH 金鑰 / vault 密碼只存在 infra repo 的 CI context（ADR-6，權限最小化）。

## 各 repo 需要設定的 CI/CD 變數

| Repo | 變數 | 型別 | 用途 |
|---|---|---|---|
| infra monorepo | `SSH_PRIVATE_KEY` | File, Protected | Ansible 部署帳號私鑰（結尾保留換行） |
| infra monorepo | `SSH_KNOWN_HOSTS` | File, Protected | `ssh-keyscan -H` 產出的主機指紋 |
| infra monorepo | `ANSIBLE_VAULT_PASS_FILE` | File, Protected | prod vault 密碼（對應 `prod@.vault_pass`） |
| 前後端 app repo | `GITOPS_PUSH_USER` / `GITOPS_PUSH_TOKEN` | Masked, Protected | gitops repo 的 Project Access Token（`write_repository`；Deploy Token 唯讀、不能 push） |
| 各 compose 專案 app repo | `INFRA_PROJECT_ID` / `INFRA_TRIGGER_TOKEN` | Masked, Protected | infra repo 的 Pipeline trigger token |
| instance / group 層 | `INTERNAL_CA_PEM` | File | 內部 Issuing CA chain（kaniko 推 registry、curl 打 API 驗 TLS 用） |

其餘細節（為什麼用 kaniko、TF http backend 變數、token 權限、CA 注入兩種作法）
都以註解形式寫在對應的 YAML 檔內——**模板即文件**。
