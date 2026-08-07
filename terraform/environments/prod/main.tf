# =============================================================================
# environments/prod/main.tf — prod 環境的機器清單與組裝
#
# 這個檔案是 Layer 1 的「事實陳述」：23 台 VM（21 台服務 + 2 台 DevOps）、
# 6 個 VLAN port group、7 組反親和規則。每一個 IP 對照 CONVENTIONS.md §2 與
# ansible/inventories/prod/hosts.yml（一一對應，兩邊都改才算改完——ADR-1，
# inventory 是主機清單的唯一事實來源，Terraform 照抄它，不反過來）。
#
# 改機器的正確流程：
#   改 hosts.yml（PR）→ 改這裡的 locals（同一個 PR）→ CI plan → review → apply
# =============================================================================

# ---- 既存物件（root 層只查反親和規則需要的 cluster；其餘 data source 在模組內） ----

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

# 收納 VM 的 inventory 資料夾（純視覺/權限歸類，不影響任何執行期行為）
resource "vsphere_folder" "platform" {
  path          = var.vm_folder
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# 平台化改名（email_proxy → platform）：moved block 讓 Terraform 做 state 級
# 更名，而不是 destroy/create（資料夾重建會把既有 VM 掃出資料夾）
moved {
  from = vsphere_folder.email_proxy
  to   = vsphere_folder.platform
}

# ---- locals：VLAN 與 VM 的完整清單 ---------------------------------------------

locals {
  # ---------------------------------------------------------------------------
  # VLAN → port group（CONVENTIONS.md §2 的六個 VLAN）
  # key = port group 名稱（vCenter 上看到的名字），value = VLAN tag + 用途
  # ---------------------------------------------------------------------------
  vlans = {
    "${var.port_group_prefix}-vlan10" = { vlan_id = 10, description = "邊界層 10.20.10.0/24：服務 VIP .10 / egress VIP .20 / lb-01..02" }
    "${var.port_group_prefix}-vlan20" = { vlan_id = 20, description = "應用層 10.20.20.0/24：kong VIP .20 / kong-01..02 .21-.22 / app-01..03 .11-.13（含同居 KeyDB）" }
    "${var.port_group_prefix}-vlan30" = { vlan_id = 30, description = "資料層 10.20.30.0/24：PgBouncer VIP .10 / pg-01..03 / RabbitMQ VIP .20 / mq-01..03 / scylla-01..03 .31-.33" }
    "${var.port_group_prefix}-vlan40" = { vlan_id = 40, description = "儲存層 10.20.40.0/24：S3 VIP .10 / nfs-01 .11 / sw-01..03 .21-.23" }
    "${var.port_group_prefix}-vlan50" = { vlan_id = 50, description = "DevOps 10.20.50.0/24：gitlab-01 / runner-01" }
    "${var.port_group_prefix}-vlan99" = { vlan_id = 99, description = "管理層 10.20.99.0/24：mgmt-01（Ansible 控制 + PKI + 監控）" }
  }

  # 反查表：VLAN id → port group 名稱（下面 VM 清單只寫 vlan 號碼，好對照文件）
  vlan_port_group = { for pg_name, v in local.vlans : v.vlan_id => pg_name }

  # ---------------------------------------------------------------------------
  # PG 節點的三顆資料碟（規劃書 §2.2 + §2.3）——抽成 local 讓 pg-01..03 完全一致。
  #
  # 重點：data / WAL / etcd「各自獨立一個 PVSCSI 控制器」（1/2/3 號；0 號留給
  # OS 碟）。WAL 是純順序寫、data 是隨機讀寫、etcd 是小量 fsync——分開控制器
  # 才不會在單一佇列上互相排隊。三顆都 thick（thin=false）：資料庫碟不賭
  # datastore 超賣；都 independent_persistent：排除在 VM 快照外（§2.3）。
  # Guest 內的格式化/掛載由 Ansible 的 block_storage role 處理（playbook 階段
  # 05-block-storage，排在服務安裝前）：enable_disk_uuid 讓 guest 看得到每顆碟，
  # role 依「容量」認碟後 mkfs.xfs + 用 UUID 寫 fstab 掛到資料目錄。
  # 三顆碟容量互異（200/50/10）是刻意的——block_storage 靠容量精確區分用途。
  # ---------------------------------------------------------------------------
  pg_extra_disks = [
    { label = "disk1-pgdata", size_gb = 200, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
    { label = "disk2-pgwal", size_gb = 50, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 2 },
    { label = "disk3-etcd", size_gb = 10, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 3 },
  ]

  # ---------------------------------------------------------------------------
  # ScyllaDB 節點的資料碟（規劃書 §2.2 新增的 scylla 列）——抽成 local 讓
  # scylla-01..03 完全一致（NTS RF=3 三節點對稱，規格分歧只會製造難查的偏斜）。
  #
  # 單顆 500 GB 資料碟，掛「自己專屬的 PVSCSI 控制器」（1 號；0 號留給 OS 碟）：
  # commitlog 順序寫與 sstable 隨機讀 / 壓實同時發生，獨立控制器讓資料 IO 不與
  # OS 碟擠同一佇列。thick（thin=false）：資料庫碟不賭 datastore 超賣；
  # independent_persistent：排除在 VM 快照外（§2.3）。整台放 datastore_ssd
  # （比照 pg，LSM 隨機讀寫對延遲敏感）。Guest 內 mkfs.xfs + 用 UUID 寫 fstab
  # 掛到資料目錄一樣交給 block_storage role（05-block-storage 階段，依容量認碟）
  # ——與 pg / mq 完全同構。
  # ---------------------------------------------------------------------------
  scylla_extra_disks = [
    { label = "disk1-scylladata", size_gb = 500, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
  ]

  # ---------------------------------------------------------------------------
  # SeaweedFS 節點的資料碟——抽成 local 讓 sw-01..03 完全一致。
  # 單顆 1000 GB（volume 資料 + idx），獨立 PVSCSI 控制器（1 號）。
  # thin=true 沿用 nfs-01 的理由：物件資料是逐步長大的冷資料，thick 一次吃掉
  # 1TB×3 太浪費；配套是 datastore 容量告警。independent_persistent：
  # 排除在 VM 快照外（有狀態資料，備援靠 replication=010 跨節點 2 副本）。
  # 不佔 SSD datastore：EC/複寫是吞吐型負載，非 fsync 延遲敏感（對比 pg/scylla）。
  # Guest 內 mkfs.xfs + UUID fstab 掛到 /var/lib/seaweedfs 由 block_storage
  # role 處理（05 階段，依容量認碟）——與 pg/mq/scylla 完全同構。
  # ---------------------------------------------------------------------------
  sw_extra_disks = [
    { label = "disk1-seaweedfs", size_gb = 1000, thin = true, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
  ]

  # ---------------------------------------------------------------------------
  # VM 完整清單（規劃書 §2.2 資源配額表 + VLAN 50 的 2 台 DevOps 機）
  #
  # 欄位說明：
  #   cpu / memory_mb / os_disk_gb : 配額表逐欄照抄（記憶體單位 MB！8 GB = 8192）
  #   vlan / ipv4                  : CONVENTIONS.md §2 IP 表逐台照抄
  #   datastore                    : pg 整台放 SSD（fsync 敏感），其餘一般 datastore
  #   extra_disks                  : 有狀態資料碟；規格見各台註解
  # ---------------------------------------------------------------------------
  vms = {

    # ---- 邊界層（VLAN 10）：HAProxy + Keepalived + Squid，無狀態、可隨時重建 ----
    "lb-01" = {
      cpu       = 2, memory_mb = 4096, os_disk_gb = 40
      vlan      = 10, ipv4 = "10.20.10.11"
      datastore = var.datastore, extra_disks = []
    }
    "lb-02" = {
      cpu       = 2, memory_mb = 4096, os_disk_gb = 40
      vlan      = 10, ipv4 = "10.20.10.12"
      datastore = var.datastore, extra_disks = []
    }

    # ---- 應用層（VLAN 20）：Kong API Gateway（DB-less，無狀態） ----
    # 規格比照 lb（同為無狀態 L7 元件）；宣告式組態在 Git、容器由 Ansible 管
    "kong-01" = {
      cpu       = 2, memory_mb = 4096, os_disk_gb = 40
      vlan      = 20, ipv4 = "10.20.20.21"
      datastore = var.datastore, extra_disks = []
    }
    "kong-02" = {
      cpu       = 2, memory_mb = 4096, os_disk_gb = 40
      vlan      = 20, ipv4 = "10.20.20.22"
      datastore = var.datastore, extra_disks = []
    }

    # ---- 應用層（VLAN 20）：email_proxy 專案 app（api/worker/smtp + 同居 KeyDB） ----
    # KeyDB 是純快取（TTL 語意）不切資料碟，用 OS 碟即可
    "app-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 60
      vlan      = 20, ipv4 = "10.20.20.11"
      datastore = var.datastore, extra_disks = []
    }
    "app-02" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 60
      vlan      = 20, ipv4 = "10.20.20.12"
      datastore = var.datastore, extra_disks = []
    }
    "app-03" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 60
      vlan      = 20, ipv4 = "10.20.20.13"
      datastore = var.datastore, extra_disks = []
    }

    # ---- 資料層（VLAN 30）：Patroni/PG18 + etcd + PgBouncer + HAProxy ----
    # 整台（含三顆資料碟）放 SSD datastore：etcd 的 fdatasync 延遲直接決定
    # Patroni 穩定度（規劃書 §2.1 註）。三顆資料碟規格見上面 pg_extra_disks。
    "pg-01" = {
      cpu       = 6, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.11"
      datastore = var.datastore_ssd, extra_disks = local.pg_extra_disks
    }
    "pg-02" = {
      cpu       = 6, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.12"
      datastore = var.datastore_ssd, extra_disks = local.pg_extra_disks
    }
    "pg-03" = {
      cpu       = 6, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.13"
      datastore = var.datastore_ssd, extra_disks = local.pg_extra_disks
    }

    # ---- 資料層（VLAN 30）：RabbitMQ 4.x quorum queue 叢集 ----
    # 100 GB 佇列資料碟：thick + independent_persistent（有狀態，快照排除）
    "mq-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.21"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-mqdata", size_gb = 100, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }
    "mq-02" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.22"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-mqdata", size_gb = 100, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }
    "mq-03" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.23"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-mqdata", size_gb = 100, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }

    # ---- 資料層（VLAN 30）：ScyllaDB 2026.1 寬欄叢集（NTS RF=3，無 VIP） ----
    # 拓撲承襲 MIS scylladb-1..3；整台放 SSD datastore（LSM 隨機讀寫 + 壓實對
    # 延遲敏感，比照 pg）。單顆 500 GB 資料碟規格見上面 scylla_extra_disks。
    "scylla-01" = {
      cpu       = 4, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.31"
      datastore = var.datastore_ssd, extra_disks = local.scylla_extra_disks
    }
    "scylla-02" = {
      cpu       = 4, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.32"
      datastore = var.datastore_ssd, extra_disks = local.scylla_extra_disks
    }
    "scylla-03" = {
      cpu       = 4, memory_mb = 16384, os_disk_gb = 40
      vlan      = 30, ipv4 = "10.20.30.33"
      datastore = var.datastore_ssd, extra_disks = local.scylla_extra_disks
    }

    # ---- 儲存層（VLAN 40）：NFSv4.1 附件 + PG 備份庫 ----
    # 1 TB 附件/備份碟（規劃書 §2.2 給 500GB–1TB 區間，取上限）：
    # thin=true 是刻意的——附件是逐步長大的冷資料，thick 一次吃掉 1 TB 太浪費；
    # 配套是 datastore 容量告警（監控 role 的 vSphere exporter 會看）
    "nfs-01" = {
      cpu       = 2, memory_mb = 8192, os_disk_gb = 40
      vlan      = 40, ipv4 = "10.20.40.11"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-attachments", size_gb = 1024, thin = true, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }

    # ---- 儲存層（VLAN 40）：SeaweedFS S3 物件儲存 ×3（master raft + volume + filer + s3） ----
    # filer 元資料在 PG（不佔本地碟）；volume 資料碟規格見上面 sw_extra_disks
    "sw-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 40, ipv4 = "10.20.40.21"
      datastore = var.datastore, extra_disks = local.sw_extra_disks
    }
    "sw-02" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 40, ipv4 = "10.20.40.22"
      datastore = var.datastore, extra_disks = local.sw_extra_disks
    }
    "sw-03" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 40
      vlan      = 40, ipv4 = "10.20.40.23"
      datastore = var.datastore, extra_disks = local.sw_extra_disks
    }

    # ---- 管理層（VLAN 99）：Ansible 控制 + Issuing CA + Prometheus/Grafana ----
    # 200 GB 監控 TSDB 碟。TSDB 可重建（丟了只是少歷史曲線），但仍設
    # independent_persistent：TSDB 的持續寫入會讓 VM 快照 delta 暴長
    "mgmt-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 100
      vlan      = 99, ipv4 = "10.20.99.11"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-monitoring", size_gb = 200, thin = true, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }

    # ---- DevOps 層（VLAN 50）：GitLab CE + Registry / Runner（lab 不部署） ----
    # gitlab 資料碟（repo + registry + artifacts）：有狀態，thick + 快照排除
    "gitlab-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 100
      vlan      = 50, ipv4 = "10.20.50.11"
      datastore = var.datastore
      extra_disks = [
        { label = "disk1-gitlab-data", size_gb = 200, thin = false, independent_persistent = true, unit_number = 0, scsi_controller = 1 },
      ]
    }
    # runner 完全無狀態（docker executor 的工作區用完即棄），不切資料碟
    "runner-01" = {
      cpu       = 4, memory_mb = 8192, os_disk_gb = 60
      vlan      = 50, ipv4 = "10.20.50.12"
      datastore = var.datastore, extra_disks = []
    }
  }
}

