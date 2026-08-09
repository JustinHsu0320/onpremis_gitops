# OpenWiki instructions

以繁體中文為主，協助後端工程師理解本 repository 的地端平台建置。

優先說明這條鏈的責任邊界、依賴、部署順序、驗證指令、故障排查與回滾：

`MacBook → VMware → Ubuntu → Terraform → Ansible → containerd → Kubernetes → Go API → GitOps → 監控`

主要來源是 `terraform/`、`ansible/`、`labs/`、`argocd/`、`gitlab/` 與 `docs/`。保留命令、資源名稱與程式碼識別字原文，清楚標註 lab 與 production 差異。

不要讀取或描述 secrets、vault password、tfstate、kubeconfig、私鑰、憑證內容或任何被 `.openwikiignore` 排除的檔案。來源程式碼與測試是權威；對不確定內容列出待驗證項目，不要自行補造設定。
