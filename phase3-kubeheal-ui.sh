#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
DEMO="kubeheal-demo"
IMAGE="kubeheal:3.0"
log(){ printf '\n[KubeHeal Phase 3] %s\n' "$1"; }

[[ -f "$APP/app.py" ]] || { echo "Phase 2 source not found at $APP"; exit 1; }

log "Upgrading KubeHeal backend"
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
settings={"cpu_warning":75,"cpu_critical":90,"memory_warning":75,"memory_critical":90,"auto_recovery":True,"refresh_seconds":2}

def now(): return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
def prom(q):
    try:
        r=requests.get(PROM+"/api/v1/query",params={"query":q},timeout=4); r.raise_for_status(); x=r.json()["data"]["result"]
        return float(x[0]["value"][1]) if x else None
    except Exception: return None

def pods():
    out=[]
    for p in core.list_namespaced_pod(NS).items:
        ready=any(c.type=="Ready" and c.status=="True" for c in (p.status.conditions or []))
        restarts=sum(s.restart_count for s in (p.status.container_statuses or []))
        out.append({"name":p.metadata.name,"app":p.metadata.labels.get("app","-"),"phase":p.status.phase,"ready":ready,"restarts":restarts,"node":p.spec.node_name or "-","ip":p.status.pod_ip or "-"})
    return sorted(out,key=lambda x:x["name"])

def deployments():
    out=[]
    ps=pods()
    for d in apps.list_namespaced_deployment(NS).items:
        name=d.metadata.name; desired=d.spec.replicas or 0; ready=d.status.ready_replicas or 0
        rp=[p for p in ps if p["app"]==name]; restarts=sum(p["restarts"] for p in rp)
        score=round((ready/desired)*100) if desired else 0
        out.append({"name":name,"desired":desired,"ready":ready,"status":"healthy" if desired and ready==desired else "unhealthy","health_score":score,"restarts":restarts})
    return sorted(out,key=lambda x:x["name"])

def create_incident(appname,typ,severity="High",action="Kubernetes controller replacement"):
    global next_id
    with lock:
        i={"id":next_id,"time":now(),"application":appname,"type":typ,"severity":severity,"status":"Active","action":action,"resolved":None,"recovery_seconds":None}
        next_id+=1; incidents.insert(0,i); return i

def monitor_recovery(inc,appname,start):
    end=time.time()+90
    while time.time()<end:
        d=apps.read_namespaced_deployment(appname,NS)
        if (d.status.ready_replicas or 0)==(d.spec.replicas or 0):
            with lock:
                inc["status"]="Recovered"; inc["resolved"]=now(); inc["recovery_seconds"]=round(time.time()-start,1)
            return
        time.sleep(1)
    with lock: inc["status"]="Failed"

def cluster_metrics():
    cpu=prom('100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))')
    mem=prom('100 * (1 - (sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)))')
    return {"cpu":round(cpu or 0,1),"memory":round(mem or 0,1)}

@app.get("/")
def index(): return render_template("dashboard.html")
@app.get("/api/summary")
def summary():
    ds=deployments(); ps=pods(); m=cluster_metrics()
    return jsonify({"applications":ds,"pods":ps,"counts":{"applications":len(ds),"pods":len(ps),"active":sum(i["status"]=="Active" for i in incidents),"recoveries":sum(i["status"]=="Recovered" for i in incidents)},"cpu":m["cpu"],"memory":m["memory"],"incidents":incidents[:50]})
@app.get("/api/applications")
def api_apps(): return jsonify(deployments())
@app.get("/api/pods")
def api_pods(): return jsonify(pods())
@app.get("/api/incidents")
def api_incidents(): return jsonify(incidents)
@app.get("/api/settings")
def api_settings(): return jsonify(settings)
@app.post("/api/settings")
def save_settings():
    data=request.json or {}; settings.update({k:v for k,v in data.items() if k in settings}); return jsonify(settings)
@app.post("/api/experiments/crash")
def crash():
    name=(request.json or {}).get("application","backend"); candidates=[p for p in pods() if p["app"]==name and p["ready"]]
    if not candidates: return jsonify({"ok":False,"message":"No ready pod found"}),404
    start=time.time(); inc=create_incident(name,"Pod Failure")
    core.delete_namespaced_pod(candidates[0]["name"],NS)
    threading.Thread(target=monitor_recovery,args=(inc,name,start),daemon=True).start()
    return jsonify({"ok":True,"incident":inc})
@app.get("/api/system/health")
def health(): return jsonify({"status":"ok"})
PY