# ---- 模組組裝 ------------------------------------------------------------------

# (1) 網路：6 個 VLAN port group（掛在既存 vDS 上）
module "network" {
  source = "../../modules/network"

  datacenter = var.datacenter
  vds_name   = var.vds_name
  vlans      = local.vlans
}

# (2) VM：23 台全部走同一個泛用模組，差異收斂在 local.vms
module "vm" {
  source   = "../../modules/vm"
  for_each = local.vms

  name          = each.key
  datacenter    = var.datacenter
  cluster       = var.cluster
  datastore     = each.value.datastore
  folder        = vsphere_folder.platform.path
  template_name = var.template_name

  cpu         = each.value.cpu
  memory_mb   = each.value.memory_mb
  os_disk_gb  = each.value.os_disk_gb
  extra_disks = each.value.extra_disks

  # 引用 network 模組的 output（而不是自己拼字串）建立隱式依賴：
  # 保證「先有 port group，VM 才查得到網路」
  networks = [{
    port_group = module.network.port_group_names[local.vlan_port_group[each.value.vlan]]
    ipv4       = each.value.ipv4
    netmask    = var.vlan_prefix_length
    gateway    = var.vlan_gateways[tostring(each.value.vlan)]
  }]
  vds_uuid = module.network.vds_uuid

