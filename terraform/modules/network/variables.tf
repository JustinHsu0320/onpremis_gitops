# =============================================================================
# modules/network/variables.tf — 網路模組的輸入介面
#
# 本模組只做一件事：在「既存的」vSphere 分散式交換器（vDS）上，替每個 VLAN
# 建立一個 distributed port group。vDS 本身、上聯（uplink）、實體交換器的
# trunk 設定都不歸 Terraform 管——那是機房網路團隊的地盤（見規劃書 §3）。
# =============================================================================

variable "datacenter" {
  description = "vSphere Datacenter 名稱（既存物件，data source 查詢用）"
  type        = string
}

variable "vds_name" {
  description = "既存的分散式交換器（vSphere Distributed Switch）名稱。本模組不建立 vDS，只在其上掛 port group——vDS 的生命週期由基礎架構團隊管理。"
  type        = string
}

variable "vlans" {
  description = <<-EOT
    要建立的 port group 清單（map）：
      key   = port group 名稱（例如 "email-proxy-vlan10"）
      value = { vlan_id = VLAN 標籤號碼, description = 用途說明 }
    對照 CONVENTIONS.md §2：VLAN 10/20/30/40/50/99 共六個。
  EOT
  type = map(object({
    vlan_id     = number
    description = optional(string, "")
  }))

  validation {
    # VLAN ID 合法範圍 1-4094（0 與 4095 為保留值）
    condition     = alltrue([for v in var.vlans : v.vlan_id >= 1 && v.vlan_id <= 4094])
    error_message = "vlan_id 必須介於 1 到 4094 之間。"
  }
}
