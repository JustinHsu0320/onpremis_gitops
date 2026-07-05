# =============================================================================
# modules/network/main.tf — vDS port group（每個 VLAN 一個）
#
# 設計說明（給第一次接手的 junior 架構師）：
#   * vDS「已經存在」——用 data source 查，不用 resource 建。這是刻意的邊界：
#     Terraform 管到 port group 為止，vDS/uplink/實體 trunk 屬於網路團隊。
#   * 每個 VLAN 一個 port group，VM 的網卡接到對應的 port group 就等於
#     接進該 VLAN（VLAN tag 由 vDS 打，Guest OS 完全不用懂 VLAN）。
#   * for_each 用 map（不是 count + list）：日後增減 VLAN 時，其他 port group
#     的 resource address 不會位移，不會發生「改一個、重建全部」的慘劇。
# =============================================================================

# ---- 既存物件查詢 -------------------------------------------------------------

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

# 既存 vDS：名稱由變數傳入（prod 環境見 environments/prod/variables.tf 的 vds_name）
data "vsphere_distributed_virtual_switch" "vds" {
  name          = var.vds_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# ---- Port groups（一個 VLAN 一個） --------------------------------------------

resource "vsphere_distributed_port_group" "pg" {
  for_each = var.vlans

  name                            = each.key
  distributed_virtual_switch_uuid = data.vsphere_distributed_virtual_switch.vds.id

  # VLAN tagging 模式：這裡是最單純的 "VLAN"（單一 tag），不是 trunk / private VLAN。
  # VM 網卡完全不需要在 Guest OS 內設 VLAN——tag 在 vDS 層就處理掉了。
  vlan_id = each.value.vlan_id

  description = each.value.description
}
