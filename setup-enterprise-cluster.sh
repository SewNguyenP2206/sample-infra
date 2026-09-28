#!/usr/bin/env bash
###############################################################################
# setup-enterprise-cluster.sh 
#
# Dựng cụm Kind mô phỏng enterprise DevOps platform. Mỗi thành phần là 1
# "service" được đánh số; có thể cài tất cả, cài một vài service, hoặc TẠO LẠI
# (xoá + cài lại) service bị lỗi mà không phải dựng lại cả cụm.
#
# CÁCH DÙNG
#   ./setup-enterprise-cluster.sh                    # mở menu tương tác
#   ./setup-enterprise-cluster.sh all                # cài tất cả (bỏ qua SKIP_IN_ALL)
#   ./setup-enterprise-cluster.sh install 5,7        # cài service số 5 và 7
#   ./setup-enterprise-cluster.sh install 3-5        # cài từ 3 đến 5
#   ./setup-enterprise-cluster.sh recreate 7         # xoá + cài lại service 7
#   ./setup-enterprise-cluster.sh recreate ALL       # tạo lại tất cả
#   ./setup-enterprise-cluster.sh status             # xem trạng thái
#   Thêm -y để bỏ qua mọi câu hỏi xác nhận (chạy không tương tác)
###############################################################################
set -uo pipefail
set -E   # để ERR trap cũng chạy bên trong các hàm

# ============================== CONFIG ======================================
CLUSTER_NAME="desktop"
INFRA_DIR="${HOME}/enterprise/infra"
CONTAINERD_CFG_DIR="${INFRA_DIR}/containerd-config"

HARBOR_VALUES="${INFRA_DIR}/helm/harbor/harbor-values.yaml"
HARBOR_CERT_YAML="${INFRA_DIR}/helm/harbor/harbor-cert.yaml"
JENKINS_VALUES="${INFRA_DIR}/helm/jenkins/jenkins-values.yaml"
ARGOCD_INGRESS_YAML="${INFRA_DIR}/k8s/argoCD/argocd-ingress.yaml"
ARGOCD_APP_YAML="${INFRA_DIR}/k8s/argoCD/argocd-app.yaml"
ARGOCD_FE_YAML="${INFRA_DIR}/k8s/argoCD/argocd-fe.yaml"
GRAFANA_INGRESS_YAML="${INFRA_DIR}/k8s/monitoring/grafana-ingress.yaml"
KYVERNO_POLICY_YAML="${INFRA_DIR}/helm/kyverno/require-resource-limits.yaml"

ARGOCD_VERSION="v3.5.3"
HARBOR_ADMIN_PASSWORD="Harbor12345"
GRAFANA_ADMIN_PASSWORD="admin123"
WORKER_COUNT=3

# Service KHÔNG nằm trong "ALL" (vẫn chọn được bằng số). Monitoring khá nặng
# khi Docker chỉ có 8GB RAM nên mặc định không đưa vào ALL.
SKIP_IN_ALL_KEYS="monitoring"

