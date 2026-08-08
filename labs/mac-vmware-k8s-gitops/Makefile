SHELL := /bin/bash

LAB_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF_DIR := $(LAB_DIR)/terraform
ANSIBLE_DIR := $(LAB_DIR)/ansible
KUBECONFIG := $(LAB_DIR)/artifacts/kubeconfig

CILIUM_VERSION ?= 1.19.4
METALLB_CHART_VERSION ?= 0.16.1
ARGOCD_CHART_VERSION ?= 9.5.17
GATEWAY_API_VERSION ?= v1.4.0

.PHONY: help doctor tf-init tf-plan tf-apply ansible-check ansible-apply kube-status platform-bootstrap gitops-bootstrap verify destroy

help:
	@awk 'BEGIN {FS = ":.*## "; printf "\nMac → VMware → K8s GitOps Lab\n\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## 檢查 Mac 控制站需要的 CLI
	@for command in terraform ansible-playbook kubectl helm ssh; do command -v $$command >/dev/null || { echo "missing: $$command"; exit 1; }; done
	@echo "control workstation is ready"

tf-init: ## 初始化 vSphere provider
	terraform -chdir=$(TF_DIR) init

tf-plan: ## 預覽三台 VM 變更
	terraform -chdir=$(TF_DIR) plan

tf-apply: ## 建立三台 Ubuntu VM 並產生 Ansible inventory
	terraform -chdir=$(TF_DIR) apply

ansible-check: ## 只做 Ansible 語法與 dry-run
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check playbooks/site.yml
	cd $(ANSIBLE_DIR) && ansible-playbook --check playbooks/01-node-baseline.yml

ansible-apply: ## 設定 Ubuntu、containerd 並以 kubeadm 建立叢集
	mkdir -p $(LAB_DIR)/artifacts
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml

kube-status: ## 檢查節點與系統 Pod
	KUBECONFIG=$(KUBECONFIG) kubectl get nodes -o wide
	KUBECONFIG=$(KUBECONFIG) kubectl get pods -A

platform-bootstrap: ## 安裝 Gateway API、Cilium、MetalLB 與 Argo CD
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	helm repo add cilium https://helm.cilium.io --force-update
	helm repo add metallb https://metallb.github.io/metallb --force-update
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update
	KUBECONFIG=$(KUBECONFIG) helm upgrade --install cilium cilium/cilium --namespace kube-system --version $(CILIUM_VERSION) --values $(LAB_DIR)/k8s/platform/cilium-values.yaml --wait --timeout 10m
	KUBECONFIG=$(KUBECONFIG) helm upgrade --install metallb metallb/metallb --namespace metallb-system --create-namespace --version $(METALLB_CHART_VERSION) --wait --timeout 10m
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f $(LAB_DIR)/k8s/platform/metallb-pool.yaml
	KUBECONFIG=$(KUBECONFIG) helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --version $(ARGOCD_CHART_VERSION) --values $(LAB_DIR)/k8s/platform/argocd-values.yaml --wait --timeout 15m

gitops-bootstrap: ## 種下唯一需要手動套用的 Argo CD root app
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f $(LAB_DIR)/gitops/bootstrap/root-app.yaml

verify: ## 驗收 Node、CNI、Argo CD、Go API 與 PostgreSQL
	KUBECONFIG=$(KUBECONFIG) kubectl wait --for=condition=Ready nodes --all --timeout=5m
	KUBECONFIG=$(KUBECONFIG) kubectl -n argocd get applications
	KUBECONFIG=$(KUBECONFIG) kubectl -n go-api get deploy,po,svc,httproute,pdb,hpa
	KUBECONFIG=$(KUBECONFIG) kubectl -n data get clusters.postgresql.cnpg.io,pods,poolers.postgresql.cnpg.io

destroy: ## 只顯示 Terraform destroy plan；實際刪除需手動確認
	terraform -chdir=$(TF_DIR) plan -destroy

