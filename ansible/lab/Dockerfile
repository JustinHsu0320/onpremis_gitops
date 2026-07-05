# =============================================================================
# lab/Dockerfile — 實驗室節點基底映像（ubuntu:26.04 LTS + systemd + sshd）
#
# 設計目標：讓一個 Docker 容器「長得像一台 VM」——
#   - 跑完整 systemd（PID 1），服務用 systemctl 管理，與 prod 行為一致
#   - 有 sshd + ansible 使用者（公鑰 + sudoers NOPASSWD），與 prod 的
#     VM template cloud-init（見 terraform/modules/vm）產出的狀態一致
#   - 兩個 build target：base（12 台節點用）與 controller（mgmt-01 加裝 ansible）
#
# 注意：這個映像只用於實驗室。prod 的 VM 由 Terraform clone template 產生。
# =============================================================================
FROM ubuntu:26.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# systemd + sshd + python3（Ansible 目標機的最低要求）+ 常用診斷工具
# 之所以在映像先裝好：13 台節點同時 apt install 會把 Docker VM 的網路打爆，
# 基線套件進映像一次搞定，playbook 只補差異
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server sudo \
        python3 python3-apt \
        iproute2 iputils-ping curl ca-certificates gnupg \
        vim-tiny less procps \
    && rm -rf /var/lib/apt/lists/*

# 遮蔽在容器內沒有意義、只會拖慢開機或報錯的 systemd 單元
# （udev 管硬體熱插拔、modules-load 載 kernel 模組——容器共用宿主 kernel，都不適用）
RUN systemctl mask \
        systemd-udevd.service \
        systemd-udevd-kernel.socket \
        systemd-udevd-control.socket \
        systemd-udev-trigger.service \
        systemd-modules-load.service \
        systemd-networkd-wait-online.service \
        getty@tty1.service \
        console-getty.service

# ansible 自動化帳號：與 prod cloud-init 完全同構
#   - 公鑰登入（金鑰由 lab-build.sh 現場產生，不進 Git）
#   - sudoers NOPASSWD（ansible.cfg 的 become_ask_pass=False 依賴這個）
RUN useradd -m -s /bin/bash ansible \
    && mkdir -p /home/ansible/.ssh \
    && chmod 700 /home/ansible/.ssh \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ansible \
    && chmod 440 /etc/sudoers.d/90-ansible
COPY .ssh/id_lab.pub /home/ansible/.ssh/authorized_keys
RUN chown -R ansible:ansible /home/ansible/.ssh \
    && chmod 600 /home/ansible/.ssh/authorized_keys

# sshd 需要的執行期目錄
RUN mkdir -p /run/sshd

# systemd 當 PID 1；SIGRTMIN+3 是 systemd 的優雅關機信號（compose 的 stop_signal 對應）
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]

# =============================================================================
# controller — mgmt-01 專用：在 base 之上加 Ansible 控制節點工具鏈
# （collections 不裝進映像：repo 的 ansible/collections 已含全部依賴，
#   由 bind mount 進來，ansible.cfg 的 collections_path 直接指到它）
# =============================================================================
FROM base AS controller

RUN apt-get update && apt-get install -y --no-install-recommends \
        ansible-core \
        openssh-client git make jq \
        python3-requests python3-yaml \
    && rm -rf /var/lib/apt/lists/*