# ============================== SERVICE REGISTRY ============================
# Thứ tự = thứ tự cài (phụ thuộc nhau); khi tạo lại sẽ xoá theo thứ tự ngược.
SVC_KEYS=(kind metallb ingress-nginx cert-manager jenkins argocd kyverno monitoring)
SVC_LABELS=(
  "Kind cluster (control-plane + workers)"
  "MetalLB (LoadBalancer L2 + strictARP)"
  "ingress-nginx (kind provider)"
  "cert-manager + selfsigned ClusterIssuer"
  "Jenkins + secret dockerhub-creds-dockerconfig"
  "ArgoCD + Applications (backend/frontend)"
  "Kyverno + policy require-resource-limits"
  "Monitoring (Prometheus + Grafana + Loki)"
)
SVC_NS=("" "metallb-system" "ingress-nginx" "cert-manager" "jenkins" "argocd" "kyverno" "monitoring")
TOTAL_SVC=${#SVC_KEYS[@]}

svc_num() { local i; for i in "${!SVC_KEYS[@]}"; do [ "${SVC_KEYS[$i]}" = "$1" ] && echo $((i+1)) && return; done; }
N_KIND=$(svc_num kind); N_INGRESS=$(svc_num ingress-nginx); N_NODEREG=$(svc_num node-registry)

# ============================== HELPERS =====================================
ERR_COUNT=0
AUTO_YES=false
SELECTED=()
RESULTS=()

log()   { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()    { echo -e "\033[1;32m   [OK] $*\033[0m"; }
warn()  { echo -e "\033[1;33m   [WARN] $*\033[0m"; }
fail()  { echo -e "\033[1;31m   [FAIL] $* — tiếp tục lệnh kế tiếp\033[0m"; return 1; }

# Không dừng toàn bộ script khi một lệnh thất bại; chỉ đếm để báo cáo cuối.
trap 'ERR_COUNT=$((ERR_COUNT+1)); warn "Lỗi lệnh tại dòng ${LINENO}: ${BASH_COMMAND} — tiếp tục lệnh kế tiếp"' ERR

confirm() {   # confirm "câu hỏi"  -> 0 nếu đồng ý (mặc định Y)
  $AUTO_YES && return 0
  [ -t 0 ] || return 0
  local ans; read -rp "   $1 [Y/n]: " ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

wait_ns_ready() {
  local ns="$1" timeout="${2:-180}" elapsed=0
  log "Đợi pods trong namespace '$ns' sẵn sàng (timeout ${timeout}s)..."
  while true; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      sleep 3; elapsed=$((elapsed+3))
      if [ "$elapsed" -ge "$timeout" ]; then fail "Namespace '$ns' không tồn tại sau ${timeout}s"; return 1; fi
      continue
    fi
    local total notready
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$total" -eq 0 ]; then
      sleep 3; elapsed=$((elapsed+3))
      if [ "$elapsed" -ge "$timeout" ]; then fail "Namespace '$ns' không có pod nào sau ${timeout}s"; return 1; fi
      continue
    fi
    notready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | { grep -vE 'Running|Completed' || true; } | wc -l)
    if [ "$notready" -eq 0 ]; then
      ok "Namespace '$ns': $total pod(s) đều Running/Completed"
      kubectl get pods -n "$ns"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      warn "Namespace '$ns' chưa sẵn sàng sau ${timeout}s — trạng thái hiện tại:"
      kubectl get pods -n "$ns"
      fail "Dừng đợi '$ns'."
      return 1
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
}

wait_ns_all_containers_ready() {
  local ns="$1" timeout="${2:-240}" elapsed=0
  log "Đợi TẤT CẢ container trong namespace '$ns' Ready (timeout ${timeout}s)..."
  while true; do
    local not_ready
    not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | awk '$3!="Completed"{split($2,a,"/"); if (a[1]!=a[2]) print}' | wc -l)
    if [ "$not_ready" -eq 0 ]; then
      ok "Namespace '$ns': mọi container đã Ready đầy đủ"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      warn "Còn container chưa Ready trong '$ns' sau ${timeout}s:"
      kubectl get pods -n "$ns"
      fail "Dừng đợi '$ns' (kubectl describe pod / logs để xem lý do)."
      return 1
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
}

require_file() {
  [ -f "$1" ] || { fail "Không tìm thấy file cần thiết: $1"; return 1; }
}

delete_ns() {   # xoá namespace và đợi biến mất (tối đa ~180s)
  local ns="$1" i
  kubectl get ns "$ns" >/dev/null 2>&1 || return 0
  kubectl delete ns "$ns" --wait=false >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    kubectl get ns "$ns" >/dev/null 2>&1 || { ok "Đã xoá namespace '$ns'"; return 0; }
    sleep 3
  done
  warn "Namespace '$ns' vẫn Terminating sau 180s (có thể kẹt finalizer): kubectl get ns $ns -o yaml"
  return 1
}

helm_remove() {  # helm_remove <release> <namespace>
  if helm status "$1" -n "$2" >/dev/null 2>&1; then
    helm uninstall "$1" -n "$2" >/dev/null 2>&1 && ok "helm uninstall $1" || warn "helm uninstall $1 thất bại"
  fi
}

wait_for_docker() {
  local timeout="${1:-90}" elapsed=0
  log "Kiểm tra Docker daemon đã sẵn sàng"
  hash -r
  while true; do
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      ok "Docker daemon đang chạy"; return 0
    fi
    if [ "$elapsed" -eq 0 ]; then
      warn "Docker chưa sẵn sàng — nếu lỗi 'docker: command not found' kéo dài:"
      warn "  Docker Desktop -> Settings -> Resources -> WSL Integration -> bật đúng distro này"
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      fail "Docker vẫn không sẵn sàng sau ${timeout}s."; return 1
    fi
    sleep 5; elapsed=$((elapsed+5)); hash -r
  done
}

# ============================== INSTALL / UNINSTALL: từng service ===========

# ---- 1. Kind cluster --------------------------------------------------------
install_kind() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    warn "Cluster '$CLUSTER_NAME' đã tồn tại — xoá để dựng lại sạch"
    kind delete cluster --name "$CLUSTER_NAME"
  fi

  local cfg="/tmp/kind-config-${CLUSTER_NAME}.yaml" i
  cat > "$cfg" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
      - containerPort: 443
        hostPort: 8443
    extraMounts:
      - hostPath: ${CONTAINERD_CFG_DIR}
        containerPath: /etc/containerd/certs.d
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          taints:
            - key: node-role.kubernetes.io/control-plane
              effect: NoSchedule
EOF
  for i in $(seq 1 "$WORKER_COUNT"); do
    cat >> "$cfg" <<EOF
  - role: worker
    extraMounts:
      - hostPath: ${CONTAINERD_CFG_DIR}
        containerPath: /etc/containerd/certs.d
EOF
  done

  kind create cluster --config "$cfg" || return 1

  log "Đợi toàn bộ node Ready"
  local notready=1
  for i in $(seq 1 30); do
    notready=$(kubectl get nodes --no-headers 2>/dev/null | { grep -v " Ready " || true; } | wc -l)
    [ "$notready" -eq 0 ] && break
    sleep 5
  done
  kubectl get nodes
  [ "$notready" -eq 0 ] || { fail "Có node chưa Ready — kiểm tra tay"; return 1; }
  ok "Tất cả node Ready"
}
uninstall_kind() { kind delete cluster --name "$CLUSTER_NAME" && ok "Đã xoá cluster '$CLUSTER_NAME'"; }

