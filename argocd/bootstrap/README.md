# ArgoCD Bootstrap（App-of-Apps 模式）

本目錄負責「把 ArgoCD 本身裝進叢集，並種下第一顆種子（root Application）」。
種子種下之後，其餘一切（AppProject、各應用 Application、K8s manifests）
全部由 Git 驅動 —— 這就是 GitOps：**Git 是唯一事實來源（Single Source of Truth）**。

```text
argocd/
├── bootstrap/            # 你在這裡。唯一需要「手動 kubectl/helm」的地方
│   ├── README.md         # 本文件：安裝三步驟 + 離線映像搬運註記
│   ├── values-argocd.yaml# argo-cd Helm chart 的地端客製 values
│   └── root-app.yaml     # App-of-Apps 的 root Application（種子）
├── projects/             # AppProject：安全邊界（root app 自動同步）
├── apps/                 # 各應用的 Application 定義（root app 自動同步）
└── k8s/                  # 各應用的 Kustomize manifests（各 Application 自動同步）
```

---

## 架構邊界（對應 ADR-4，務必先讀）

> **email_proxy 本體「不在」K8s 裡。**
>
> email_proxy 跑在獨立 VM 上（Docker Compose），由本 repo 的 `ansible/`
> 目錄以 Ansible 管理其生命週期（部署、憑證、更版）。
> 原因（ADR-4 決策摘要）：
> 1. SMTP 出口需要固定來源 IP 供對外白名單，VM 比 K8s LoadBalancer/NodePort 單純可控；
> 2. email_proxy 與平台叢集的故障域要分離 —— 叢集掛了，郵件通道不能跟著掛；
> 3. 其流量模式（長連線、佇列落地）對 K8s 的滾動更新語意沒有增益。
>
> 因此：**ArgoCD / 本 `argocd/` 目錄只管平台 K8s 上的工作負載
> （web-frontend / web-backend），永遠不要把 email_proxy 的部署塞進來。**
> 兩者唯一的交集是同一個 GitLab（gitlab.ptc-nec.com.tw）與同一個
> registry（registry.ptc-nec.com.tw:5050）。

---

## 前置條件

| 項目 | 說明 |
| --- | --- |
| K8s 叢集 | 平台叢集 kubeconfig 已就緒，`kubectl` 可操作 |
| Ingress Controller | ingress-nginx 已安裝（本環境不提供 LoadBalancer，見 values 註解） |
| 內部 CA | 內部 CA 憑證鏈（PEM）在手上 —— GitLab/Registry/ArgoCD UI 的 TLS 都由它簽 |
| Helm | v3.x |
| Git 憑證 | GitLab 上供 ArgoCD 唯讀拉取 gitops repo 的 deploy token / PAT |

## 離線環境映像搬運註記（air-gapped）

地端叢集節點**不能**直連 quay.io / ghcr.io，所有映像必須先搬進內部 registry。
在一台可同時連外網與內部 registry 的中繼機上執行（版本以實際安裝的 chart 對應為準）：

```bash
# 1. 查出該 chart 版本用到的所有映像
helm template argocd argo/argo-cd -f values-argocd.yaml \
  | grep 'image:' | sort -u

# 2. 逐一搬運（也可改用 skopeo copy，免 docker daemon）
docker pull quay.io/argoproj/argocd:v2.13.3
docker tag  quay.io/argoproj/argocd:v2.13.3 \
            registry.ptc-nec.com.tw:5050/mirror/quay.io/argoproj/argocd:v2.13.3
docker push registry.ptc-nec.com.tw:5050/mirror/quay.io/argoproj/argocd:v2.13.3
# redis（HA 模式另需 haproxy）同理搬運：
#   public.ecr.aws/docker/library/redis:<tag>
#   → registry.ptc-nec.com.tw:5050/mirror/library/redis:<tag>
```

`values-argocd.yaml` 已把 `global.image.repository` 指向內部 mirror 路徑，
搬完映像即可離線安裝。

---

## 安裝三步驟

### 步驟 1：建立 argocd namespace

```bash
kubectl create namespace argocd
```

### 步驟 2：以 Helm 安裝 ArgoCD（帶入地端 values）

```bash
# 有外網的環境先加 repo；離線環境請改用事先下載的 chart tgz
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.11 \
  -f values-argocd.yaml
```

`values-argocd.yaml` 重點（詳見檔內逐行註解）：

- **不用 LoadBalancer**：地端沒有雲廠商 LB，`server.service` 維持 ClusterIP，
  對外一律走 ingress-nginx（`server.ingress.*`）。
- **`server.insecure: true`**：TLS 由 Ingress 終結，ArgoCD server 本身走 HTTP，
  避免 Ingress ↔ ArgoCD 之間的雙重 TLS 與 gRPC 憑證問題。
- **內部 CA**：`configs.tls.certificates` 把內部 CA 簽的 GitLab 憑證鏈餵給
  ArgoCD，否則 repo-server 拉 `https://gitlab.ptc-nec.com.tw` 會 x509 失敗。
- **repo 憑證**：以 `argocd.argoproj.io/secret-type=repository` 的 Secret
  宣告（token 不進 Git，見 values 內註解與下方指令）。
- **HA 模式**：預留註解（controller/repo-server 副本數、redis-ha），
  單叢集起步先跑單副本，量大再開。

安裝後建立 repo 憑證 Secret（token 絕不 commit 進 Git）：

```bash
kubectl -n argocd create secret generic repo-gitops \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.ptc-nec.com.tw/platform/gitops.git \
  --from-literal=username=argocd-readonly \
  --from-literal=password='<GitLab deploy token>'
kubectl -n argocd label secret repo-gitops argocd.argoproj.io/secret-type=repository
```

取得初始 admin 密碼、確認 UI 可登入（https://argocd.ptc-nec.com.tw）：

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 步驟 3：種下 root Application（App-of-Apps 種子）

```bash
kubectl apply -n argocd -f root-app.yaml
```

root app 是**唯一**手動 apply 的 Application。它以 multi-source 同時指向
`argocd/projects/`（AppProject 安全邊界）與 `argocd/apps/`（各應用的
Application），之後任何新應用只要往 `argocd/apps/` 加一個 YAML 並 push，
ArgoCD 就會自動收編 —— 不再需要任何 kubectl。

```text
root-app ──sync──> projects/platform.yaml   (AppProject：安全邊界)
         └─sync──> apps/web-frontend.yaml ──sync──> k8s/web-frontend/overlays/prod
                   apps/web-backend.yaml  ──sync──> k8s/web-backend/overlays/prod
```

---

## 驗證

```bash
# Application 全數 Synced / Healthy 即成功
kubectl -n argocd get applications

# manifests 靜態驗證（CI 也跑同一條）：
cd <repo 根目錄>
docker run --rm -v $PWD/argocd:/manifests \
  ghcr.io/yannh/kubeconform:latest \
  -strict -ignore-missing-schemas -summary /manifests
```

## 與 CI 的關係（tag bump 流程）

應用映像 tag **不由人手改**：`gitlab/ci-templates` 的 bump job 會在應用
repo 出新版後，對本 repo 執行
`cd argocd/k8s/<app>/overlays/prod && kustomize edit set image ...`
並 commit push；ArgoCD 偵測到新 commit 即自動同步（automated + selfHeal）。
詳見各 `overlays/prod/kustomization.yaml` 的 `images:` 段註解。