log "Upgrading interactive UI"
cat >"$APP/templates/dashboard.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KubeHeal</title>
<style>*{box-sizing:border-box}body{margin:0;font:14px Arial;background:#f5f7fb;color:#172033}.side{position:fixed;width:200px;height:100vh;background:#0c203a;color:#fff;padding:20px 12px}.brand{font-size:21px;font-weight:700;padding:0 10px 22px}.nav{padding:12px;border-radius:7px;margin:5px 0;cursor:pointer}.nav:hover,.nav.active{background:#1769e0}.main{margin-left:200px;padding:28px}.top{display:flex;justify-content:space-between;align-items:center}.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:20px 0}.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.card,.panel{background:#fff;border:1px solid #dfe5ee;border-radius:9px;padding:18px;box-shadow:0 1px 3px #e1e6ee}.num{font-size:27px;font-weight:700}.green{color:#129b55}.red{color:#e53535}.orange{color:#d98300}.badge{padding:5px 10px;border-radius:15px;background:#dcf8e8;color:#08783d;font-weight:bold}.bad{background:#ffe2e2;color:#b51e1e}.bar{height:8px;background:#e6ebf2;border-radius:9px;margin-top:8px}.fill{height:100%;background:#17ad63;border-radius:9px}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #e7ebf0;text-align:left}button{background:#1769e0;color:#fff;border:0;border-radius:6px;padding:10px 14px;cursor:pointer}.danger{background:#e53935}.view{display:none}.view.active{display:block}.exp{background:#fff;border:1px solid #dfe5ee;border-radius:9px;padding:20px}.muted{color:#718096}.metricbox{font-size:34px;font-weight:700;margin-top:12px}input{padding:9px;border:1px solid #ccd4df;border-radius:6px;width:100px}.setting{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid #eee}@media(max-width:900px){.side{display:none}.main{margin-left:0}.grid4,.grid3{grid-template-columns:1fr 1fr}}</style></head>
<body><aside class="side"><div class="brand">⬡ KubeHeal</div><div class="nav active" data-page="dashboard">▣ Dashboard</div><div class="nav" data-page="applications">▦ Applications</div><div class="nav" data-page="pods">▱ Pods</div><div class="nav" data-page="incidents">● Incidents</div><div class="nav" data-page="experiments">◇ Experiments</div><div class="nav" data-page="metrics">▥ Metrics</div><div class="nav" data-page="settings">⚙ Settings</div></aside>
<main class="main"><div class="top"><div><h1 id="title">Dashboard</h1><div class="muted" id="subtitle">Kubernetes Application Health & Auto-Recovery</div></div><div class="green">● Cluster Connected</div></div>
<section id="dashboard" class="view active"><div class="grid4"><div class="card">Applications<div class="num" id="ca">-</div></div><div class="card">Pods<div class="num" id="cp">-</div></div><div class="card">Active Incidents<div class="num red" id="ci">-</div></div><div class="card">Successful Recoveries<div class="num green" id="cr">-</div></div></div><div class="panel"><h2>Application Health</h2><div class="grid3" id="dashApps"></div></div><div class="panel" style="margin-top:16px"><h2>Cluster Resource Usage</h2><div class="grid3"><div>CPU<div class="metricbox" id="dcpu">-</div></div><div>Memory<div class="metricbox" id="dmem">-</div></div><div>Pods<div class="metricbox" id="dpods">-</div></div></div></div></section>
<section id="applications" class="view"><div class="grid3" id="appCards"></div></section>
<section id="pods" class="view"><div class="panel"><table><thead><tr><th>Pod</th><th>Application</th><th>Phase</th><th>Ready</th><th>Restarts</th><th>Node</th><th>IP</th></tr></thead><tbody id="podRows"></tbody></table></div></section>
<section id="incidents" class="view"><div class="panel"><table><thead><tr><th>ID</th><th>Time</th><th>Application</th><th>Incident</th><th>Severity</th><th>Status</th><th>Action</th><th>Recovery</th></tr></thead><tbody id="incidentRows"></tbody></table></div></section>
<section id="experiments" class="view"><div class="grid3"><div class="exp"><h2>Crash Pod</h2><p class="muted">Delete one running backend pod and observe Kubernetes replacement.</p><button class="danger" onclick="crash('backend')">Trigger Backend Crash</button></div><div class="exp"><h2>CPU Stress</h2><p class="muted">Planned for Phase 4 with a dedicated controlled load generator.</p><button disabled>Coming Next</button></div><div class="exp"><h2>Memory Stress</h2><p class="muted">Planned for Phase 4 with bounded demo-only memory pressure.</p><button disabled>Coming Next</button></div></div><p id="msg"></p></section>
<section id="metrics" class="view"><div class="grid3"><div class="card"><h3>CPU Usage</h3><div class="metricbox" id="mcpu">-</div></div><div class="card"><h3>Memory Usage</h3><div class="metricbox" id="mmem">-</div></div><div class="card"><h3>Running Pods</h3><div class="metricbox" id="mpods">-</div></div></div><div class="panel" style="margin-top:16px"><p class="muted">Historical charts and response/error metrics will be added after application instrumentation in Phase 4.</p></div></section>
<section id="settings" class="view"><div class="panel"><h2>Health Thresholds</h2><div class="setting"><span>CPU Warning (%)</span><input id="cpuWarning" type="number"></div><div class="setting"><span>CPU Critical (%)</span><input id="cpuCritical" type="number"></div><div class="setting"><span>Memory Warning (%)</span><input id="memWarning" type="number"></div><div class="setting"><span>Memory Critical (%)</span><input id="memCritical" type="number"></div><br><button onclick="saveSettings()">Save Settings</button><span id="settingsMsg" style="margin-left:10px"></span></div></section>
</main><script>
const meta={dashboard:['Dashboard','Kubernetes Application Health & Auto-Recovery'],applications:['Applications','Manage and monitor Kubernetes applications'],pods:['Pods','Live workload status from the Kubernetes API'],incidents:['Incidents','Detected incidents and automatic recovery actions'],experiments:['Experiments','Controlled demo-only failure scenarios'],metrics:['Metrics','Cluster metrics from Prometheus'],settings:['Settings','KubeHeal thresholds and policy settings']};
document.querySelectorAll('.nav').forEach(n=>n.onclick=()=>{document.querySelectorAll('.nav,.view').forEach(x=>x.classList.remove('active'));n.classList.add('active');document.getElementById(n.dataset.page).classList.add('active');title.textContent=meta[n.dataset.page][0];subtitle.textContent=meta[n.dataset.page][1];});
function appCard(a){return `<div class="card"><div style="display:flex;justify-content:space-between"><h2>${a.name}</h2><span class="badge ${a.status==='healthy'?'':'bad'}">${a.status}</span></div><h3>${a.ready}/${a.desired} Running Pods</h3><div class="bar"><div class="fill" style="width:${a.health_score}%"></div></div><p>Health Score <b>${a.health_score}%</b></p><p>Container Restarts <b>${a.restarts}</b></p></div>`}
async function refresh(){let r=await fetch('/api/summary',{cache:'no-store'}),d=await r.json();ca.textContent=d.counts.applications;cp.textContent=d.counts.pods;ci.textContent=d.counts.active;cr.textContent=d.counts.recoveries;dcpu.textContent=mcpu.textContent=d.cpu+'%';dmem.textContent=mmem.textContent=d.memory+'%';dpods.textContent=mpods.textContent=d.counts.pods;dashApps.innerHTML=appCards.innerHTML=d.applications.map(appCard).join('');podRows.innerHTML=d.pods.map(p=>`<tr><td>${p.name}</td><td>${p.app}</td><td>${p.phase}</td><td class="${p.ready?'green':'red'}">${p.ready?'Ready':'Not Ready'}</td><td>${p.restarts}</td><td>${p.node}</td><td>${p.ip}</td></tr>`).join('');incidentRows.innerHTML=d.incidents.map(i=>`<tr><td>#${i.id}</td><td>${i.time}</td><td>${i.application}</td><td>${i.type}</td><td class="red">${i.severity}</td><td class="${i.status==='Recovered'?'green':'red'}">${i.status}</td><td>${i.action}</td><td>${i.recovery_seconds?i.recovery_seconds+'s':'-'}</td></tr>`).join('')||'<tr><td colspan="8">No incidents yet</td></tr>'}
async function crash(app){msg.textContent='Injecting controlled fault...';let r=await fetch('/api/experiments/crash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:app})});let d=await r.json();msg.textContent=d.ok?'Incident created; watching Kubernetes recovery...':d.message;refresh()}
async function loadSettings(){let d=await (await fetch('/api/settings')).json();cpuWarning.value=d.cpu_warning;cpuCritical.value=d.cpu_critical;memWarning.value=d.memory_warning;memCritical.value=d.memory_critical}
async function saveSettings(){let body={cpu_warning:+cpuWarning.value,cpu_critical:+cpuCritical.value,memory_warning:+memWarning.value,memory_critical:+memCritical.value};await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});settingsMsg.textContent='Saved'}
refresh();loadSettings();setInterval(refresh,1500);
</script></body></html>
HTML

log "Building image $IMAGE"
cd "$APP"
minikube image build -t "$IMAGE" .

log "Updating deployment"
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl -n "$NS" patch deployment kubeheal -p '{"spec":{"template":{"spec":{"containers":[{"name":"kubeheal","imagePullPolicy":"Never"}]}}}}'
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s

log "Phase 3 ready"
kubectl get pods -n "$NS"
echo
echo "If your existing port-forward is running, refresh the browser."
echo "Otherwise run:"
echo "kubectl port-forward --address=0.0.0.0 svc/kubeheal 8080:8080 -n $NS"
echo "Open: http://<EC2-PUBLIC-IP>:8080"