# ---- 2. MetalLB -------------------------------------------------------------
install_metallb() {
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
  wait_ns_ready "metallb-system" 120

  log "Bật strictARP cho kube-proxy (bắt buộc cho MetalLB L2 mode)"
  kubectl get configmap kube-proxy -n kube-system -o yaml \
    | sed -e "s/strictARP: false/strictARP: true/" \
    | kubectl apply -f - -n kube-system
  kubectl rollout restart daemonset kube-proxy -n kube-system
  kubectl rollout status daemonset kube-proxy -n kube-system --timeout=90s

  log "Lấy dải IP docker network 'kind' để tạo MetalLB pool (chỉ IPv4)"
  local subnet base pool
  subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' kind 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | head -1 || true)
  if [ -z "$subnet" ]; then
    warn "Không tự lấy được subnet IPv4 — dùng mặc định 172.18.0.0/16"
    pool="172.18.255.200-172.18.255.250"
  else
    base=$(echo "$subnet" | cut -d. -f1-2)
    pool="${base}.255.200-${base}.255.250"
  fi
  ok "MetalLB pool range: $pool"

  # webhook của MetalLB có thể chưa nhận request ngay -> retry
  local i
  for i in $(seq 1 10); do
    if cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${pool}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF
    then ok "MetalLB cấu hình xong"; return 0; fi
    warn "  Apply pool thất bại (lần $i/10) — đợi 6s..."; sleep 6
  done
  return 1
}
uninstall_metallb() {
  kubectl delete ipaddresspool,l2advertisement --all -n metallb-system --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  delete_ns metallb-system
}

