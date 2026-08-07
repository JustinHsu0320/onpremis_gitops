# =============================================================================
# modules/vm/variables.tf — 泛用 VM 模組的輸入介面
#
# 這個模組是整個 Layer 1 的核心：所有 18 台 VM（16 台服務 + 2 台 DevOps）都
# 透過同一個模組長出來，差異全部收斂在輸入變數。模組本身不含任何主機名 /
# IP 的硬編值——那些屬於 environments/prod/main.tf 的 locals（單一事實來源
# 是 ansible/inventories/prod/hosts.yml + CONVENTIONS.md §2，見 ADR-1）。
# =============================================================================

# ---- 基本識別 -----------------------------------------------------------------

variable "name" {
  description = "VM 名稱（= Guest OS hostname = Ansible inventory 主機名，三者必須一致，否則之後對照表會對不起來）"
  type        = string

  validation {
    # hostname 規範（RFC 1123 子集）：小寫字母/數字/連字號，不可用底線——
    # 底線在 DNS 名稱裡不合法，之後 /etc/hosts 與憑證 SAN 都會出問題
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name))
    error_message = "name 只能包含小寫字母、數字與連字號（會直接當 hostname 用）。"
  }
}

# ---- vSphere 佈局（全部是「既存物件」的名稱，data source 查詢用） ----------------

variable "datacenter" {
  description = "vSphere Datacenter 名稱（既存物件）"
  type        = string
}

variable "cluster" {
  description = "vSphere 運算叢集名稱（既存物件；VM 放進叢集的根 resource pool，讓 DRS 決定實際落在哪台 ESXi——反親和規則見 anti_affinity 模組）"
  type        = string
}

variable "datastore" {
  description = "Datastore 名稱（既存物件）。注意：整台 VM（含所有磁碟）都放同一個 datastore——PG 這種 fsync 敏感的 VM 請整台放 SSD datastore（規劃書 §2.1）"
  type        = string
}

variable "folder" {
  description = "VM 所屬的 vSphere inventory 資料夾路徑（不含 datacenter 前綴），方便在 vCenter 裡把本專案的 VM 收在一起"
  type        = string
  default     = ""
}

variable "template_name" {
  description = "clone 來源的 VM template 名稱（本專案用 ubuntu-26.04 cloud image template：需內建 cloud-init 且啟用 VMware guestinfo datasource、open-vm-tools）"
  type        = string
}

# ---- 運算資源 -----------------------------------------------------------------

variable "cpu" {
  description = "vCPU 數（對照規劃書 §2.2 資源配額表）"
  type        = number

  validation {
    condition     = var.cpu >= 1 && var.cpu <= 64
    error_message = "cpu 必須介於 1 到 64。"
  }
}

variable "memory_mb" {
  description = "記憶體大小（MB）。注意單位是 MB 不是 GB——vSphere API 的原生單位，8 GB 請填 8192"
  type        = number

  validation {
    condition     = var.memory_mb >= 1024
    error_message = "memory_mb 單位是 MB，最小 1024（1 GB）——填太小通常是把 GB 當 MB 填了。"
  }
}

# ---- 磁碟 ---------------------------------------------------------------------

variable "os_disk_gb" {
  description = "OS 碟（disk0）大小，單位 GB。必須 >= template 的 OS 碟大小（clone 只能長大不能縮小）；cloud-init 的 growpart 會在首次開機自動把 / 撐滿"
  type        = number
}

