variable "vsphere_server" {
  description = "vCenter FQDN or IP; the provider talks to vSphere, not VMware Fusion"
  type        = string
}

variable "vsphere_user" {
  description = "Least-privilege vSphere automation account"
  type        = string
}

variable "vsphere_password" {
  description = "vSphere automation account password; prefer TF_VAR_vsphere_password"
  type        = string
  sensitive   = true
}

variable "allow_unverified_ssl" {
  description = "Lab-only escape hatch for a self-signed vCenter certificate"
  type        = bool
  default     = false
}

variable "datacenter" {
  type = string
}

variable "cluster" {
  type = string
}

variable "datastore" {
  type = string
}

variable "network" {
  description = "Existing vSphere port group reachable from the Mac"
  type        = string
}

variable "template_name" {
  description = "Ubuntu cloud-init template with open-vm-tools"
  type        = string
}

variable "vm_folder" {
  type    = string
  default = ""
}

variable "domain" {
  type    = string
  default = "lab.internal"
}

variable "gateway" {
  type    = string
  default = "192.168.68.1"
}

variable "netmask" {
  type    = number
  default = 24
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_public_key_path" {
  description = "Public key only; never pass a private key to Terraform"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ansible_user" {
  type    = string
  default = "ansible"
}

variable "nodes" {
  description = "One control plane and two workers. Increase memory before enabling the full platform profile."
  type = map(object({
    role      = string
    ip        = string
    cpu       = number
    memory_mb = number
    disk_gb   = number
  }))

  default = {
    "k8s-cp-01" = {
      role      = "control_plane"
      ip        = "192.168.68.211"
      cpu       = 4
      memory_mb = 8192
      disk_gb   = 100
    }
    "k8s-worker-01" = {
      role      = "workers"
      ip        = "192.168.68.212"
      cpu       = 4
      memory_mb = 8192
      disk_gb   = 120
    }
    "k8s-worker-02" = {
      role      = "workers"
      ip        = "192.168.68.213"
      cpu       = 4
      memory_mb = 8192
      disk_gb   = 120
    }
  }

  validation {
    condition     = length([for node in values(var.nodes) : node if node.role == "control_plane"]) == 1
    error_message = "This lab expects exactly one control_plane node."
  }
}