# ---- 3. ingress-nginx -------------------------------------------------------
install_ingress_nginx() {
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml

  log "Patch toleration cho ingress-nginx (để chạy được trên control-plane đã taint)"
  sleep 5
  kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' \
    || warn "Patch toleration thất bại — kiểm tra tay nếu ingress-nginx không lên được"

  kubectl wait --namespace ingress-nginx --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller --timeout=180s
  wait_ns_ready "ingress-nginx" 60
  ok "ingress-nginx sẵn sàng"
}
uninstall_ingress_nginx() {
  kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  delete_ns ingress-nginx
}

# ---- 4. cert-manager --------------------------------------------------------
install_cert_manager() {
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  wait_ns_ready "cert-manager" 120
  kubectl wait --namespace cert-manager --for=condition=ready pod \
    --selector=app.kubernetes.io/instance=cert-manager --timeout=120s

  log "Chờ cert-manager webhook TLS sẵn sàng (probe thực tế, retry)..."
  local i webhook_ready=false
  for i in $(seq 1 20); do
    if kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'PROBE'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: webhook-probe-dummy
spec:
  selfSigned: {}
PROBE
    then
      webhook_ready=true; ok "cert-manager webhook đã sẵn sàng (sau $((i*5-5))s)"; break
    fi
    warn "  Webhook chưa sẵn sàng (lần $i/20) — đợi 5s..."; sleep 5
  done
  [ "$webhook_ready" = "true" ] || { warn "Webhook chưa phản hồi — đợi thêm 30s"; sleep 30; }

  local applied=false
  for i in $(seq 1 5); do
    if cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
    then applied=true; break; fi
    warn "  Apply ClusterIssuer thất bại (lần $i/5) — đợi 10s..."; sleep 10
  done
  [ "$applied" = "true" ] || { fail "Không apply được ClusterIssuer"; return 1; }

  local ready=""
  for i in $(seq 1 12); do
    ready=$(kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$ready" == "True" ] && break
    sleep 5
  done
  [ "$ready" == "True" ] || { fail "ClusterIssuer selfsigned-issuer không Ready"; return 1; }
  ok "cert-manager + ClusterIssuer sẵn sàng"
}
uninstall_cert_manager() {
  kubectl delete clusterissuer --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  delete_ns cert-manager
}

# ---- 5. Jenkins -------------------------------------------------------------
install_jenkins() {
  require_file "$JENKINS_VALUES" || return 1
  helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1
  helm repo update >/dev/null
  kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install jenkins jenkins/jenkins -n jenkins -f "$JENKINS_VALUES" || return 1

  log "Tạo Secret dockerhub-creds-dockerconfig cho Kaniko push"
  kubectl create secret docker-registry dockerhub-creds-dockerconfig \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=sewnguyen \
    --docker-password="dckr_pat_#####(UR dockerhub PAT)" \
    -n jenkins --dry-run=client -o yaml | kubectl apply -f -

  wait_ns_ready "jenkins" 300
  wait_ns_all_containers_ready "jenkins" 180
  ok "Jenkins đã lên"
}
uninstall_jenkins() {
  helm_remove jenkins jenkins
  kubectl delete pvc --all -n jenkins --ignore-not-found >/dev/null 2>&1 || true
  delete_ns jenkins
}

# ---- 8. ArgoCD --------------------------------------------------------------
install_argocd() {
  local url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  log "Cài ArgoCD ${ARGOCD_VERSION} bằng Server-Side Apply"
  kubectl apply -n argocd --server-side --force-conflicts -f "$url" || return 1

  log "Đợi ArgoCD server Ready"
  kubectl wait --namespace argocd --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argocd-server --timeout=240s
  wait_ns_ready "argocd" 180

  [ -f "$ARGOCD_INGRESS_YAML" ] && kubectl apply -f "$ARGOCD_INGRESS_YAML" && ok "Đã apply ArgoCD Ingress"

  echo -n "   ArgoCD admin password: "
  kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
  echo

  kubectl create namespace sample-backend  --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace sample-frontend --dry-run=client -o yaml | kubectl apply -f -

  if [ -f "$ARGOCD_APP_YAML" ]; then kubectl apply -f "$ARGOCD_APP_YAML" && ok "Đã apply ArgoCD Application (backend)"
  else warn "Chưa có $ARGOCD_APP_YAML — tự tạo Application sau"; fi
  if [ -f "$ARGOCD_FE_YAML" ]; then kubectl apply -f "$ARGOCD_FE_YAML" && ok "Đã apply ArgoCD Application (frontend)"
  else warn "Chưa có $ARGOCD_FE_YAML — tự tạo Application sau"; fi

  ok "ArgoCD ${ARGOCD_VERSION} sẵn sàng"
}
uninstall_argocd() {
  # Gỡ finalizer của Application để KHÔNG cascade-xoá workload đang chạy
  local app
  for app in $(kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null); do
    kubectl patch "$app" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl delete applications.argoproj.io --all -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  delete_ns argocd
}

# ---- 9. Kyverno -------------------------------------------------------------
install_kyverno() {
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1
  helm repo update >/dev/null
  kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install kyverno kyverno/kyverno -n kyverno || return 1

  wait_ns_ready "kyverno" 300
  wait_ns_all_containers_ready "kyverno" 180

  local pol="$KYVERNO_POLICY_YAML" i
  [ -f "$pol" ] || pol="${KYVERNO_POLICY_YAML}.yaml"   # phòng trường hợp tên file bị đôi đuôi .yaml.yaml
  if [ ! -f "$pol" ]; then
    warn "Không thấy file policy ($KYVERNO_POLICY_YAML) — bỏ qua bước apply policy"
    return 0
  fi
  for i in $(seq 1 6); do
    if kubectl apply -f "$pol"; then ok "Đã apply policy $(basename "$pol")"; return 0; fi
    warn "  Apply policy thất bại (lần $i/6) — webhook Kyverno chưa sẵn sàng, đợi 10s..."; sleep 10
  done
  return 1
}
uninstall_kyverno() {
  kubectl delete clusterpolicy --all --ignore-not-found >/dev/null 2>&1 || true
  helm_remove kyverno kyverno
  delete_ns kyverno
}

# ---- 10. Monitoring ---------------------------------------------------------
install_monitoring() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1
  helm repo update >/dev/null
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" || return 1

  wait_ns_ready "monitoring" 300
  wait_ns_all_containers_ready "monitoring" 180

  log "Cài Loki — tắt isDefault để không xung đột datasource với Prometheus"
  helm upgrade --install loki grafana/loki-stack -n monitoring \
    --set promtail.enabled=true \
    --set loki.persistence.enabled=false \
    --set loki.image.tag="2.9.15" \
    --set loki.isDefault=false \
    --set loki.url="http://loki:3100" || return 1
  wait_ns_ready "monitoring" 180

  local loki_cm
  loki_cm=$(kubectl get configmap -n monitoring -l grafana_datasource=1 -o name | grep -i loki || true)
  if [ -n "$loki_cm" ] && kubectl get "$loki_cm" -n monitoring -o jsonpath='{.data}' | grep -q "isDefault: true"; then
    warn "ConfigMap Loki vẫn set isDefault:true — tự vá lại"
    kubectl get "$loki_cm" -n monitoring -o yaml | sed 's/isDefault: true/isDefault: false/' | kubectl apply -f -
    kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana
    wait_ns_all_containers_ready "monitoring" 180
  fi

  [ -f "$GRAFANA_INGRESS_YAML" ] && kubectl apply -f "$GRAFANA_INGRESS_YAML"
  ok "Monitoring stack sẵn sàng"
}
uninstall_monitoring() {
  helm_remove loki monitoring
  helm_remove kube-prometheus-stack monitoring
  kubectl delete pvc --all -n monitoring --ignore-not-found >/dev/null 2>&1 || true
  delete_ns monitoring
}

