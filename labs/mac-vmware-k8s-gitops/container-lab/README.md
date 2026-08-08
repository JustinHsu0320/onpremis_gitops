# Container Lab：Docker → kind → GitOps

這是一條不依賴 vCenter 的快速整合測試路徑。它使用 kind 建立 1 個
control-plane 與 2 個 worker container，並在 Docker network 內啟動 local
registry，再把只讀 Git daemon 以 Kubernetes Service 執行，讓 Argo CD 可以真的
從 cluster DNS 讀取本 profile 的宣告。

它可以驗證：

- Cilium 與 Kubernetes node readiness
- Argo CD App-of-Apps 與 self-heal/reconciliation
- local registry image promotion 與 Go API probes
- CloudNativePG、Prometheus、Grafana 與 ServiceMonitor
- 1 control-plane + 2 worker 的多節點 scheduling
- Cilium Gateway API、MetalLB Docker network 位址池與 HTTPRoute

它不能取代 VMware/vCenter 的 Terraform apply、SSH host bootstrap、真實
containerd host 設定、Longhorn block device 或實體 LAN 上的 MetalLB ARP。
PostgreSQL 在此 profile 使用 kind 的 `standard` storage class；Longhorn
則刻意不安裝。MetalLB 使用 `172.19.255.200-172.19.255.207`，這是 kind
預設 Docker network 的測試位址池，只能在本機 container lab 使用，不代表
實體 LAN 的 ARP 廣播配置。

CloudNativePG 的 CRD 會在 GitOps bootstrap 前以 server-side apply 安裝，Argo
CD 只同步 operator/workload；這是因為大型 OpenAPI schema 若走傳統
`kubectl apply`，會超過 Kubernetes annotation 大小限制。

## 前置條件

Docker Desktop、`kubectl`、`helm` 與 `kind`。`kind` 可用官方 Go 安裝方式：

```bash
GOBIN=/opt/homebrew/bin go install sigs.k8s.io/kind@v0.32.0
```

## 執行

從 repository root 執行：

```bash
make -C labs/mac-vmware-k8s-gitops/container-lab all
```

或分段執行：

```bash
make -C labs/mac-vmware-k8s-gitops/container-lab up
make -C labs/mac-vmware-k8s-gitops/container-lab platform
make -C labs/mac-vmware-k8s-gitops/container-lab gitops
make -C labs/mac-vmware-k8s-gitops/container-lab verify
```

清理：

```bash
make -C labs/mac-vmware-k8s-gitops/container-lab down
```

測試產物會寫入 `labs/mac-vmware-k8s-gitops/artifacts/container-lab/`，該路徑
已被 `.gitignore` 忽略。
