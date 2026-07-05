# =============================================================================
# modules/network/versions.tf — 本模組的 Terraform / Provider 版本宣告
#
# 為什麼模組也要宣告 required_providers？
#   模組是可被任何 root module 重用的元件，明確宣告「我依賴 vsphere provider
#   哪個版本」可以在版本不相容時於 init 階段就報錯，而不是 apply 到一半才炸。
#   版本約束刻意比 root（environments/prod/versions.tf）寬鬆：模組只宣告
#   「最低需求」，實際鎖版本的責任在 root module 與 .terraform.lock.hcl。
# =============================================================================

terraform {
  # optional() 帶預設值的 object 型別需要 Terraform >= 1.3；全 repo 統一要求 1.6
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      # namespace 是 vmware/（非 hashicorp/）：provider 已移交 VMware 維護，
      # 且必須與 root module 的 source 一致，否則會被視為不同 provider
      source  = "vmware/vsphere"
      version = ">= 2.8.0"
    }
  }
}