# ============================== SELECTION / ORCHESTRATION ===================
in_selected() { local x; for x in "${SELECTED[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
sort_selected() { mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | sort -nu); }

# Nhận: "ALL" | "5" | "5,7" | "5 7" | "3-5" | trộn lẫn -> SELECTED (đã sort, không trùng)
parse_selection() {
  local input="${1^^}" tok a b n i key
  local -A seen=()
  SELECTED=()
  input="${input//,/ }"
  [ -n "${input// /}" ] || { warn "Chưa nhập gì."; return 1; }
  for tok in $input; do
    case "$tok" in
      ALL|A)
        for ((i=1; i<=TOTAL_SVC; i++)); do
          key="${SVC_KEYS[$((i-1))]}"
          [[ " $SKIP_IN_ALL_KEYS " == *" $key "* ]] && continue
          seen[$i]=1
        done ;;
      *-*)
        a="${tok%-*}"; b="${tok#*-}"
        if ! [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || (( a<1 || b>TOTAL_SVC || a>b )); then
          warn "Khoảng không hợp lệ: '$tok' (hợp lệ: 1-$TOTAL_SVC)"; return 1
        fi
        for ((n=a; n<=b; n++)); do seen[$n]=1; done ;;
      *)
        if ! [[ "$tok" =~ ^[0-9]+$ ]] || (( tok<1 || tok>TOTAL_SVC )); then
          warn "Số service không hợp lệ: '$tok' (hợp lệ: 1-$TOTAL_SVC hoặc ALL)"; return 1
        fi
        seen[$tok]=1 ;;
    esac
  done
  [ "${#seen[@]}" -gt 0 ] || { warn "Không có service nào được chọn."; return 1; }
  SELECTED=("${!seen[@]}")
  sort_selected
}

