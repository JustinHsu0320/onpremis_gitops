#!/usr/bin/env bash

set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ROOT="$(cd "${LAB_DIR}/.." && pwd)"
ARTIFACTS_DIR="${LAB_ROOT}/artifacts/container-lab"
KUBECONFIG_PATH="${ARTIFACTS_DIR}/kubeconfig"

CLUSTER_NAME="${CONTAINER_LAB_CLUSTER_NAME:-container-lab}"
REGISTRY_NAME="${CONTAINER_LAB_REGISTRY_NAME:-container-lab-registry}"
REGISTRY_PORT="${CONTAINER_LAB_REGISTRY_PORT:-5001}"
GIT_NAME="${CONTAINER_LAB_GIT_NAME:-container-lab-git}"
GIT_IMAGE="${CONTAINER_LAB_GIT_IMAGE:-alpine/git:latest}"
GIT_SERVER_IMAGE="localhost:${REGISTRY_PORT}/container-lab-git:container"
GIT_WORKTREE="${ARTIFACTS_DIR}/git-source"
GIT_BARE="${ARTIFACTS_DIR}/repo.git"
IMAGE="localhost:${REGISTRY_PORT}/onprem-go-api:container"
CNPG_VERSION="${CONTAINER_LAB_CNPG_VERSION:-0.26.0}"

export KUBECONFIG="${KUBECONFIG_PATH}"

log() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null || {
    printf 'missing command: %s\n' "$1" >&2
    exit 1
  }
}

require_commands() {
  require_command docker
  require_command helm
  require_command kubectl
  require_command kind
  require_command git
  require_command curl
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"
}

registry_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" == "true" ]]
}

ensure_registry() {
  log "ensure local registry ${REGISTRY_NAME}"
  if ! registry_running; then
    docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
    docker run -d --restart=always \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      --network bridge \
      --name "${REGISTRY_NAME}" \
      registry:3 >/dev/null
  fi
}

ensure_cluster() {
  mkdir -p "${ARTIFACTS_DIR}"
  if ! cluster_exists; then
    log "create kind cluster ${CLUSTER_NAME}"
    kind create cluster \
      --name "${CLUSTER_NAME}" \
      --config "${LAB_DIR}/kind-config.yaml"
  else
    log "reuse kind cluster ${CLUSTER_NAME}"
  fi

  kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
  chmod 600 "${KUBECONFIG_PATH}"

  for _ in {1..60}; do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl get --raw=/readyz >/dev/null

  if ! docker network inspect kind >/dev/null 2>&1; then
    printf 'kind Docker network is missing\n' >&2
    exit 1
  fi
  docker network connect kind "${REGISTRY_NAME}" >/dev/null 2>&1 || true

  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    docker exec "${node}" mkdir -p "/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
    printf '[host."http://%s:5000"]\n' "${REGISTRY_NAME}" | \
      docker exec -i "${node}" sh -c \
        "cat > /etc/containerd/certs.d/localhost:${REGISTRY_PORT}/hosts.toml"
  done

  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

  # Existing clusters created before the kubeadm patch may still have the
  # default control-plane NoSchedule taint.
  kubectl taint node "${CLUSTER_NAME}-control-plane" \
    node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
}

install_cilium() {
  log "install Gateway API and Cilium"
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml >/dev/null
  helm repo add cilium https://helm.cilium.io --force-update >/dev/null
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version 1.19.4 \
    --values "${LAB_DIR}/k8s/cilium-values.yaml" \
    --set "k8sServiceHost=${CLUSTER_NAME}-control-plane" \
    --set k8sServicePort=6443 \
    --wait --timeout 10m
  kubectl wait --for=condition=Ready nodes --all --timeout=5m
  kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
}

install_metallb() {
  log "install MetalLB controller/speaker (no LAN ARP assertion)"
  helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
  helm repo update metallb >/dev/null
  if ! helm upgrade --install metallb metallb/metallb \
      --namespace metallb-system \
      --create-namespace \
      --version 0.16.1 \
      --wait --timeout 5m; then
    # MetalLB creates the memberlist Secret from the controller while the
    # speaker DaemonSet is already being scheduled. Recreate stale speakers
    # before retrying the same idempotent Helm release.
    kubectl -n metallb-system delete pod \
      -l app.kubernetes.io/component=speaker \
      --ignore-not-found >/dev/null
    helm upgrade --install metallb metallb/metallb \
      --namespace metallb-system \
      --create-namespace \
      --version 0.16.1 \
      --wait --timeout 5m
  fi
  kubectl apply -f "${LAB_DIR}/k8s/metallb-pool.yaml" >/dev/null
}

install_argocd() {
  log "install Argo CD"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --version 9.5.17 \
    --values "${LAB_DIR}/k8s/argocd-values.yaml" \
    --wait --timeout 15m
}

install_cnpg_crds() {
  log "bootstrap CloudNativePG CRDs with server-side apply"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
  helm repo update cnpg >/dev/null
  helm template cnpg cnpg/cloudnative-pg \
    --version "${CNPG_VERSION}" \
    --include-crds | awk '
      function flush() {
        if (doc ~ /kind: CustomResourceDefinition/) printf "%s", doc
        doc = ""
      }
      /^---$/ { flush(); doc = "---\n"; next }
      { doc = doc $0 "\n" }
      END { flush() }
    ' | kubectl apply --server-side --force-conflicts \
      --field-manager=container-lab-cnpg-crds -f - >/dev/null
}

