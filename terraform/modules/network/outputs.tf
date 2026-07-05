# =============================================================================
# modules/network/outputs.tf — 網路模組的輸出
# =============================================================================

output "port_group_ids" {
  description = "port group 名稱 → managed object id 的 map（除錯 / 進階引用用）"
  value       = { for k, pg in vsphere_distributed_port_group.pg : k => pg.id }
}

output "port_group_names" {
  description = "port group 名稱 → 名稱的 map。看似多餘，但下游（vm 模組）引用這個輸出可以建立『先建 port group、再查 network』的隱式依賴。"
  value       = { for k, pg in vsphere_distributed_port_group.pg : k => pg.name }
}

output "vds_uuid" {
  description = "既存 vDS 的 UUID（data.vsphere_network 消歧義用：同名網路存在於多個交換器時，用 UUID 指定要查哪一個 vDS 上的）"
  value       = data.vsphere_distributed_virtual_switch.vds.id
}
