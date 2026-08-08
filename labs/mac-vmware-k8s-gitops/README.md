# MacBook → VMware → 3-node Kubernetes → GitOps Lab

這個目錄是一條獨立於正式環境的學習路徑，不會改動既有的 21-node 平台拓撲。

- 完整教學：[`LAB-GUIDE.md`](LAB-GUIDE.md)
- 一鍵入口：`make help`
- Terraform：`terraform/`
- Ansible：`ansible/`
- Go API：`apps/go-api/`
- Kubernetes 宣告：`k8s/`
- Argo CD App-of-Apps：`gitops/`
- Docker/kind 快速整合測試：[`container-lab/README.md`](container-lab/README.md)
- 互動教學網站：`site/`

> 最重要的相容性邊界：官方 `vmware/vsphere` Terraform provider 連的是
> vCenter / ESXi，不是 VMware Fusion。只有 Fusion 的 Mac 可以照教學手動建三台
> Ubuntu VM，再從 Ansible 階段開始；要完整跑 Terraform provisioning，請準備可連線的
> vSphere lab。