prepare_git_source() {
  log "prepare ephemeral Git source for Argo CD"
  rm -rf "${GIT_WORKTREE}" "${GIT_BARE}"
  mkdir -p "${GIT_WORKTREE}"
  cp -R "${LAB_DIR}" "${GIT_WORKTREE}/container-lab"
  cp -R "${LAB_ROOT}/k8s" "${GIT_WORKTREE}/k8s"
  git -C "${GIT_WORKTREE}" init -b main >/dev/null
  git -C "${GIT_WORKTREE}" config user.name container-lab
  git -C "${GIT_WORKTREE}" config user.email container-lab@localhost
  git -C "${GIT_WORKTREE}" add container-lab k8s
  git -C "${GIT_WORKTREE}" commit -m 'container lab source' >/dev/null
  git clone --bare "${GIT_WORKTREE}" "${GIT_BARE}" >/dev/null
}

build_git_server_image() {
  log "build and push Kubernetes Git daemon image ${GIT_SERVER_IMAGE}"
  cat > "${ARTIFACTS_DIR}/Dockerfile.git" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache git-daemon \
    && addgroup -S -g 1000 git \
    && adduser -S -D -H -u 1000 -G git git
COPY repo.git /srv/git/repo.git
RUN chown -R 1000:1000 /srv/git
USER 1000:1000
ENTRYPOINT ["/usr/libexec/git-core/git-daemon", "--reuseaddr", "--base-path=/srv/git", "--export-all", "--informative-errors", "--verbose"]
EOF
  docker build -f "${ARTIFACTS_DIR}/Dockerfile.git" \
    -t "${GIT_SERVER_IMAGE}" "${ARTIFACTS_DIR}"
  docker push "${GIT_SERVER_IMAGE}"
  kind load docker-image "${GIT_SERVER_IMAGE}" --name "${CLUSTER_NAME}" >/dev/null
  kubectl apply -f "${LAB_DIR}/k8s/git-server.yaml"
  kubectl -n git rollout restart deployment/container-lab-git
  kubectl -n git rollout status deployment/container-lab-git --timeout=5m
}

build_and_push_image() {
  log "build and push Go API image ${IMAGE}"
  docker build -t "${IMAGE}" "${LAB_ROOT}/apps/go-api"
  docker push "${IMAGE}"
  kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}" >/dev/null
}

bootstrap_gitops() {
  prepare_git_source
  build_git_server_image
  build_and_push_image
  install_cnpg_crds
  log "apply Argo CD root application"
  kubectl apply -f "${LAB_DIR}/gitops/bootstrap/root-app.yaml"
  kubectl -n argocd annotate application --all \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

platform() {
  ensure_cluster
  install_cilium
  install_metallb
  install_argocd
}

verify() {
  log "verify nodes, storage and workloads"
  kubectl get nodes -o wide
  kubectl get storageclass
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/cnpg-operator --timeout=10m
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/monitoring --timeout=10m
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/app-postgres --timeout=10m
  kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/go-api --timeout=10m
  kubectl -n go-api wait --for=condition=Available deployment/go-api --timeout=10m
  kubectl -n data wait --for=condition=Ready cluster/app-postgres --timeout=10m
  kubectl -n monitoring get pods
  kubectl -n go-api get deploy,po,svc,servicemonitor
  kubectl -n data get clusters.postgresql.cnpg.io,pods,poolers.postgresql.cnpg.io

  local forward_pid
  kubectl -n go-api port-forward svc/go-api 18081:80 >"${ARTIFACTS_DIR}/port-forward.log" 2>&1 &
  forward_pid=$!
  trap 'kill "${forward_pid:-}" >/dev/null 2>&1 || true' RETURN
  for _ in {1..30}; do
    if curl --fail --silent http://127.0.0.1:18081/healthz >/dev/null; then
      break
    fi
    sleep 2
  done
  printf 'go-api healthz='; curl --fail --silent --show-error -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/healthz
  printf 'go-api root='; curl --fail --silent --show-error -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/
}

status() {
  ensure_cluster
  kubectl get nodes -o wide
  kubectl get pods -A
  kubectl -n argocd get applications 2>/dev/null || true
}

down() {
  log "delete container lab"
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${REGISTRY_NAME}" "${GIT_NAME}" >/dev/null 2>&1 || true
  rm -rf "${ARTIFACTS_DIR}"
}

main() {
  require_commands
  case "${1:-all}" in
    up)
      ensure_registry
      ensure_cluster
      ;;
    platform)
      platform
      ;;
    gitops)
      ensure_cluster
      bootstrap_gitops
      ;;
    verify)
      verify
      ;;
    status)
      status
      ;;
    down)
      down
      ;;
    all)
      ensure_registry
      platform
      bootstrap_gitops
      verify
      ;;
    *)
      printf 'usage: %s {all|up|platform|gitops|verify|status|down}\n' "$0" >&2
      exit 2
      ;;
  esac
}

main "$@"
