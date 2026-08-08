output "node_ips" {
  description = "Stable node addresses; this is the Layer 1 → Layer 2 contract"
  value       = { for name, node in var.nodes : name => node.ip }
}

output "control_plane_endpoint" {
  value = "https://${local.control_plane_ip}:6443"
}

output "ansible_inventory" {
  value = local_file.ansible_inventory.filename
}

