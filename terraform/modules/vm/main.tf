# =============================================================================
# modules/vm/main.tf — 泛用 VM 模組本體：clone template → 掛碟 → 接網 → cloud-init
#
# 一台 VM 的生命由三段組成，這個檔案就照這個順序寫：
#   (1) data source：把「既存物件」（datacenter / cluster / datastore / template /
#       port group）的名字換成 vSphere API 要的 managed object id。
#   (2) resource "vsphere_virtual_machine"：真正的機器——CPU/RAM/磁碟/網卡。
#   (3) cloud-init（extra_config 的 guestinfo.*）：首次開機自舉，把「裸機」
#       變成「Ansible 可以接手的機器」。之後的一切設定都是 Ansible 的事（Layer 2），
#       Terraform 到此為止——這是刻意的分層邊界（規劃書 §6）。
# =============================================================================

# ---- (1) 既存物件查詢 ----------------------------------------------------------

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

# 運算叢集：VM 統一放叢集根 resource pool，實際落在哪台 ESXi 交給 DRS 排程，
# 「不可同居」的約束由 anti_affinity 模組的規則表達（規劃書 §2.1）
data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

# clone 來源 template（ubuntu-26.04 cloud image）。硬性需求：
#   * 內建 cloud-init 且啟用 VMware guestinfo datasource（cloud-init >= 21.3 內建）
#   * 已安裝 open-vm-tools（guestinfo 的傳輸通道 + vSphere 回報 IP 都靠它）
data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# 每張網卡對應的 port group（由 network 模組建立）。
# distributed_virtual_switch_uuid 用來消歧義：同名 port group 若存在於多個
# 交換器上，指定 UUID 才能保證查到「我們那個 vDS」上的。
data "vsphere_network" "net" {
  # for_each 的 key 必須是字串，這裡用網卡的序號（"0"、"1"…）當 key，
  # 讓下面的 network_interface 可以按原始順序對回來
  for_each = { for idx, n in var.networks : tostring(idx) => n }

  name                            = each.value.port_group
  datacenter_id                   = data.vsphere_datacenter.dc.id
  distributed_virtual_switch_uuid = var.vds_uuid
}

# ---- 中間量計算 ----------------------------------------------------------------

locals {
  # SCSI 控制器數量 = extra_disks 用到的最大控制器編號 + 1（至少 1 個給 OS 碟）。
  # 這就是規劃書 §2.3 的落點：PG 把 data/WAL/etcd 分掛控制器 1/2/3 →
  # scsi_controller_count = 4，四個控制器全部都是 PVSCSI（見下方 scsi_type）。
  scsi_controller_count = (
    length(var.extra_disks) == 0
    ? 1
    : max([for d in var.extra_disks : d.scsi_controller]...) + 1
  )

  # Ubuntu 上 VMXNET3 網卡依 PCI 槽位的「可預期介面名」（predictable NIC name）。
  # 第 1~4 張網卡依序是 ens192/ens224/ens256/ens161——這是 vSphere 虛擬硬體
  # PCI 槽位編號換算的結果，本專案每台 VM 都只有一張網卡（= ens192），
  # 多網卡支援是留給未來的（例如備份專用網段）。
  nic_names = ["ens192", "ens224", "ens256", "ens161"]

  # 把介面名與「是否為第 0 張（主網卡，掛預設路由）」補進每張網卡的資訊，
  # 餵給 metadata（netplan）模板用
  networks_with_names = [
    for idx, n in var.networks : merge(n, {
      name       = local.nic_names[idx]
      is_primary = idx == 0
    })
  ]

  # ---- cloud-init 兩份文件（先渲染成字串，再 base64 塞進 guestinfo） ----
  #
  # metadata：instance-id、hostname、netplan 靜態 IP（開機「前」就要知道的事）
  # userdata：建 ansible 使用者、公鑰、sudoers、關密碼登入（開機「後」做的事）
  metadata = templatefile("${path.module}/templates/metadata.yaml.tftpl", {
    hostname    = var.name
    networks    = local.networks_with_names
    dns_servers = var.dns_servers
    domain      = var.domain
  })

  userdata = templatefile("${path.module}/templates/userdata.yaml.tftpl", {
    hostname           = var.name
    fqdn               = "${var.name}.${var.domain}"
    ansible_public_key = var.ansible_public_key
  })
}

# ---- (2)+(3) VM 本體 -----------------------------------------------------------

