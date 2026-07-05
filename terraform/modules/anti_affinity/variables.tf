# =============================================================================
# modules/anti_affinity/variables.tf — 反親和模組的輸入介面
# =============================================================================

variable "name" {
  description = "規則名稱（vCenter UI 上看到的名字），本專案慣例 AA-<叢集名>：AA-postgres / AA-rabbitmq / AA-app / AA-lb（規劃書 §2.1 表）"
  type        = string
}

variable "compute_cluster_id" {
  description = "規則所屬的運算叢集 managed object id（呼叫端用 data.vsphere_compute_cluster.<x>.id 取得後傳入）"
  type        = string
}

variable "vm_ids" {
  description = "互斥的 VM UUID 清單（vm 模組的 output \"id\"）。清單內任兩台 VM 不得落在同一台 ESXi"
  type        = list(string)

  validation {
    # 一台 VM 跟自己反親和沒有意義；規則至少要有兩個成員
    condition     = length(var.vm_ids) >= 2
    error_message = "vm_ids 至少要有 2 台 VM，反親和規則才有意義。"
  }
}

variable "enabled" {
  description = "規則是否啟用。保留開關是為了緊急維運：極端狀況（例如 3 台 ESXi 壞到只剩 1 台）需要暫時允許同居時，改這裡 apply，而不是去 vCenter 手點（手點 = drift）"
  type        = bool
  default     = true
}

variable "mandatory" {
  description = <<-EOT
    是否為「強制（must）」規則。預設 false（偏好/should 規則）是深思後的決定：

      * mandatory = true 時，vSphere「任何」違反規則的操作都會被擋——包括
        vSphere HA 的故障重啟與維護模式的 vMotion。本專案只有 3 台 ESXi、
        叢集成員也是 3 台：一旦 1 台 ESXi 進維護或故障，3 台 VM 只剩 2 台
        實體機可站，mandatory 規則會讓第三台 VM 完全無處可去（開不了機）。
      * mandatory = false（should 規則）時，DRS 在「正常狀態」下仍然保證分散
        （這是我們要的日常行為）；只有在別無選擇時才允許暫時同居，並在
        資源恢復後自動搬回。對 quorum 叢集而言「暫時同居但活著」遠好於
        「堅持分散但少一個節點」。

    只有當 ESXi 數量「嚴格大於」叢集成員數（例如 4+ 台 ESXi 跑 3 節點 PG）
    時，才建議把這個開成 true。
  EOT
  type        = bool
  default     = false
}
