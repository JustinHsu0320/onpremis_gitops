# =============================================================================
# environments/prod/providers.tf — vSphere provider 設定
#
# 憑證注入的三條路（優先序由上而下，擇一即可）：
#   1. 環境變數 TF_VAR_vcenter_user / TF_VAR_vcenter_password（CI 推薦：
#      GitLab CI/CD variable 設成 masked，job 內自動變成 TF_VAR_*）
#   2. 三個變數留 null 時，provider 會退回讀自己的原生環境變數
#      VSPHERE_SERVER / VSPHERE_USER / VSPHERE_PASSWORD（本機互動使用方便）
#   3. terraform.tfvars（僅示範檔進 Git；真檔已被 .gitignore 排除）
#
# 絕對不要做的事：把密碼寫進任何會 commit 的檔案。
# =============================================================================

provider "vsphere" {
  vsphere_server = var.vcenter_server
  user           = var.vcenter_user
  password       = var.vcenter_password

  # 地端 vCenter 常見自簽/內部 CA 憑證。正道是把內部 CA 加入執行端信任庫
  # 後維持 false；true 是「知情的例外」，開了要在 PR 說明原因
  allow_unverified_ssl = var.vcenter_allow_unverified_ssl

  # vCenter API 逾時（分鐘）。clone 大 template 或 datastore 忙碌時預設 5
  # 分鐘偶爾不夠，放寬到 10 分鐘減少 CI 假性失敗
  api_timeout = 10
}
