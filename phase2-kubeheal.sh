#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
DEMO="kubeheal-demo"
IMAGE="kubeheal:2.0"
log(){ printf '\n[KubeHeal Phase 2] %s\n' "$1"; }

command -v kubectl >/dev/null || { echo "kubectl missing"; exit 1; }
command -v minikube >/dev/null || { echo "minikube missing"; exit 1; }
kubectl get node minikube >/dev/null || { echo "Minikube not ready"; exit 1; }

log "Creating application source"
rm -rf "$APP"
mkdir -p "$APP/templates"
cat >"$APP/requirements.txt" <<'EOF'
Flask==3.1.2
requests==2.32.5
kubernetes==34.1.0
gunicorn==23.0.0
EOF
cat >"$APP/Dockerfile" <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
EXPOSE 8080
CMD ["gunicorn","--bind","0.0.0.0:8080","--workers","1","--threads","4","app:app"]
EOF
cat >"$APP/app.py" <<'PY'
from flask import Flask, jsonify, render_template, request
from kubernetes import client, config
import requests, os, threading, time
from datetime import datetime, timezone

app=Flask(__name__)
NS=os.getenv("DEMO_NAMESPACE","kubeheal-demo")
PROM=os.getenv("PROMETHEUS_URL","http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090")
config.load_incluster_config(); core=client.CoreV1Api(); apps=client.AppsV1Api()
lock=threading.Lock(); incidents=[]; next_id=1

def now(): return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
def deployments():
    out=[]
    for d in apps.list_namespaced_deployment(NS).items:
        desired=d.spec.replicas or 0; ready=d.status.ready_replicas or 0
        out.append({"name":d.metadata.name,"desired":desired,"ready":ready,"status":"healthy" if desired and ready==desired else "unhealthy"})
    return sorted(out,key=lambda x:x["name"])
def pods():
    out=[]
    for p in core.list_namespaced_pod(NS).items:
        ready=any(c.type=="Ready" and c.status=="True" for c in (p.status.conditions or []))
        restarts=sum(s.restart_count for s in (p.status.container_statuses or []))
        out.append({"name":p.metadata.name,"app":p.metadata.labels.get("app","-"),"phase":p.status.phase,"ready":ready,"restarts":restarts})
    return out
def prom(q):
    try:
        r=requests.get(PROM+"/api/v1/query",params={"query":q},timeout=4); r.raise_for_status(); x=r.json()["data"]["result"]
        return float(x[0]["value"][1]) if x else None
    except Exception: return None
def create_incident(appname,typ,action="Kubernetes controller replacement"):
    global next_id
    with lock:
        i={"id":next_id,"time":now(),"application":appname,"type":typ,"severity":"High","status":"Active","action":action,"resolved":None}
        next_id+=1; incidents.insert(0,i); return i

def monitor_recovery(inc,appname,timeout=90):
    end=time.time()+timeout
    while time.time()<end:
        d=apps.read_namespaced_deployment(appname,NS)
        if (d.status.ready_replicas or 0)==(d.spec.replicas or 0):
            with lock: inc["status"]="Recovered"; inc["resolved"]=now()
            return
        time.sleep(1)
    with lock: inc["status"]="Failed"

@app.get("/")
def index(): return render_template("dashboard.html")
@app.get("/api/summary")
def summary():
    ds=deployments(); ps=pods(); active=sum(i["status"]=="Active" for i in incidents); recovered=sum(i["status"]=="Recovered" for i in incidents)
    cpu=prom('100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))')
    mem=prom('100 * (1 - (sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)))')
    return jsonify({"applications":ds,"pods":ps,"counts":{"applications":len(ds),"pods":len(ps),"active":active,"recoveries":recovered},"cpu":round(cpu or 0,1),"memory":round(mem or 0,1),"incidents":incidents[:20]})
@app.post("/api/experiments/crash")
def crash():
    name=(request.json or {}).get("application","backend")
    candidates=[p for p in pods() if p["app"]==name]
    if not candidates: return jsonify({"ok":False,"message":"No pod found"}),404
    inc=create_incident(name,"Pod Failure")
    core.delete_namespaced_pod(candidates[0]["name"],NS)
    threading.Thread(target=monitor_recovery,args=(inc,name),daemon=True).start()
    return jsonify({"ok":True,"incident":inc})
