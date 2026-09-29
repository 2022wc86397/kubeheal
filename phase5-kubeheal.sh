#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
IMAGE="kubeheal:5.0"
log(){ printf '\n[KubeHeal Phase 5] %s\n' "$1"; }
[[ -f "$APP/app.py" ]] || { echo "Run Phase 3/4 first."; exit 1; }

log "Replacing backend with Phase 5 incident snapshot engine"
cat >"$APP/app.py" <<'PY'
from flask import Flask, jsonify, render_template, request
from kubernetes import client, config
import requests, os, threading, time
from datetime import datetime, timezone

app=Flask(__name__)
NS=os.getenv("DEMO_NAMESPACE","kubeheal-demo")
PROM=os.getenv("PROMETHEUS_URL","http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090")
config.load_incluster_config(); core=client.CoreV1Api(); apps=client.AppsV1Api()
lock=threading.RLock(); incidents=[]; next_id=1

def now(): return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
def prom(q):
    try:
        r=requests.get(PROM+"/api/v1/query",params={"query":q},timeout=4); r.raise_for_status(); x=r.json()["data"]["result"]
        return float(x[0]["value"][1]) if x else None
    except Exception: return None

def pod_list(appname=None):
    out=[]
    for p in core.list_namespaced_pod(NS).items:
        a=(p.metadata.labels or {}).get("app","-")
        if appname and a!=appname: continue
        ready=any(c.type=="Ready" and c.status=="True" for c in (p.status.conditions or []))
        out.append({"name":p.metadata.name,"uid":p.metadata.uid,"app":a,"phase":p.status.phase,"ready":ready,"restarts":sum(s.restart_count for s in (p.status.container_statuses or []))})
    return sorted(out,key=lambda x:x["name"])
def metrics(appname):
    cpu=prom(f'sum(rate(container_cpu_usage_seconds_total{{namespace="{NS}",pod=~"{appname}-.*",container!="",container!="POD"}}[1m]))')
    mem=prom(f'sum(container_memory_working_set_bytes{{namespace="{NS}",pod=~"{appname}-.*",container!="",container!="POD"}})')
    return {"cpu_cores":round(cpu or 0,4),"memory_mib":round((mem or 0)/1024/1024,1)}
def snapshot(appname,label):
    d=apps.read_namespaced_deployment(appname,NS); ps=pod_list(appname); m=metrics(appname)
    desired=d.spec.replicas or 0; ready=d.status.ready_replicas or 0
    return {"label":label,"captured_at":now(),"desired":desired,"ready":ready,"health":"HEALTHY" if desired and ready==desired else "UNHEALTHY","pods":ps,"cpu_cores":m["cpu_cores"],"memory_mib":m["memory_mib"]}
def deployments():
    return [{"name":d.metadata.name,"desired":d.spec.replicas or 0,"ready":d.status.ready_replicas or 0,"status":"healthy" if (d.status.ready_replicas or 0)==(d.spec.replicas or 0) else "unhealthy"} for d in apps.list_namespaced_deployment(NS).items]
def create_incident(appname,typ,severity,action,before):
    global next_id
    with lock:
        i={"id":next_id,"application":appname,"type":typ,"severity":severity,"status":"ACTIVE","detected_at":now(),"resolved_at":None,"recovery_action":action,"recovery_owner":"Kubernetes / KubeHeal","recovery_seconds":None,"progress":["Incident detected","Classifying incident"],"before":before,"during":None,"after":None,"old_pods":[p["name"] for p in before["pods"]],"new_pods":[]}
        next_id+=1; incidents.insert(0,i); return i
def set_during(inc,appname):
    time.sleep(1)
    with lock: inc["during"]=snapshot(appname,"During Incident"); inc["status"]="RECOVERING"; inc["progress"].append("Executing recovery action")
def verify_recovery(inc,appname,start,timeout=90):
    end=time.time()+timeout
    while time.time()<end:
        d=apps.read_namespaced_deployment(appname,NS)
        if (d.status.ready_replicas or 0)==(d.spec.replicas or 0) and (d.spec.replicas or 0)>0:
            after=snapshot(appname,"After Recovery"); old=set(inc["old_pods"]); new=[p["name"] for p in after["pods"] if p["name"] not in old]
            with lock:
                inc["progress"] += ["Verifying recovery","Recovery verified","Completed"]
                inc["after"]=after; inc["new_pods"]=new; inc["status"]="RECOVERED"; inc["resolved_at"]=now(); inc["recovery_seconds"]=round(time.time()-start,1)
            return
        time.sleep(1)
    with lock: inc["status"]="FAILED"; inc["progress"].append("Recovery verification timed out")

