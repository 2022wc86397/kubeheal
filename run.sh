#!/usr/bin/env bash
set -euo pipefail

# KubeGuard master controller
# Usage:
#   ./run.sh setup       Build + deploy everything
#   ./run.sh dashboard   Expose the dashboard on host port 8080
#   ./run.sh traffic     Generate baseline traffic
#   ./run.sh cpu         Inject CPU degradation
#   ./run.sh errors      Inject HTTP errors
#   ./run.sh latency     Inject latency degradation
#   ./run.sh analyze     Analyze -> Incident -> Recover -> Verify
#   ./run.sh demo        Run a complete demonstration
#   ./run.sh status      Show project status
#   ./run.sh stop        Stop active experiment
#   ./run.sh cleanup     Remove the project
#   ./run.sh all         Setup + baseline + dashboard
#
# Only host port 8080 is used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

NAMESPACE="kubeguard"
DEMO_NAMESPACE="demo-app"
DASHBOARD_SERVICE="kubeguard-dashboard"
DASHBOARD_PORT="8080"
API_SERVICE="kubeguard"
API_PORT="8000"

log()  { echo -e "\n[ KUBEGUARD ] $*"; }
ok()   { echo "[ OK ] $*"; }
die()  { echo "[ ERROR ] $*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found."
}

check_prereqs() {
    log "Checking prerequisites"
    need_cmd docker
    need_cmd kubectl
    need_cmd minikube
    need_cmd helm
    need_cmd curl
    ok "Prerequisites available"
}

wait_for_deployment() {
    local ns="$1"
    local name="$2"
    log "Waiting for deployment/$name"
    kubectl -n "$ns" rollout status "deployment/$name" --timeout=180s
}

setup() {
    check_prereqs

    log "Starting Minikube if necessary"
    if ! minikube status >/dev/null 2>&1; then
        minikube start --cpus=4 --memory=6144 --driver=docker
    else
        echo "Minikube is already running."
    fi

    log "Using Minikube's Docker daemon"
    eval "$(minikube docker-env)"

    log "Building Docker images"
    docker build -t kubeguard-demo-backend:0.1 ./demo-app/backend
    docker build -t kubeguard-frontend:0.1 ./demo-app/frontend
    docker build -t kubeguard:0.1 ./kubeguard
    docker build -t kubeguard-dashboard:0.1 ./dashboard

    log "Creating namespaces"
    kubectl apply -f k8s/namespaces.yaml

    log "Installing/updating Prometheus + Grafana"
    helm repo add prometheus-community \
        https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null
    helm upgrade --install monitoring \
        prometheus-community/kube-prometheus-stack \
        -n monitoring \
        --create-namespace \
        -f k8s/monitoring-values.yaml

    log "Deploying demo application"
    kubectl apply -f k8s/demo-app.yaml
    kubectl apply -f k8s/demo-monitoring.yaml

    log "Deploying KubeGuard RBAC and backend"
    kubectl apply -f k8s/kubeguard-rbac.yaml
    kubectl apply -f k8s/kubeguard.yaml

    log "Deploying KubeGuard dashboard"
    kubectl apply -f k8s/dashboard.yaml

    wait_for_deployment "$DEMO_NAMESPACE" "demo-backend"
    wait_for_deployment "$DEMO_NAMESPACE" "demo-frontend"
    wait_for_deployment "$NAMESPACE" "kubeguard"
    wait_for_deployment "$NAMESPACE" "$DASHBOARD_SERVICE"

    log "Checking KubeGuard API"
    kubectl -n "$NAMESPACE" get pods
    kubectl -n "$DEMO_NAMESPACE" get pods

    ok "KubeGuard installation completed"
    echo
    echo "Dashboard command:"
    echo "  ./run.sh dashboard"
    echo
    echo "Dashboard URL:"
    echo "  http://localhost:${DASHBOARD_PORT}"
}

api_call() {
    local method="$1"
    local path="$2"

    kubectl -n "$NAMESPACE" port-forward \
        "svc/${API_SERVICE}" "${API_PORT}:${API_PORT}" \
        >/tmp/kubeguard-api-port-forward.log 2>&1 &
    local pf_pid=$!

    trap 'kill "$pf_pid" 2>/dev/null || true' RETURN
    sleep 2

    if [[ "$method" == "GET" ]]; then
        curl -fsS "http://127.0.0.1:${API_PORT}${path}"
    else
        curl -fsS -X "$method" "http://127.0.0.1:${API_PORT}${path}"
    fi

    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
    trap - RETURN
}

dashboard() {
    log "Starting dashboard on host port ${DASHBOARD_PORT}"
    echo "Open: http://localhost:${DASHBOARD_PORT}"
    echo "Press Ctrl+C to stop port forwarding."

    kubectl -n "$NAMESPACE" port-forward \
        "svc/${DASHBOARD_SERVICE}" "${DASHBOARD_PORT}:80"
}

get_demo_pod() {
    kubectl -n "$DEMO_NAMESPACE" get pod \
        -l app=demo-backend \
        -o jsonpath='{.items[0].metadata.name}'
}