# Chọn kind => cluster cũ bị xoá, mọi add-on khác mất theo => gợi ý chuyển sang ALL
guard_kind_selection() {
  in_selected "$N_KIND" || return 0
  warn "Bạn chọn [${N_KIND}] Kind cluster: cluster hiện có sẽ bị XOÁ và toàn bộ add-on bên trong sẽ mất."
  if [ "${#SELECTED[@]}" -lt $((TOTAL_SVC - 1)) ]; then
    if confirm "Chuyển sang ALL để cài lại đầy đủ các add-on trên cluster mới?"; then
      parse_selection "ALL"
      in_selected "$N_KIND" || { SELECTED+=("$N_KIND"); sort_selected; }
      ok "Đã chuyển sang ALL"
    fi
  fi
  confirm "Xác nhận xoá & tạo lại cluster '$CLUSTER_NAME'?" || return 1
}

# ingress-nginx đổi ClusterIP khi cài lại => cấu hình node registry phải làm lại
apply_dependencies() {
  if in_selected "$N_INGRESS" && ! in_selected "$N_NODEREG"; then
    log "ingress-nginx được cài lại → ClusterIP mới, tự động thêm [${N_NODEREG}] Node registry config"
    SELECTED+=("$N_NODEREG"); sort_selected
  fi
}

preflight() {
  log "Kiểm tra công cụ cần thiết"
  local bin
  for bin in kind kubectl helm; do
    command -v "$bin" >/dev/null 2>&1 || { fail "Thiếu '$bin' trong PATH."; return 1; }
  done
  ok "kind, kubectl, helm đều có sẵn"
  wait_for_docker 90 || return 1
  mkdir -p "$CONTAINERD_CFG_DIR"
}

ensure_cluster() {   # các service ≠ kind cần cluster đang chạy
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
    kubectl get nodes >/dev/null 2>&1 && return 0
  fi
  fail "Cluster '$CLUSTER_NAME' chưa có/không truy cập được. Hãy cài service [${N_KIND}] Kind cluster trước."
  return 1
}

