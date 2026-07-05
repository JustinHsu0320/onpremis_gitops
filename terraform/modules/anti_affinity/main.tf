# =============================================================================
# modules/anti_affinity/main.tf — DRS VM-VM 反親和規則（規劃書 §2.1）
#
# 為什麼需要這個模組（給 junior 架構師的白話版）：
#   pg / mq / app 都是「三節點 quorum」叢集——掉 1 個節點沒事，掉 2 個就失去
#   多數。如果 DRS 把三台 pg 排到同一台 ESXi，那台實體機一故障，整個
#   PostgreSQL 叢集直接死透，vSphere HA 形同虛設。反親和規則就是告訴 DRS：
#   「這幾台 VM 永遠不要放在同一台 ESXi 上」。
#
# 邊界：本模組只建立「規則」。VM 是誰、cluster 是誰，由呼叫端
# （environments/prod/main.tf）決定——模組不查任何 data source，保持純粹。
# =============================================================================

resource "vsphere_compute_cluster_vm_anti_affinity_rule" "rule" {
  name                = var.name
  compute_cluster_id  = var.compute_cluster_id
  virtual_machine_ids = var.vm_ids

  enabled = var.enabled

  # mandatory 的取捨見 variables.tf 的長註解——預設 false（soft rule）不是手滑
  mandatory = var.mandatory
}
