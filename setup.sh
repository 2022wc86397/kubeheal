#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf '\n[KubeHeal] %s\n' "$1"; }
fail(){ echo "ERROR: $1" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] || fail "Run as the normal Ubuntu user, not root."

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=amd64 ;;
  aarch64|arm64) KARCH=arm64 ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac

log "1/9 Installing Docker and prerequisites"
sudo apt-get update -y
sudo apt-get install -y docker.io curl ca-certificates python3 python3-pip python3-venv
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
# Let this initial installation continue without requiring a new login.
sudo setfacl -m "u:$USER:rw" /var/run/docker.sock 2>/dev/null || sudo chmod 666 /var/run/docker.sock

docker info >/dev/null

log "2/9 Installing kubectl"
KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl

log "3/9 Installing Minikube"
curl -fsSLo /tmp/minikube "https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-${KARCH}"
sudo install -m 0755 /tmp/minikube /usr/local/bin/minikube
rm -f /tmp/minikube

log "4/9 Starting Minikube"
if ! minikube status >/dev/null 2>&1; then
  minikube start --driver=docker --cpus=2 --memory=3000
fi
kubectl wait --for=condition=Ready node/minikube --timeout=180s

log "5/9 Installing Helm"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

log "6/9 Installing Prometheus stack (Grafana disabled)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --set grafana.enabled=false \
  --wait --timeout 10m

log "7/9 Creating KubeHeal namespaces"
kubectl create namespace kubeheal-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kubeheal-demo --dry-run=client -o yaml | kubectl apply -f -

log "8/9 Deploying demo applications"
cat >/tmp/kubeheal-demo.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: kubeheal-demo
spec:
  replicas: 2
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports: [{containerPort: 80}]
        resources:
          requests: {cpu: 20m, memory: 32Mi}
          limits: {cpu: 200m, memory: 128Mi}
        readinessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: kubeheal-demo
spec:
  replicas: 2
  selector:
    matchLabels: {app: backend}
  template:
    metadata:
      labels: {app: backend}
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports: [{containerPort: 80}]
        resources:
          requests: {cpu: 20m, memory: 32Mi}
          limits: {cpu: 200m, memory: 128Mi}
        readinessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database
  namespace: kubeheal-demo
spec:
  replicas: 1
  selector:
    matchLabels: {app: database}
  template:
    metadata:
      labels: {app: database}
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports: [{containerPort: 80}]
        resources:
          requests: {cpu: 20m, memory: 32Mi}
          limits: {cpu: 200m, memory: 128Mi}
        readinessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 10
          periodSeconds: 10
YAML
kubectl apply -f /tmp/kubeheal-demo.yaml
kubectl rollout status deployment/frontend -n kubeheal-demo --timeout=180s
kubectl rollout status deployment/backend -n kubeheal-demo --timeout=180s
kubectl rollout status deployment/database -n kubeheal-demo --timeout=180s

log "9/9 Verification"
kubectl get nodes
kubectl get pods -n monitoring
kubectl get deployments,pods -n kubeheal-demo

echo
echo "Infrastructure foundation is ready."
echo "Next phase: build and deploy the KubeHeal API/UI container."
echo "Note: future Docker commands may require a logout/login for docker-group membership."