def run_crash(appname):
    before=snapshot(appname,"Before Incident"); inc=create_incident(appname,"Pod Failure","HIGH","Observe Deployment controller replacement",before); candidates=[p for p in before["pods"] if p["ready"]]
    if not candidates: return None
    core.delete_namespaced_pod(candidates[0]["name"],NS); start=time.time(); threading.Thread(target=set_during,args=(inc,appname),daemon=True).start(); threading.Thread(target=verify_recovery,args=(inc,appname,start),daemon=True).start(); return inc

def run_notready(appname):
    before=snapshot(appname,"Before Incident"); d=apps.read_namespaced_deployment(appname,NS); original=d.spec.replicas or 1; inc=create_incident(appname,"Replica Unavailable","MEDIUM",f"Restore desired replicas 0 -> {original}",before); start=time.time(); apps.patch_namespaced_deployment_scale(appname,NS,{"spec":{"replicas":0}})
    def heal():
        set_during(inc,appname); time.sleep(5); apps.patch_namespaced_deployment_scale(appname,NS,{"spec":{"replicas":original}}); verify_recovery(inc,appname,start)
    threading.Thread(target=heal,daemon=True).start(); return inc

def run_restart(appname):
    before=snapshot(appname,"Before Incident"); inc=create_incident(appname,"Controlled Restart","MEDIUM","Rolling restart Deployment",before); start=time.time(); stamp=str(int(time.time())); apps.patch_namespaced_deployment(appname,NS,{"spec":{"template":{"metadata":{"annotations":{"kubeheal/restartedAt":stamp}}}}})
    threading.Thread(target=set_during,args=(inc,appname),daemon=True).start(); threading.Thread(target=verify_recovery,args=(inc,appname,start),daemon=True).start(); return inc

@app.get("/")
def index(): return render_template("dashboard.html")
@app.get("/api/summary")
def summary():
    ds=deployments(); ps=pod_list(); cpu=prom('100*(1-avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))') or 0; mem=prom('100*(1-(sum(node_memory_MemAvailable_bytes)/sum(node_memory_MemTotal_bytes)))') or 0
    return jsonify({"applications":ds,"pods":ps,"counts":{"applications":len(ds),"pods":len(ps),"active":sum(i["status"] in ["ACTIVE","RECOVERING"] for i in incidents),"recoveries":sum(i["status"]=="RECOVERED" for i in incidents)},"cpu":round(cpu,1),"memory":round(mem,1),"incidents":incidents})
@app.get("/api/incidents/<int:iid>")
def incident(iid):
    x=next((i for i in incidents if i["id"]==iid),None); return jsonify(x) if x else (jsonify({"error":"not found"}),404)
@app.post("/api/experiments/<kind>")
def experiment(kind):
    name=(request.json or {}).get("application","backend")
    if kind=="crash": inc=run_crash(name)
    elif kind=="not-ready": inc=run_notready(name)
    elif kind=="restart": inc=run_restart(name)
    else: return jsonify({"ok":False,"message":"Unsupported experiment"}),400
    return jsonify({"ok":bool(inc),"incident":inc})
@app.get("/api/system/health")
def health(): return jsonify({"status":"ok"})
PY