variable "extra_disks" {
  description = <<-EOT
    額外資料碟清單（規劃書 §2.3 磁碟最佳實踐）。每顆：
      label                  : Terraform 內部識別用標籤（如 "disk1-pgdata"），改名會導致重建，取好就別改
      size_gb                : 大小（GB）
      thin                   : true = thin provisioning（省空間）；false = thick lazy-zeroed
                               （容量預先保留，避免 datastore 超賣後寫入才發現沒空間——資料庫碟建議 false）
      independent_persistent : true = 磁碟模式設為 Independent-Persistent，「不參與 VM 快照」
                               （規劃書 §2.3：有狀態資料碟一律 true，備份改用資料庫原生機制）
      unit_number            : 在所屬 SCSI 控制器上的槽位（0-14，7 保留給控制器本身）
      scsi_controller        : 掛在第幾號 SCSI 控制器（0-3）。PG 的 data/WAL/etcd 各自獨立
                               控制器（1/2/3），避免 WAL 順序寫與資料隨機讀互搶單一控制器的佇列
  EOT
  type = list(object({
    label                  = string
    size_gb                = number
    thin                   = optional(bool, true)
    independent_persistent = optional(bool, true)
    unit_number            = optional(number, 0)
    scsi_controller        = optional(number, 0)
  }))
  default = []

  validation {
    condition     = alltrue([for d in var.extra_disks : d.scsi_controller >= 0 && d.scsi_controller <= 3])
    error_message = "scsi_controller 必須介於 0 到 3（vSphere 每台 VM 最多 4 個 SCSI 控制器）。"
  }

  validation {
    # unit 7 是 SCSI 控制器自己佔用的 target ID，不能配置磁碟
    condition     = alltrue([for d in var.extra_disks : d.unit_number >= 0 && d.unit_number <= 14 && d.unit_number != 7])
    error_message = "unit_number 必須介於 0 到 14 且不可為 7（7 保留給 SCSI 控制器本身）。"
  }

  validation {
    # (controller, unit) 組合不可重複，否則兩顆磁碟搶同一個槽位
    condition = length(var.extra_disks) == length(distinct([
      for d in var.extra_disks : "${d.scsi_controller}:${d.unit_number}"
    ]))
    error_message = "extra_disks 中 (scsi_controller, unit_number) 組合不可重複。"
  }

  validation {
    # OS 碟固定佔用 controller 0 / unit 0，資料碟不可撞上去
    condition     = alltrue([for d in var.extra_disks : !(d.scsi_controller == 0 && d.unit_number == 0)])
    error_message = "controller 0 / unit 0 已被 OS 碟（disk0）佔用，extra_disks 不可使用。"
  }
}

# ---- 網路 ---------------------------------------------------------------------

variable "networks" {
  description = <<-EOT
    網卡清單（第 0 張為主網卡，其 gateway 會成為預設路由）。每張：
      port_group : 要接上的 vDS port group 名稱（由 network 模組建立）
      ipv4       : 靜態 IPv4（對照 CONVENTIONS.md §2 的 IP 配置表）
      netmask    : 前綴長度（CIDR 位數，本專案全部 /24 → 填 24）
      gateway    : 該網段的預設閘道（本專案慣例為 .1，見 prod 的 vlan_gateways 變數）
  EOT
  type = list(object({
    port_group = string
    ipv4       = string
    netmask    = number
    gateway    = string
  }))

  validation {
    condition     = length(var.networks) >= 1
    error_message = "至少要有一張網卡（networks 不可為空）。"
  }

  validation {
    condition     = alltrue([for n in var.networks : can(cidrnetmask("${n.ipv4}/${n.netmask}"))])
    error_message = "networks 的 ipv4/netmask 組合必須是合法的 IPv4 位址與前綴長度。"
  }
}

variable "vds_uuid" {
  description = "port group 所在 vDS 的 UUID（data.vsphere_network 消歧義用；同名 port group 存在於多個交換器時必須指定）。傳 null 則不限定交換器"
  type        = string
  default     = null
}

# ---- cloud-init（首次開機自舉，之後全部交給 Ansible） ---------------------------

variable "domain" {
  description = "內部網域（組 FQDN 用，prod = ptc-nec.com.tw，見 CONVENTIONS.md §7）"
  type        = string
}

variable "ansible_public_key" {
  description = "ansible 自動化帳號的 SSH 公鑰（一行 authorized_keys 格式）。對應 mgmt-01 上的 ~/.ssh/id_platform——這是 Layer 1 交棒給 Layer 2（Ansible）的唯一憑證"
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ansible_public_key))
    error_message = "ansible_public_key 必須是一行合法的 SSH 公鑰（ssh-ed25519 / ssh-rsa / ecdsa 開頭）。"
  }
}

variable "dns_servers" {
  description = "DNS 伺服器清單。可為空——本專案主機間解析走 Ansible 管的 /etc/hosts（ADR-5），但 apt/外部連線通常仍需 DNS"
  type        = list(string)
  default     = []
}
