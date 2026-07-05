# =============================================================================
# modules/anti_affinity/outputs.tf — 反親和模組的輸出
# =============================================================================

output "id" {
  description = "規則的 resource id（除錯 / import 對照用）"
  value       = vsphere_compute_cluster_vm_anti_affinity_rule.rule.id
}

output "name" {
  description = "規則名稱（在 vCenter → 叢集 → Configure → VM/Host Rules 可對照）"
  value       = vsphere_compute_cluster_vm_anti_affinity_rule.rule.name
}
