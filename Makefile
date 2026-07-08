# =============================================================================
# Makefile — 全 repo 統一操作入口
#
# 慣例：所有指令都在 repo 根目錄執行。`make help` 列出所有目標。
# 工具鏈：Ansible 用本機（或 venv，設 BIN=<venv>/bin/）；
#         Terraform / kubeconform 用官方 Docker image（不污染本機）。
# =============================================================================

# 若 ansible 裝在 venv，執行時帶 BIN 前綴：make lint BIN=~/venv/bin/
BIN ?=
ANSIBLE          := $(BIN)ansible
ANSIBLE_PLAYBOOK := $(BIN)ansible-playbook
ANSIBLE_GALAXY   := $(BIN)ansible-galaxy
ANSIBLE_LINT     := $(BIN)ansible-lint
YAMLLINT         := $(BIN)yamllint

LAB_INV  := inventories/lab/hosts.yml
TF_IMAGE := hashicorp/terraform:1.9
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:latest

.PHONY: help deps lint syntax check-all tf-validate argocd-validate \
        lab-build lab-up lab-deploy lab-verify lab-destroy lab-sh

help: ## 列出所有目標
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------- 依賴 ----------
deps: ## 安裝 Ansible collections 到 ansible/collections/
	cd ansible && $(ANSIBLE_GALAXY) collection install -r requirements.yml -p collections

# ---------- 靜態檢查（CI 的 validate 階段跑的就是這些） ----------
lint: ## yamllint + ansible-lint
	$(YAMLLINT) .
	cd ansible && $(ANSIBLE_LINT) playbooks/

syntax: ## 兩套 inventory 的 playbook 語法檢查
	cd ansible && $(ANSIBLE_PLAYBOOK) --syntax-check playbooks/site.yml
	cd ansible && $(ANSIBLE_PLAYBOOK) -i $(LAB_INV) --syntax-check playbooks/site.yml

tf-validate: ## Terraform fmt 檢查 + validate（官方 image，無需本機安裝）
	docker run --rm -v $(PWD)/terraform:/tf -w /tf/environments/prod $(TF_IMAGE) init -backend=false -input=false
	docker run --rm -v $(PWD)/terraform:/tf -w /tf $(TF_IMAGE) fmt -check -recursive
	docker run --rm -v $(PWD)/terraform:/tf -w /tf/environments/prod $(TF_IMAGE) validate

argocd-validate: ## ArgoCD/K8s manifests 結構驗證（kubeconform）
	docker run --rm -v $(PWD)/argocd:/manifests $(KUBECONFORM_IMAGE) \
	  -strict -ignore-missing-schemas -summary /manifests

check-all: lint syntax tf-validate argocd-validate ## 全部靜態檢查

# ---------- Docker 實驗室（16 節點 ubuntu:26.04 systemd + 5 VLAN） ----------
lab-build: ## 建置實驗室基底映像 + 產生 SSH 金鑰
	cd ansible/lab && ./lab-build.sh

lab-up: lab-build ## 啟動 16 節點實驗室拓撲
	cd ansible/lab && docker compose up -d && ./lab-wait-ready.sh

lab-deploy: ## 在 mgmt-01 內對整個實驗室跑 site.yml（真正的端到端部署）
	docker exec email-proxy-mgmt-01 bash -lc \
	  'cd /work/ansible && ansible-playbook -i $(LAB_INV) playbooks/site.yml'

lab-verify: ## 只跑全鏈健檢
	docker exec email-proxy-mgmt-01 bash -lc \
	  'cd /work/ansible && ansible-playbook -i $(LAB_INV) playbooks/99-verify.yml'

lab-sh: ## 進入 mgmt-01（實驗室的 Ansible 控制節點）
	docker exec -it email-proxy-mgmt-01 bash

lab-destroy: ## 銷毀實驗室（含 volume）
	cd ansible/lab && docker compose down -v --remove-orphans
