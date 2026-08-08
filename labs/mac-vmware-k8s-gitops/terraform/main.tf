locals {
  control_plane_name = one([for name, node in var.nodes : name if node.role == "control_plane"])
  control_plane_ip   = var.nodes[local.control_plane_name].ip
}

module "k8s_node" {
  for_each = var.nodes
  source   = "../../../terraform/modules/vm"

  name               = each.key
  datacenter         = var.datacenter
  cluster            = var.cluster
  datastore          = var.datastore
  folder             = var.vm_folder
  template_name      = var.template_name
  cpu                = each.value.cpu
  memory_mb          = each.value.memory_mb
  os_disk_gb         = each.value.disk_gb
  domain             = var.domain
  ansible_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_servers        = var.dns_servers

  networks = [{
    port_group = var.network
    ipv4       = each.value.ip
    netmask    = var.netmask
    gateway    = var.gateway
  }]
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/generated.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    nodes            = var.nodes
    ansible_user     = var.ansible_user
    control_plane_ip = local.control_plane_ip
  })
}

