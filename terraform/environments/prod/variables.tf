# =============================================================================
# environments/prod/variables.tf — prod 環境的完整輸入變數
#
# 分四組：vCenter 連線 / vSphere 既存物件名稱 / VM 共用參數 / 網路參數。
# 示範值見 terraform.tfvars.example；真實值走 CI variable 或本機 tfvars
# （已被 .gitignore 排除）。
# =============================================================================

# ---- 1. vCenter 連線 -----------------------------------------------------------

variable "vcenter_server" {
  description = "vCenter Server 的 FQDN 或 IP。留 null 時 provider 退回讀環境變數 VSPHERE_SERVER"
  type        = string
  default     = null
}

variable "vcenter_user" {
  description = "vCenter 登入帳號（建議專用服務帳號如 svc-terraform@vsphere.local，權限最小化：VM/資料夾/port group/DRS 規則的 CRUD）。留 null 時退回環境變數 VSPHERE_USER"
  type        = string
  default     = null
}

variable "vcenter_password" {
  description = "vCenter 登入密碼。一律走 TF_VAR_vcenter_password 或 VSPHERE_PASSWORD 環境變數注入，不落檔"
  type        = string
  default     = null
  sensitive   = true
}

variable "vcenter_allow_unverified_ssl" {
  description = "是否允許未驗證的 vCenter TLS 憑證（自簽）。正道：把內部 CA 加入信任庫並維持 false"
  type        = bool
  default     = false
}

# ---- 2. vSphere 既存物件（全部只是「名稱」，data source 查詢用） -----------------

variable "datacenter" {
  description = "vSphere Datacenter 名稱（既存物件）"
  type        = string
}

variable "cluster" {
  description = "運算叢集名稱（既存物件；至少 3 台 ESXi 並啟用 HA + DRS，否則反親和規則沒有意義——規劃書 §2.1）"
  type        = string
}

variable "vds_name" {
  description = "既存分散式交換器（vDS）名稱。Terraform 只在其上建 port group，vDS 本身/uplink/實體 trunk 歸網路團隊管"
  type        = string
}

variable "datastore" {
  description = "一般 datastore 名稱（SAS/混合陣列即可）：lb / app / mq / nfs / mgmt / gitlab / runner 用"
  type        = string
}

variable "datastore_ssd" {
  description = "SSD/NVMe datastore 名稱：pg-01..03（etcd 與 PG WAL 對 fsync 延遲極度敏感，規劃書 §2.1）與 scylla-01..03（LSM 隨機讀寫 + 壓實）整台放這；並確認底層關閉會延後寫入確認的快取策略"
  type        = string
}

variable "template_name" {
  description = "clone 來源 VM template 名稱（ubuntu-26.04 cloud image：內建 cloud-init + VMware guestinfo datasource + open-vm-tools）"
  type        = string
}

variable "vm_folder" {
  description = "收納本專案 VM 的 vSphere inventory 資料夾名稱（由本 root module 建立），方便 vCenter 內權限切分與視覺歸類"
  type        = string
  default     = "email-proxy"

  validation {
    condition     = length(var.vm_folder) > 0
    error_message = "vm_folder 不可為空字串。"
  }
}

# ---- 3. VM 共用參數 ------------------------------------------------------------

variable "domain" {
  description = "內部網域（組 FQDN 用），對齊 CONVENTIONS.md §7 的 domain 變數"
  type        = string
  default     = "ptc-nec.com.tw"
}

variable "ansible_public_key" {
  description = "ansible 自動化帳號的 SSH 公鑰（一行 authorized_keys 格式）。私鑰只存在 mgmt-01 的 ~/.ssh/id_email_proxy——這是 Terraform 交棒給 Ansible 的唯一憑證"
  type        = string
}

variable "dns_servers" {
  description = "Guest OS 的 DNS 伺服器。主機間解析走 Ansible 管的 /etc/hosts（ADR-5），這裡只影響對外解析（apt mirror、OAuth endpoint 等）；可為空"
  type        = list(string)
  default     = []
}

# ---- 4. 網路參數 ---------------------------------------------------------------

variable "port_group_prefix" {
  description = "port group 命名前綴（完整名 = <prefix>-vlan<id>，例 email-proxy-vlan30）。同一 vDS 上可能還有別的專案，前綴避免命名衝突"
  type        = string
  default     = "email-proxy"
}

variable "vlan_prefix_length" {
  description = "各 VLAN 網段的前綴長度。CONVENTIONS.md §2：全部 /24"
  type        = number
  default     = 24

  validation {
    condition     = var.vlan_prefix_length >= 8 && var.vlan_prefix_length <= 30
    error_message = "vlan_prefix_length 必須介於 8 到 30。"
  }
}

variable "vlan_gateways" {
  description = "VLAN id → 該網段預設閘道 IP 的 map。本專案慣例：每網段 .1（由 L3 交換器 / 防火牆擔任），與 CONVENTIONS.md §2 的網段表對齊；機房閘道慣例不同時整個 map 覆寫即可"
  type        = map(string)
  default = {
    "10" = "10.20.10.1" # 邊界
    "20" = "10.20.20.1" # 應用
    "30" = "10.20.30.1" # 資料
    "40" = "10.20.40.1" # 儲存
    "50" = "10.20.50.1" # DevOps
    "99" = "10.20.99.1" # 管理
  }

  validation {
    condition     = alltrue([for g in values(var.vlan_gateways) : can(cidrnetmask("${g}/24"))])
    error_message = "vlan_gateways 的每個值都必須是合法的 IPv4 位址。"
  }
}