generate_traffic() {
    log "Generating short baseline traffic inside Kubernetes"
    local pod
    pod="$(get_demo_pod)"

    for i in $(seq 1 120); do
        kubectl -n "$DEMO_NAMESPACE" exec "$pod" -- \
            python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/work', timeout=3).read()" \
            >/dev/null 2>&1 || true
        sleep 1
    done

    ok "Baseline traffic completed"
}

experiment() {
    local kind="$1"

    case "$kind" in
        cpu|errors|latency) ;;
        *) die "Invalid experiment: $kind. Use cpu, errors, or latency." ;;
    esac

    log "Starting ${kind} degradation experiment"
    api_call POST "/experiments/start/${kind}"
    echo
    log "Generating workload for 60 seconds"

    local pod
    pod="$(get_demo_pod)"

    for i in $(seq 1 60); do
        kubectl -n "$DEMO_NAMESPACE" exec "$pod" -- \
            python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/work', timeout=3).read()" \
            >/dev/null 2>&1 || true
        sleep 1
    done

    ok "${kind} experiment completed"
    echo
    echo "Now run:"
    echo "  ./run.sh analyze"
}

stop_experiment() {
    log "Stopping active degradation experiment"
    api_call POST "/experiments/stop"
    echo
    ok "Experiment stopped"
}

analyze_recover() {
    log "Running KubeGuard: Analyze -> Incident -> Recover -> Verify"
    echo
    api_call POST "/experiments/analyze-and-recover"
    echo
}

status() {
    log "Kubernetes status"
    kubectl -n "$DEMO_NAMESPACE" get pods,svc
    echo
    kubectl -n "$NAMESPACE" get pods,svc
    echo
    log "Current KubeGuard analysis"
    api_call GET "/analysis"
    echo
    log "Incident history"
    api_call GET "/incidents"
    echo
}

demo() {
    log "Starting complete KubeGuard demonstration"

    setup

    log "Generating normal baseline"
    generate_traffic

    log "Starting CPU degradation"
    api_call POST "/experiments/start/cpu"
    echo

    log "Generating workload during degradation"
    local pod
    pod="$(get_demo_pod)"

    for i in $(seq 1 60); do
        kubectl -n "$DEMO_NAMESPACE" exec "$pod" -- \
            python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/work', timeout=3).read()" \
            >/dev/null 2>&1 || true
        sleep 1
    done

    log "Stopping degradation before recovery analysis"
    api_call POST "/experiments/stop" >/dev/null || true

    log "Waiting briefly for Prometheus to observe the final state"
    sleep 15

    log "Running Analyze -> Incident -> Recover -> Verify"
    api_call POST "/experiments/analyze-and-recover"
    echo

    log "Complete demonstration finished"
    echo
    echo "Start the dashboard with:"
    echo "  ./run.sh dashboard"
    echo
    echo "Dashboard:"
    echo "  http://localhost:${DASHBOARD_PORT}"
}

cleanup() {
    log "Stopping experiment if active"
    api_call POST "/experiments/stop" >/dev/null 2>&1 || true

    log "Removing KubeGuard resources"
    kubectl delete -f k8s/dashboard.yaml --ignore-not-found
    kubectl delete -f k8s/kubeguard.yaml --ignore-not-found
    kubectl delete -f k8s/kubeguard-rbac.yaml --ignore-not-found
    kubectl delete -f k8s/demo-monitoring.yaml --ignore-not-found
    kubectl delete -f k8s/demo-app.yaml --ignore-not-found

    log "Removing monitoring stack"
    helm uninstall monitoring -n monitoring >/dev/null 2>&1 || true

    kubectl delete namespace kubeguard demo-app monitoring --ignore-not-found

    ok "KubeGuard resources removed"
}

usage() {
    cat <<EOF

KubeGuard Master Script

Usage:
  ./run.sh setup       Build and deploy the complete project
  ./run.sh dashboard   Open dashboard on localhost:8080
  ./run.sh traffic     Generate normal baseline traffic
  ./run.sh cpu         Run CPU degradation experiment
  ./run.sh errors      Run HTTP error experiment
  ./run.sh latency     Run latency experiment
  ./run.sh analyze     Analyze, create incident, recover and verify
  ./run.sh demo        Run complete demonstration
  ./run.sh status      Show Kubernetes/incident status
  ./run.sh stop        Stop active experiment
  ./run.sh cleanup     Remove project resources
  ./run.sh all         Setup + baseline + start dashboard

Only host port 8080 is used for the dashboard.

EOF
}

case "${1:-}" in
    setup)    setup ;;
    dashboard) dashboard ;;
    traffic)  generate_traffic ;;
    cpu)      experiment cpu ;;
    errors)   experiment errors ;;
    latency)  experiment latency ;;
    analyze)  analyze_recover ;;
    demo)     demo ;;
    status)   status ;;
    stop)     stop_experiment ;;
    cleanup)  cleanup ;;
    all)
        setup
        generate_traffic
        dashboard
        ;;
    -h|--help|help|"") usage ;;
    *) die "Unknown command '$1'. Run ./run.sh --help" ;;
esac