  domain             = var.domain
  ansible_public_key = var.ansible_public_key
  dns_servers        = var.dns_servers
}

# (3) 反親和規則 ×7（AA-postgres / AA-rabbitmq / AA-scylladb / AA-seaweedfs /
#     AA-app / AA-lb / AA-kong）
# mandatory 維持模組預設 false（should 規則）：3 台 ESXi 剛好等於叢集成員數，
# must 規則會擋維護模式 vMotion 與 HA 故障重啟——取捨的完整說明見
# modules/anti_affinity/variables.tf。

module "aa_postgres" {
  source = "../../modules/anti_affinity"

  name               = "AA-postgres"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # Patroni + etcd quorum：掉 2 個節點才失去多數，所以 3 台必須在 3 台 ESXi 上
  vm_ids = [for h in ["pg-01", "pg-02", "pg-03"] : module.vm[h].id]
}

module "aa_rabbitmq" {
  source = "../../modules/anti_affinity"

  name               = "AA-rabbitmq"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # RabbitMQ quorum queue 靠 Raft 多數，同上
  vm_ids = [for h in ["mq-01", "mq-02", "mq-03"] : module.vm[h].id]
}

module "aa_scylladb" {
  source = "../../modules/anti_affinity"

  name               = "AA-scylladb"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # NTS RF=3 + QUORUM 讀寫：掉 2 個節點才失去多數，3 台必須在 3 台 ESXi 上
  vm_ids = [for h in ["scylla-01", "scylla-02", "scylla-03"] : module.vm[h].id]
}

