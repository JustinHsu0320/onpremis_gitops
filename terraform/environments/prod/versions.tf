# =============================================================================
# environments/prod/versions.tf — root module 的版本鎖定
#
# 版本策略（與模組層的分工）：
#   * 模組（modules/*/versions.tf）只宣告最低需求 >= 2.8.0
#   * root（這裡）用悲觀鎖 ~> 2.8：允許 2.8.x → 2.x 的小版本演進，
#     擋掉 3.0 的破壞性升級——provider 大版本升級要走 PR 明改，不能被
#     某次 init 悄悄帶上去
#   * 精確到 patch 的鎖定在 .terraform.lock.hcl（CI 的 init 會驗 hash）
# =============================================================================

terraform {
  # optional() object 預設值、Terraform 1.6 起的測試框架等特性的基線
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      # 注意 namespace 是 vmware/ 不是 hashicorp/：provider 已於 2024 移交
      # VMware 維護，hashicorp/vsphere 凍結在 2.12.0，新版（含安全修補）
      # 只發佈在 vmware/vsphere。root 與所有模組的 source 必須一致，
      # 否則 Terraform 會視為兩個不同的 provider。
      source = "vmware/vsphere"
      # ~> 2.8 = >= 2.8.0, < 3.0.0
      version = "~> 2.8"
    }
  }
}
