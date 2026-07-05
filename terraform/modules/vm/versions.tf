# =============================================================================
# modules/vm/versions.tf — 本模組的 Terraform / Provider 版本宣告
#
# 模組層只宣告「最低需求」（>=），實際鎖定版本由 root module 的
# environments/prod/versions.tf（~> 2.8）與 .terraform.lock.hcl 負責。
# =============================================================================

terraform {
  # extra_disks 的 optional() 預設值語法需要 >= 1.3；全 repo 統一要求 1.6
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