module "aa_app" {
  source = "../../modules/anti_affinity"

  name               = "AA-app"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # app 本身無狀態，但「同居的 KeyDB cluster」（3 master + 3 replica）也要分散
  vm_ids = [for h in ["app-01", "app-02", "app-03"] : module.vm[h].id]
}

module "aa_lb" {
  source = "../../modules/anti_affinity"

  name               = "AA-lb"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # Keepalived VIP 主備不可同機，否則一台 ESXi 故障 = 服務入口全滅
  vm_ids = [for h in ["lb-01", "lb-02"] : module.vm[h].id]
}

module "aa_kong" {
  source = "../../modules/anti_affinity"

  name               = "AA-kong"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # 理由同 AA-lb：VI_KONG 主備不可同機，否則一台 ESXi 故障 = 東西向 API 入口全滅
  vm_ids = [for h in ["kong-01", "kong-02"] : module.vm[h].id]
}

module "aa_seaweedfs" {
  source = "../../modules/anti_affinity"

  name               = "AA-seaweedfs"
  compute_cluster_id = data.vsphere_compute_cluster.cluster.id
  # master raft 多數 + replication=010 的兩副本落點：3 台必須在 3 台 ESXi 上，
  # 否則一台 ESXi 故障可能同時帶走某物件的兩份副本
  vm_ids = [for h in ["sw-01", "sw-02", "sw-03"] : module.vm[h].id]
}