@app.get("/api/system/health")
def health(): return jsonify({"status":"ok"})
PY
cat >"$APP/templates/dashboard.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KubeHeal</title>
<style>*{box-sizing:border-box}body{margin:0;font:14px Arial;background:#f6f8fb;color:#172033}.side{position:fixed;width:190px;height:100vh;background:#0c203a;color:#fff;padding:22px}.brand{font-size:21px;font-weight:700;margin-bottom:30px}.nav{padding:12px;border-radius:7px;margin:6px 0}.nav.active{background:#1769e0}.main{margin-left:190px;padding:28px}.top{display:flex;justify-content:space-between}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:20px 0}.card,.panel{background:white;border:1px solid #dfe5ee;border-radius:9px;padding:18px;box-shadow:0 1px 3px #dfe5ee}.num{font-size:27px;font-weight:bold}.green{color:#129b55}.red{color:#e53535}.apps{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.badge{padding:5px 10px;border-radius:15px;background:#dcf8e8;color:#08783d;font-weight:bold}.bad{background:#ffe2e2;color:#b51e1e}.bar{height:8px;background:#e6ebf2;border-radius:9px;margin-top:8px}.fill{height:100%;background:#17ad63;border-radius:9px}.incident{width:100%;border-collapse:collapse}.incident th,.incident td{padding:10px;border-bottom:1px solid #e7ebf0;text-align:left}button{background:#1769e0;color:white;border:0;border-radius:6px;padding:10px 14px;cursor:pointer}.experiment{margin-top:18px;background:#fff2f2;border:1px solid #ffcccc;border-radius:9px;padding:18px}@media(max-width:900px){.grid,.apps{grid-template-columns:1fr 1fr}.side{display:none}.main{margin-left:0}}</style></head>
<body><aside class="side"><div class="brand">⬡ KubeHeal</div><div class="nav active">Dashboard</div><div class="nav">Applications</div><div class="nav">Pods</div><div class="nav">Incidents</div><div class="nav">Experiments</div><div class="nav">Metrics</div><div class="nav">Settings</div></aside>
<main class="main"><div class="top"><div><h1>Dashboard</h1><div>Kubernetes Application Health & Auto-Recovery</div></div><div class="green">● Cluster Connected</div></div>
<div class="grid"><div class="card"><div>Applications</div><div class="num" id="ca">-</div></div><div class="card"><div>Pods</div><div class="num" id="cp">-</div></div><div class="card"><div>Active Incidents</div><div class="num red" id="ci">-</div></div><div class="card"><div>Successful Recoveries</div><div class="num green" id="cr">-</div></div></div>
<div class="panel"><h2>Application Health</h2><div class="apps" id="apps"></div></div>
<div class="panel" style="margin-top:18px"><h2>Cluster Resource Usage</h2><div class="grid" style="grid-template-columns:1fr 1fr"><div><b>CPU</b><div class="num" id="cpu">-</div></div><div><b>Memory</b><div class="num" id="mem">-</div></div></div></div>
<div class="experiment"><h2>Experiment: Crash Pod</h2><p>Deletes one backend demo pod. The Deployment controller should automatically replace it, while KubeHeal records the incident and recovery.</p><button onclick="crash()">Trigger Backend Crash</button><span id="msg" style="margin-left:12px"></span></div>
<div class="panel" style="margin-top:18px"><h2>Incidents</h2><table class="incident"><thead><tr><th>ID</th><th>Time</th><th>Application</th><th>Type</th><th>Severity</th><th>Status</th><th>Recovery Action</th></tr></thead><tbody id="incs"></tbody></table></div>
</main><script>
async function refresh(){let r=await fetch('/api/summary',{cache:'no-store'}),d=await r.json();ca.textContent=d.counts.applications;cp.textContent=d.counts.pods;ci.textContent=d.counts.active;cr.textContent=d.counts.recoveries;cpu.textContent=d.cpu+'%';mem.textContent=d.memory+'%';apps.innerHTML=d.applications.map(a=>`<div class="card"><div style="display:flex;justify-content:space-between"><b>${a.name}</b><span class="badge ${a.status==='healthy'?'':'bad'}">${a.status}</span></div><h3>${a.ready}/${a.desired} Running Pods</h3><div class="bar"><div class="fill" style="width:${a.desired?100*a.ready/a.desired:0}%"></div></div></div>`).join('');incs.innerHTML=d.incidents.map(i=>`<tr><td>#${i.id}</td><td>${i.time}</td><td>${i.application}</td><td>${i.type}</td><td class="red">${i.severity}</td><td class="${i.status==='Recovered'?'green':'red'}">${i.status}</td><td>${i.action}</td></tr>`).join('')||'<tr><td colspan="7">No incidents yet</td></tr>'}
async function crash(){msg.textContent='Injecting fault...';let r=await fetch('/api/experiments/crash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})});let d=await r.json();msg.textContent=d.ok?'Incident created. Watching recovery...':d.message;refresh()}
refresh();setInterval(refresh,1000);
</script></body></html>
HTML

log "Building KubeHeal image in Minikube"
cd "$APP"
minikube image build -t "$IMAGE" .

log "Deploying RBAC and KubeHeal"
cat >/tmp/kubeheal-phase2.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: kubeheal, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: kubeheal-demo-controller, namespace: $DEMO}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","watch","delete"]
- apiGroups: ["apps"]
  resources: ["deployments","deployments/scale"]
  verbs: ["get","list","watch","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: kubeheal-demo-controller, namespace: $DEMO}
subjects:
- kind: ServiceAccount
  name: kubeheal
  namespace: $NS
roleRef:
  kind: Role
  name: kubeheal-demo-controller
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: kubeheal, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: kubeheal}}
  template:
    metadata: {labels: {app: kubeheal}}
    spec:
      serviceAccountName: kubeheal
      containers:
      - name: kubeheal
        image: $IMAGE
        imagePullPolicy: Never
        ports: [{containerPort: 8080}]
        env:
        - {name: DEMO_NAMESPACE, value: "$DEMO"}
        - {name: PROMETHEUS_URL, value: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"}
        readinessProbe: {httpGet: {path: /api/system/health, port: 8080}, initialDelaySeconds: 4, periodSeconds: 5}
        livenessProbe: {httpGet: {path: /api/system/health, port: 8080}, initialDelaySeconds: 10, periodSeconds: 10}
---
apiVersion: v1
kind: Service
metadata: {name: kubeheal, namespace: $NS}
spec:
  selector: {app: kubeheal}
  ports: [{port: 8080, targetPort: 8080}]
YAML
kubectl apply -f /tmp/kubeheal-phase2.yaml
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s

log "Verifying KubeHeal"
kubectl get pods -n "$NS"
kubectl get pods -n "$DEMO"
echo
echo "Phase 2 deployed successfully."
echo "To access the GUI, run:"
echo "  kubectl port-forward --address=0.0.0.0 svc/kubeheal 8080:8080 -n $NS"
echo "Then browse: http://<EC2-PUBLIC-IP>:8080"
echo "Ensure the EC2 Security Group allows TCP 8080 from your IP."