resource "vsphere_virtual_machine" "vm" {
  name             = var.name
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  # folder 傳空字串代表放在 datacenter 根層；轉成 null 讓 provider 走預設行為
  folder = var.folder != "" ? var.folder : null

  num_cpus = var.cpu
  memory   = var.memory_mb

  # guest_id / firmware 一律「跟著 template 走」——clone 出來的 VM 若與
  # template 的宣告不一致（例如 BIOS vs EFI），輕則警告、重則開不了機
  guest_id = data.vsphere_virtual_machine.template.guest_id
  firmware = data.vsphere_virtual_machine.template.firmware

  # 規劃書 §2.3：全部 SCSI 控制器統一用 PVSCSI（半虛擬化，佇列深、CPU 開銷低）。
  # 注意 scsi_type 是「所有控制器」的型別——vSphere provider 不支援混搭。
  # 前提：template 的 OS 碟本來就要在 PVSCSI 上（Ubuntu 內建 vmw_pvscsi 驅動，
  # cloud image 沒問題；若換自製 template 請先確認，否則 clone 後找不到根碟）。
  scsi_type             = "pvscsi"
  scsi_controller_count = local.scsi_controller_count

  # 讓 Guest OS 看得到每顆 VMDK 的 UUID（/dev/disk/by-id/wwn-*）。
  # Ansible 的 storage role 依 UUID 而不是 /dev/sdX 來認碟——sdX 順序在
  # 多控制器下不保證穩定，用它掛檔案系統遲早出事。
  enable_disk_uuid = true

  # ---- 網卡（依 var.networks 順序，第 0 張為主網卡） ----
  dynamic "network_interface" {
    for_each = var.networks
    content {
      network_id = data.vsphere_network.net[tostring(network_interface.key)].id
      # VMXNET3：唯一該用的虛擬網卡型別（e1000 系列是相容性後備，效能差一截）
      adapter_type = "vmxnet3"
    }
  }

  # ---- disk0：OS 碟（controller 0 / unit 0，thin 與否跟著 template） ----
  disk {
    label       = "disk0"
    size        = var.os_disk_gb
    unit_number = 0
    # OS 碟的佈建型式沿用 template 的設定——clone 時若不一致 provider 會要求
    # 昂貴的磁碟轉換；OS 碟沒有 IO 敏感問題，不值得為它 thick
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks[0].eagerly_scrub
  }

  # ---- 資料碟（規劃書 §2.3 的三條最佳實踐都在這個 block 落地） ----
  dynamic "disk" {
    for_each = { for d in var.extra_disks : d.label => d }
    content {
      label = disk.value.label
      size  = disk.value.size_gb

      # provider 的 unit_number 是「全域碟號」：控制器 N 的槽位 M = N*15 + M
      # （每個控制器 15 個槽位 0-14）。例：controller 2 / unit 0 → 30。
      # 呼叫端只需要想「第幾個控制器、第幾個槽」，換算在這裡集中處理。
      unit_number = disk.value.scsi_controller * 15 + disk.value.unit_number

      # thin=false → thick lazy-zeroed：容量先保留，資料庫碟不賭 datastore 超賣
      thin_provisioned = disk.value.thin
      eagerly_scrub    = false

      # 快照排除策略（規劃書 §2.3）：
      #   independent_persistent 模式的磁碟「不參與 VM 快照」。有狀態資料
      #   （PG data/WAL、etcd、MQ、NFS）的一致性備份靠資料庫原生機制
      #   （pgBackRest / mnesia backup / rsync，見規劃書 §9），VM 快照對它們
      #   不但沒意義（crash-consistent 而已），還會讓 delta 檔暴長拖垮 IO。
      disk_mode = disk.value.independent_persistent ? "independent_persistent" : "persistent"

      # keep_on_remove：VM 被 terraform destroy 時「保留 VMDK 不刪」。
      # 這是資料碟的最後保險——重建 VM（例如換 template）不應該連資料一起蒸發；
      # 確定不要的碟，由管理員在 datastore 層手動刪除（有意識的動作）。
      keep_on_remove = disk.value.independent_persistent
    }
  }

  # ---- clone 來源 ----
  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    # 刻意「沒有 customize block」：Guest 客製化全部交給 cloud-init。
    # vSphere 傳統 guest customization 與 cloud-init 會互踩（兩邊都想改
    # hostname / netplan），一台機器只能有一個 first-boot 的主人。
    timeout = 30
  }

  # ---- cloud-init 注入（VMware guestinfo datasource） ----
  # cloud-init 開機時透過 open-vm-tools 讀 guestinfo.metadata / userdata，
  # base64 是官方建議的傳輸編碼（避免多行 YAML 在 VMX 屬性裡被咬壞）。
  extra_config = {
    "guestinfo.metadata"          = base64encode(local.metadata)
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata"          = base64encode(local.userdata)
    "guestinfo.userdata.encoding" = "base64"
  }

  # 在 vCenter UI 的備註欄提醒人類：這台機器是 IaC 管的
  annotation = "Managed by Terraform (platform Layer 1)。手動改規格 = drift，請改 terraform/ 後 apply。"

  lifecycle {
    # cloud-init 只在首次開機作用；之後若調整模板內容（例如換公鑰），
    # 不應該為此重建整台 VM——機上帳號/金鑰的後續管理是 Ansible 的職責。
    ignore_changes = [
      extra_config["guestinfo.metadata"],
      extra_config["guestinfo.userdata"],
    ]
  }
}
