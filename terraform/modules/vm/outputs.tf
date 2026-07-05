# =============================================================================
# modules/vm/outputs.tf — VM 模組的輸出
#
# 主要消費者：
#   * environments/prod/main.tf 的 anti_affinity 模組（要 VM 的 uuid）
#   * environments/prod/outputs.tf 的 name→IP 對照表與 inventory 渲染
# =============================================================================

output "id" {
  description = "VM 的 UUID（vsphere_compute_cluster_vm_anti_affinity_rule 的 virtual_machine_ids 吃這個）"
  value       = vsphere_virtual_machine.vm.id
}

output "moid" {
  description = "VM 的 managed object id（vSphere API 進階操作 / govc 除錯用）"
  value       = vsphere_virtual_machine.vm.moid
}

output "name" {
  description = "VM 名稱（= hostname = Ansible inventory 主機名）"
  value       = vsphere_virtual_machine.vm.name
}

output "primary_ip" {
  description = "主網卡（第 0 張）的靜態 IPv4。刻意回傳「我們宣告的 IP」而不是 vSphere 回報的 guest IP——宣告值在 plan 階段就已知，且不受 open-vm-tools 回報時差影響"
  value       = var.networks[0].ipv4
}
