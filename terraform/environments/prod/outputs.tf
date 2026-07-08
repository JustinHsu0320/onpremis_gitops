# =============================================================================
# environments/prod/outputs.tf — prod 環境的輸出
#
# 兩個消費場景：
#   1. 人：apply 完看 vm_ips 快速確認 18 台機器的名字與 IP
#   2. 對照：rendered_ansible_inventory 渲染出 hosts.yml「樣式」的 YAML，
#      與 ansible/inventories/prod/hosts.yml 做人工 diff 用
# =============================================================================

output "vm_ips" {
  description = "VM 名稱 → 主網卡靜態 IPv4 的 map（18 台）。應與 CONVENTIONS.md §2 的 IP 表完全一致"
  value       = { for name, m in module.vm : name => m.primary_ip }
}

output "vm_moids" {
  description = "VM 名稱 → vSphere managed object id 的 map（govc / API 除錯用）"
  value       = { for name, m in module.vm : name => m.moid }
}

output "port_groups" {
  description = "port group 名稱 → managed object id（VM 網卡接線對照 / 除錯用）"
  value       = module.network.port_group_ids
}

# ---- bonus：渲染成 Ansible inventory 樣式的 YAML 字串 ---------------------------
#
# 用途：`terraform output -raw rendered_ansible_inventory` 之後與
# ansible/inventories/prod/hosts.yml「人工比對」，確認兩邊沒有漂移。
#
# 刻意「不」拿這個輸出去覆蓋 hosts.yml：inventory 才是主機清單的唯一事實
# 來源（ADR-1，見 hosts.yml 頂部註解）——流程是先改 inventory、再改
# Terraform 的 locals；這個輸出只是幫你驗證「Terraform 有沒有跟上 inventory」，
# 方向不能反過來，否則哪天 state 壞了 inventory 就跟著陪葬。
#
# 已知差異（比對時忽略即可）：群組順序是字母序（模板吃 map，Terraform 的
# map 迭代恆為 key 排序）；別名群組（egress/keydb/etcd）這裡也會帶
# ansible_host（值相同，語意無差）；all.vars 那段連線參數不在渲染範圍。
locals {
  # 群組 → 成員清單（對照 CONVENTIONS.md §1 的群組表；含同居別名群組）
  inventory_groups = {
    lb            = ["lb-01", "lb-02"]
    egress        = ["lb-01", "lb-02"] # egress 與 lb 同居（ADR-3）
    app           = ["app-01", "app-02", "app-03"]
    keydb         = ["app-01", "app-02", "app-03"] # KeyDB 與 app 同居（規劃書 §2.4）
    postgres      = ["pg-01", "pg-02", "pg-03"]
    etcd          = ["pg-01", "pg-02", "pg-03"] # etcd 與 pg 同居（Patroni DCS）
    rabbitmq      = ["mq-01", "mq-02", "mq-03"]
    scylladb      = ["scylla-01", "scylla-02", "scylla-03"]
    nfs           = ["nfs-01"]
    gitlab        = ["gitlab-01"]
    gitlab_runner = ["runner-01"]
    monitoring    = ["mgmt-01"]
  }
}

output "rendered_ansible_inventory" {
  description = "hosts.yml 樣式的 YAML 字串（與 ansible/inventories/prod/hosts.yml 人工比對用；inventory 仍是唯一事實來源——ADR-1）"
  value = templatefile("${path.module}/templates/ansible_inventory.yml.tftpl", {
    groups = local.inventory_groups
    # 用 local.vms 的宣告值（而非 vSphere 回報值）：plan 階段即可渲染，不用等 apply
    ips = { for name, spec in local.vms : name => spec.ipv4 }
  })
}