log "Replacing UI with Phase 5 incident detail / before-during-after view"
cat >"$APP/templates/dashboard.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KubeHeal</title><style>*{box-sizing:border-box}body{margin:0;font:14px Arial;background:#f5f7fb;color:#172033}.side{position:fixed;width:200px;height:100vh;background:#0c203a;color:white;padding:20px}.brand{font-size:22px;font-weight:bold;margin-bottom:25px}.nav{padding:12px;margin:5px 0;border-radius:7px;cursor:pointer}.nav:hover,.nav.active{background:#1769e0}.main{margin-left:200px;padding:28px}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.three{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.card,.panel{background:white;border:1px solid #dde4ed;border-radius:9px;padding:18px;margin-bottom:16px}.num{font-size:27px;font-weight:bold}.green{color:#119653}.red{color:#dc3030}.orange{color:#d47d00}.badge{padding:5px 10px;border-radius:14px;background:#dcf8e8;color:#08783d}.view{display:none}.view.active{display:block}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #e8edf3;text-align:left}button{border:0;border-radius:6px;background:#1769e0;color:white;padding:9px 13px;cursor:pointer}.danger{background:#e53935}.state{min-height:235px}.pod{padding:6px;background:#f3f6fa;border-radius:5px;margin:4px 0}.step{padding:8px;border-left:3px solid #2caf63;margin:5px}.muted{color:#68768a}@media(max-width:900px){.side{display:none}.main{margin-left:0}.grid,.three{grid-template-columns:1fr}}</style></head><body><aside class="side"><div class="brand">⬡ KubeHeal</div><div class="nav active" onclick="show('dashboard',this)">Dashboard</div><div class="nav" onclick="show('incidents',this)">Incidents</div><div class="nav" onclick="show('experiments',this)">Experiments</div></aside><main class="main"><h1 id="pageTitle">Dashboard</h1><section id="dashboard" class="view active"><div class="grid"><div class="card">Applications<div id="ca" class="num">-</div></div><div class="card">Pods<div id="cp" class="num">-</div></div><div class="card">Active Incidents<div id="ci" class="num red">-</div></div><div class="card">Recoveries<div id="cr" class="num green">-</div></div></div><div class="panel"><h2>Application Health</h2><div id="apps" class="three"></div></div></section><section id="incidents" class="view"><div class="panel"><h2>Incident History</h2><table><thead><tr><th>ID</th><th>Application</th><th>Issue</th><th>Status</th><th>Recovery Action</th><th>Recovery Time</th><th></th></tr></thead><tbody id="rows"></tbody></table></div><div id="detail"></div></section><section id="experiments" class="view"><div class="three"><div class="card"><h2>Crash Pod</h2><p>Delete one backend Pod and observe Deployment replacement.</p><button class="danger" onclick="run('crash')">Trigger Crash</button></div><div class="card"><h2>Pod Not Ready</h2><p>Temporarily make backend replicas unavailable, then automatically restore them.</p><button onclick="run('not-ready')">Trigger Not Ready</button></div><div class="card"><h2>Restart Deployment</h2><p>Perform a controlled backend rolling restart and verify readiness.</p><button onclick="run('restart')">Trigger Restart</button></div></div><p id="msg"></p></section></main><script>
function show(id,n){document.querySelectorAll('.view,.nav').forEach(x=>x.classList.remove('active'));document.getElementById(id).classList.add('active');n.classList.add('active');pageTitle.textContent=id[0].toUpperCase()+id.slice(1)}
function appcard(a){return `<div class="card"><h2>${a.name} <span class="badge">${a.status}</span></h2><div class="num">${a.ready}/${a.desired} Ready</div></div>`}
function state(s){if(!s)return '<div class="state"><b>Waiting for snapshot...</b></div>';return `<div class="state"><h3>${s.label}</h3><div class="num ${s.health==='HEALTHY'?'green':'red'}">${s.health}</div><p>Replicas: <b>${s.ready}/${s.desired}</b></p><p>CPU: <b>${s.cpu_cores} cores</b></p><p>Memory: <b>${s.memory_mib} MiB</b></p><b>Pods</b>${s.pods.map(p=>`<div class="pod">${p.name}<br>${p.ready?'Ready':'Not Ready'} | Restarts ${p.restarts}</div>`).join('')}</div>`}
async function refresh(){let d=await (await fetch('/api/summary',{cache:'no-store'})).json();ca.textContent=d.counts.applications;cp.textContent=d.counts.pods;ci.textContent=d.counts.active;cr.textContent=d.counts.recoveries;apps.innerHTML=d.applications.map(appcard).join('');rows.innerHTML=d.incidents.map(i=>`<tr><td>#${i.id}</td><td>${i.application}</td><td>${i.type}</td><td class="${i.status==='RECOVERED'?'green':'red'}">${i.status}</td><td>${i.recovery_action}</td><td>${i.recovery_seconds?i.recovery_seconds+'s':'-'}</td><td><button onclick="details(${i.id})">View</button></td></tr>`).join('')||'<tr><td colspan="7">No incidents yet</td></tr>'}
async function details(id){let i=await (await fetch('/api/incidents/'+id)).json();detail.innerHTML=`<div class="panel"><h2>Incident #${i.id} - ${i.application} - ${i.type}</h2><p><b>Status:</b> ${i.status} &nbsp; <b>Severity:</b> ${i.severity}</p><p><b>Recovery Action:</b> ${i.recovery_action}</p><p><b>Recovery Owner:</b> ${i.recovery_owner}</p><p><b>Old Pods:</b> ${i.old_pods.join(', ')||'-'}</p><p><b>New Pods:</b> ${i.new_pods.join(', ')||'-'}</p><h3>Recovery Progress</h3>${i.progress.map(x=>`<div class="step">✓ ${x}</div>`).join('')}<h2>Before → Incident → After</h2><div class="three">${state(i.before)}${state(i.during)}${state(i.after)}</div></div>`}
async function run(k){msg.textContent='Creating '+k+' incident...';let r=await fetch('/api/experiments/'+k,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})});let d=await r.json();msg.textContent=d.ok?'Incident #'+d.incident.id+' created. Watch Incidents for recovery.':'Experiment failed';refresh()}
refresh();setInterval(refresh,1200);
</script></body></html>
HTML

log "Building $IMAGE"
cd "$APP"; minikube image build -t "$IMAGE" .
log "Deploying Phase 5"
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s
log "Phase 5 ready"
kubectl get pods -n "$NS"
echo; echo "Refresh the browser. Open Experiments, trigger an issue, then open Incidents -> View."
echo "You will see Before, During Incident, After Recovery, recovery action, old/new Pods, progress, and recovery time."