run_install() {
  local n key rc before
  for n in "${SELECTED[@]}"; do
    key="${SVC_KEYS[$((n-1))]}"
    log "════ [$n] CÀI ĐẶT: ${SVC_LABELS[$((n-1))]}"
    before=$ERR_COUNT
    "install_${key//-/_}"; rc=$?
    if [ $rc -ne 0 ] || [ "$ERR_COUNT" -gt "$before" ]; then
      RESULTS+=("[$n] ${SVC_LABELS[$((n-1))]}: CÓ LỖI/CẢNH BÁO")
    else
      RESULTS+=("[$n] ${SVC_LABELS[$((n-1))]}: OK")
    fi
  done
}

run_uninstall() {   # gỡ theo thứ tự NGƯỢC
  local i n key
  for ((i=${#SELECTED[@]}-1; i>=0; i--)); do
    n="${SELECTED[$i]}"; key="${SVC_KEYS[$((n-1))]}"
    log "════ [$n] GỠ: ${SVC_LABELS[$((n-1))]}"
    "uninstall_${key//-/_}"
  done
}

print_report() {
  echo ""; echo "═══════════════════════ KẾT QUẢ ═══════════════════════"
  local r
  for r in "${RESULTS[@]:-}"; do
    [ -z "$r" ] && continue
    if [[ "$r" == *": OK" ]]; then echo -e "  \033[1;32m$r\033[0m"; else echo -e "  \033[1;31m$r\033[0m"; fi
  done
  echo "════════════════════════════════════════════════════════════"
  echo "  Service lỗi có thể chạy lại bằng:  $0 recreate <số>"
}

# ============================== MODES =======================================
print_services() {
  local i note
  echo ""
  echo "  Danh sách service:"
  for i in "${!SVC_KEYS[@]}"; do
    note=""; [[ " $SKIP_IN_ALL_KEYS " == *" ${SVC_KEYS[$i]} "* ]] && note="  (không nằm trong ALL)"
    printf "   %2d) %s%s\n" $((i+1)) "${SVC_LABELS[$i]}" "$note"
  done
  echo ""
}

mode_install() {      # $1 = chuỗi chọn (rỗng => hỏi)
  local sel="${1:-}"
  if [ -z "$sel" ]; then
    print_services
    read -rp "  Nhập số service cần cài (VD: 5,7 hoặc 3-5 hoặc ALL): " sel
  fi
  parse_selection "$sel" || return 1
  guard_kind_selection || { warn "Đã huỷ."; return 1; }
  apply_dependencies
  log "Sẽ cài: ${SELECTED[*]}"
  preflight || return 1
  in_selected "$N_KIND" || ensure_cluster || return 1
  run_install
  print_report
}

mode_recreate() {     # $1 = chuỗi chọn (rỗng => hỏi)
  local sel="${1:-}"
  if [ -z "$sel" ]; then
    print_services
    read -rp "  Nhập số service cần TẠO LẠI (xoá + cài lại) — VD: 7 hoặc 5,7 hoặc ALL: " sel
  fi
  parse_selection "$sel" || return 1
  guard_kind_selection || { warn "Đã huỷ."; return 1; }
  apply_dependencies
  log "Sẽ TẠO LẠI: ${SELECTED[*]}"
  local n; for n in "${SELECTED[@]}"; do echo "     - [$n] ${SVC_LABELS[$((n-1))]}"; done
  confirm "Xác nhận xoá và cài lại các service trên?" || { warn "Đã huỷ."; return 1; }
  preflight || return 1
  if ! in_selected "$N_KIND"; then ensure_cluster || return 1; run_uninstall; fi
  # nếu chọn kind: install_kind tự xoá cluster cũ nên không cần gỡ từng add-on
  run_install
  print_report
}

mode_all() {
  mode_install "ALL"
}

ns_status() {   # in trạng thái 1 namespace
  local ns="$1" total bad
  kubectl get ns "$ns" >/dev/null 2>&1 || { echo -e "\033[1;31mCHƯA CÀI\033[0m"; return; }
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
  [ "$total" -eq 0 ] && { echo -e "\033[1;33mCó namespace, chưa có pod\033[0m"; return; }
  bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | awk '$3!="Completed"{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") c++} END{print c+0}')
  if [ "$bad" -eq 0 ]; then echo -e "\033[1;32mOK ($total pod)\033[0m"
  else echo -e "\033[1;33m$bad/$total pod chưa Ready\033[0m"; fi
}

mode_status() {
  log "Trạng thái các service"
  local i key ns st node
  local cluster_up=false
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && cluster_up=true
  $cluster_up && kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
  for i in "${!SVC_KEYS[@]}"; do
    key="${SVC_KEYS[$i]}"; ns="${SVC_NS[$i]}"
    if [ "$key" = "kind" ]; then
      $cluster_up && st="\033[1;32mCHẠY\033[0m" || st="\033[1;31mCHƯA CÓ\033[0m"
    elif ! $cluster_up; then
      st="\033[1;31m(cluster chưa có)\033[0m"
    elif [ "$key" = "node-registry" ]; then
      node=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | grep worker | head -1)
      if [ -n "$node" ] && docker exec "$node" grep -q 'harbor\.local' /etc/hosts 2>/dev/null; then
        st="\033[1;32mĐÃ CẤU HÌNH\033[0m"; else st="\033[1;31mCHƯA CẤU HÌNH\033[0m"; fi
    else
      st=$(ns_status "$ns")
    fi
    printf "   %2d) %-66s " $((i+1)) "${SVC_LABELS[$i]}"; echo -e "$st"
  done
  echo ""
}

print_summary() {
  echo "==================================================================="
  echo " Truy cập qua port-forward (Docker Desktop/WSL2 cách ly network):"
  echo "   kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8443:443 8080:80 &"
  echo " Domain cần trong /etc/hosts (Windows + WSL2) -> 127.0.0.1:"
  echo "   harbor.local  jenkins.local  argocd.local  grafana.local"
  echo "   https://harbor.local:8443   (admin / ${HARBOR_ADMIN_PASSWORD})"
  echo "   https://jenkins.local:8443"
  echo "   https://argocd.local:8443"
  echo "   https://grafana.local:8443  (admin / ${GRAFANA_ADMIN_PASSWORD})"
  echo "==================================================================="
}

main_menu() {
  local choice
  while true; do
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        ENTERPRISE K8S LAB — SETUP MENU                    ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  1) Cài đặt TẤT CẢ add-on (full setup)                    ║"
    echo "║  2) Deploy 1 hoặc nhiều add-on (chọn theo số)             ║"
    echo "║  3) Tạo lại add-on bị lỗi (xoá + cài lại, chọn số / ALL)  ║"
    echo "║  4) Xem trạng thái các service                            ║"
    echo "║  0) Thoát                                                 ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    read -rp "  Chọn: " choice
    case "$choice" in
      1) mode_all ;;
      2) mode_install ;;
      3) mode_recreate ;;
      4) mode_status ;;
      0|q|Q) echo "Thoát."; exit 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
  done
}

# ============================== ENTRY POINT =================================
ARGS=()
for a in "$@"; do
  case "$a" in -y|--yes) AUTO_YES=true ;; *) ARGS+=("$a") ;; esac
done
set -- "${ARGS[@]:-}"

case "${1:-}" in
  "")        main_menu ;;
  all)       mode_all;        print_summary ;;
  install)   mode_install "${2:-}"; print_summary ;;
  recreate)  mode_recreate "${2:-}" ;;
  status)    mode_status ;;
  -h|--help|help) sed -n '2,24p' "$0" ;;
  *)         echo "Lệnh không hợp lệ: $1  (all | install <ds> | recreate <ds> | status)"; exit 1 ;;
esac