#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
DEMO="kubeheal-demo"
IMAGE="kubeheal:6.0"
log(){ printf '\n[KubeHeal 6] %s\n' "$1"; }
fail(){ echo "ERROR: $1" >&2; exit 1; }
command -v kubectl >/dev/null || fail "kubectl missing"
command -v minikube >/dev/null || fail "minikube missing"
kubectl get ns "$NS" >/dev/null || fail "kubeheal-system missing"
kubectl get ns "$DEMO" >/dev/null || fail "kubeheal-demo missing"

log "Backing up current KubeHeal"
mkdir -p "$APP/backup-pre-phase6" "$APP/templates"
[ -f "$APP/app.py" ] && cp -f "$APP/app.py" "$APP/backup-pre-phase6/app.py" || true
[ -f "$APP/templates/dashboard.html" ] && cp -f "$APP/templates/dashboard.html" "$APP/backup-pre-phase6/dashboard.html" || true

log "Writing standalone backend"
cat > "$APP/app.py" <<'PY'
from flask import Flask, jsonify, render_template, request
from kubernetes import client, config
import json, os, sqlite3, threading, time, requests
from datetime import datetime, timezone
app=Flask(__name__)
NS=os.getenv('DEMO_NAMESPACE','kubeheal-demo')
PROM=os.getenv('PROMETHEUS_URL','http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090')
DB=os.getenv('DB_PATH','/data/kubeheal.db')
config.load_incluster_config(); core=client.CoreV1Api(); apps=client.AppsV1Api()
DEFAULT={'cpu_critical':90.0,'memory_critical':90.0,'restart_critical':3.0,'sustain_cycles':3.0,'cooldown_seconds':60.0}
strikes={}; last_created={}
def utc(): return datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
def db():
    os.makedirs(os.path.dirname(DB),exist_ok=True); c=sqlite3.connect(DB,timeout=10); c.row_factory=sqlite3.Row; return c
def initdb():
    with db() as c:
        c.execute('CREATE TABLE IF NOT EXISTS incidents(id INTEGER PRIMARY KEY AUTOINCREMENT,application TEXT,type TEXT,severity TEXT,status TEXT,detected_at TEXT,resolved_at TEXT,recovery_action TEXT,recovery_seconds REAL,before_json TEXT,during_json TEXT,after_json TEXT,progress_json TEXT)')
        c.execute('CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT)')
        for k,v in DEFAULT.items(): c.execute('INSERT OR IGNORE INTO settings VALUES(?,?)',(k,str(v)))
initdb()
def policy():
    with db() as c:return {r['key']:float(r['value']) for r in c.execute('SELECT key,value FROM settings')}
def prom(q):
    try:
        r=requests.get(PROM+'/api/v1/query',params={'query':q},timeout=4); r.raise_for_status(); x=r.json()['data']['result']; return float(x[0]['value'][1]) if x else 0.0
    except Exception:return 0.0
def pods(name=None):
    out=[]
    for p in core.list_namespaced_pod(NS).items:
        a=(p.metadata.labels or {}).get('app','-')
        if name and a!=name: continue
        ready=any(c.type=='Ready' and c.status=='True' for c in (p.status.conditions or []))
        out.append({'name':p.metadata.name,'app':a,'phase':p.status.phase,'ready':ready,'restarts':sum(s.restart_count for s in (p.status.container_statuses or []))})
    return sorted(out,key=lambda x:x['name'])
def raw_metrics(name):
    cpu=prom(f'sum(rate(container_cpu_usage_seconds_total{{namespace="{NS}",pod=~"{name}-.*",container!="",container!="POD"}}[2m]))')
    mem=prom(f'sum(container_memory_working_set_bytes{{namespace="{NS}",pod=~"{name}-.*",container!="",container!="POD"}})')
    cpu_lim=prom(f'sum(kube_pod_container_resource_limits{{namespace="{NS}",pod=~"{name}-.*",resource="cpu"}})')
    mem_lim=prom(f'sum(kube_pod_container_resource_limits{{namespace="{NS}",pod=~"{name}-.*",resource="memory"}})')
    return {'cpu_cores':round(cpu,4),'memory_mib':round(mem/1048576,1),'cpu_percent':round(100*cpu/cpu_lim,1) if cpu_lim else 0.0,'memory_percent':round(100*mem/mem_lim,1) if mem_lim else 0.0}
def snapshot(name,label):
    d=apps.read_namespaced_deployment(name,NS); desired=d.spec.replicas or 0; ready=d.status.ready_replicas or 0
    return {'label':label,'time':utc(),'desired':desired,'ready':ready,'health':'HEALTHY' if desired>0 and ready==desired else 'UNHEALTHY','pods':pods(name),**raw_metrics(name)}
def deployments():
    out=[]
    for d in apps.list_namespaced_deployment(NS).items:
        n=d.metadata.name; des=d.spec.replicas or 0; rd=d.status.ready_replicas or 0
        out.append({'name':n,'desired':des,'ready':rd,'status':'healthy' if des>0 and rd==des else 'unhealthy',**raw_metrics(n)})
    return sorted(out,key=lambda x:x['name'])
def make(name,typ,sev,action,before):
    with db() as c:
        cur=c.execute('INSERT INTO incidents(application,type,severity,status,detected_at,recovery_action,before_json,progress_json) VALUES(?,?,?,?,?,?,?,?)',(name,typ,sev,'ACTIVE',utc(),action,json.dumps(before),json.dumps(['Incident detected','Incident classified'])))
        return cur.lastrowid
def upd(iid,**kw):
    if not kw:return
    with db() as c:c.execute('UPDATE incidents SET '+','.join(k+'=?' for k in kw)+' WHERE id=?',list(kw.values())+[iid])
def progress(iid,msg):
    with db() as c:
        r=c.execute('SELECT progress_json FROM incidents WHERE id=?',(iid,)).fetchone(); a=json.loads(r[0] or '[]'); a.append(msg); c.execute('UPDATE incidents SET progress_json=? WHERE id=?',(json.dumps(a),iid))
def asobj(r):
    d=dict(r)
    for src,dst in [('before_json','before'),('during_json','during'),('after_json','after'),('progress_json','progress')]:
        raw=d.pop(src); d[dst]=json.loads(raw) if raw else ([] if dst=='progress' else None)
    return d
def active(name,typ):
    with db() as c:return c.execute("SELECT 1 FROM incidents WHERE application=? AND type=? AND status IN ('ACTIVE','RECOVERING') LIMIT 1",(name,typ)).fetchone() is not None
def verify(iid,name,start,timeout=90):
    end=time.time()+timeout
    while time.time()<end:
        d=apps.read_namespaced_deployment(name,NS)
        if (d.spec.replicas or 0)>0 and (d.status.ready_replicas or 0)==(d.spec.replicas or 0):
            progress(iid,'Recovery verified'); upd(iid,status='RECOVERED',resolved_at=utc(),recovery_seconds=round(time.time()-start,1),after_json=json.dumps(snapshot(name,'After Recovery'))); return
        time.sleep(1)
    upd(iid,status='FAILED'); progress(iid,'Recovery verification timed out')
def maybe_incident(name,typ,sev,action,snap,pol):
    key=(name,typ); strikes[key]=strikes.get(key,0)+1
    if strikes[key] < int(pol['sustain_cycles']) or active(name,typ): return
    if time.time()-last_created.get(key,0) < pol['cooldown_seconds']: return
    iid=make(name,typ,sev,action,snap); upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(name,'During Incident'))); progress(iid,'Automatic detector created incident'); last_created[key]=time.time(); strikes[key]=0
    threading.Thread(target=verify,args=(iid,name,time.time()),daemon=True).start()
def monitor():
    while True:
        try:
            pol=policy()
            for a in deployments():
                n=a['name']; s=snapshot(n,'Automatic Detection'); current=set()
                rules=[]
                if a['ready']<a['desired']: rules.append(('REPLICA_DEGRADED','HIGH','Observe Kubernetes Deployment reconciliation'))
                if any(not p['ready'] for p in s['pods']): rules.append(('POD_NOT_READY','MEDIUM','Observe readiness/liveness recovery'))
                if sum(p['restarts'] for p in s['pods'])>=int(pol['restart_critical']): rules.append(('RESTART_THRESHOLD','HIGH','Observe restart stabilization'))
                if a['cpu_percent']>=pol['cpu_critical']: rules.append(('CPU_OVERLOAD','HIGH','Observe load and apply bounded scaling policy'))
                if a['memory_percent']>=pol['memory_critical']: rules.append(('MEMORY_PRESSURE','HIGH','Observe memory pressure and workload health'))
                for typ,sev,act in rules: current.add(typ); maybe_incident(n,typ,sev,act,s,pol)
                for key in list(strikes):
                    if key[0]==n and key[1] not in current:strikes[key]=0
        except Exception as e: print('monitor error:',e,flush=True)
        time.sleep(5)
threading.Thread(target=monitor,daemon=True).start()
@app.get('/')
def home():return render_template('dashboard.html')
@app.get('/api/summary')
def summary():
    ds=deployments(); ps=pods(); cpu=prom('100*(1-avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))'); mem=prom('100*(1-(sum(node_memory_MemAvailable_bytes)/sum(node_memory_MemTotal_bytes)))')
    with db() as c: inc=[asobj(r) for r in c.execute('SELECT * FROM incidents ORDER BY id DESC LIMIT 100')]
    return jsonify({'applications':ds,'pods':ps,'cpu':round(cpu,1),'memory':round(mem,1),'incidents':inc,'counts':{'applications':len(ds),'pods':len(ps),'active':sum(i['status'] in ('ACTIVE','RECOVERING') for i in inc),'recoveries':sum(i['status']=='RECOVERED' for i in inc)}})
@app.get('/api/incidents/<int:iid>')
def incident(iid):
    with db() as c:r=c.execute('SELECT * FROM incidents WHERE id=?',(iid,)).fetchone()
    return jsonify(asobj(r)) if r else (jsonify({'error':'not found'}),404)
@app.get('/api/settings')
def getsettings():return jsonify(policy())
@app.post('/api/settings')
def savesettings():
    data=request.json or {}
    with db() as c:
        for k,v in data.items():
            if k in DEFAULT:c.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(k,str(v)))
    return jsonify(policy())
@app.post('/api/experiments/crash')
def crash():
    n=(request.json or {}).get('application','backend'); before=snapshot(n,'Before Incident'); cand=[p for p in before['pods'] if p['ready']]
    if not cand:return jsonify({'ok':False,'message':'No ready Pod'}),404
    iid=make(n,'POD_FAILURE','HIGH','Kubernetes Deployment controller replacement',before); core.delete_namespaced_pod(cand[0]['name'],NS); time.sleep(.5); upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Incident'))); progress(iid,'Native recovery in progress'); threading.Thread(target=verify,args=(iid,n,time.time()),daemon=True).start(); return jsonify({'ok':True,'id':iid})
@app.get('/api/system/health')
def health():return jsonify({'status':'ok'})
PY

log "Writing full UI"
cat > "$APP/templates/dashboard.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KubeHeal 6</title><style>body{margin:0;font:14px Arial;background:#f5f7fb;color:#172033}.side{position:fixed;width:190px;height:100vh;background:#10223d;color:white;padding:20px}.brand{font-size:22px;font-weight:bold;margin-bottom:25px}.nav{padding:12px;border-radius:7px;cursor:pointer}.nav.active,.nav:hover{background:#3673df}.main{margin-left:220px;padding:28px}.view{display:none}.view.active{display:block}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:15px}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:15px}.card,.panel{background:white;border:1px solid #dde4ec;border-radius:9px;padding:18px;margin-bottom:16px}.num{font-size:28px;font-weight:bold}.green{color:#14954f}.red{color:#dc3535}.badge{padding:5px 9px;border-radius:14px;background:#ddf8e8;color:#08783d}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid #e7edf3;text-align:left}button{background:#246de1;color:white;border:0;border-radius:6px;padding:9px 13px;cursor:pointer}.danger{background:#df3b37}.pod,.step{padding:7px;margin:4px;background:#f3f6fa;border-radius:5px}.metric{font-size:32px;font-weight:bold}.setting{display:flex;justify-content:space-between;padding:10px;border-bottom:1px solid #eee}input{width:90px;padding:6px}</style></head><body><aside class="side"><div class="brand">⬡ KubeHeal</div><div class="nav active" data-p="dashboard">Dashboard</div><div class="nav" data-p="applications">Applications</div><div class="nav" data-p="pods">Pods</div><div class="nav" data-p="incidents">Incidents</div><div class="nav" data-p="experiments">Experiments</div><div class="nav" data-p="metrics">Metrics</div><div class="nav" data-p="settings">Settings</div></aside><main class="main"><h1 id="title">Dashboard</h1><section id="dashboard" class="view active"><div class="stats"><div class="card">Applications<div id="ca" class="num">-</div></div><div class="card">Pods<div id="cp" class="num">-</div></div><div class="card">Active Incidents<div id="ci" class="num red">-</div></div><div class="card">Recoveries<div id="cr" class="num green">-</div></div></div><div class="panel"><h2>Application Health</h2><div id="dashApps" class="grid"></div></div></section><section id="applications" class="view"><div id="appCards" class="grid"></div></section><section id="pods" class="view"><div class="panel"><table><thead><tr><th>Pod</th><th>App</th><th>Phase</th><th>Ready</th><th>Restarts</th></tr></thead><tbody id="podRows"></tbody></table></div></section><section id="incidents" class="view"><div class="panel"><table><thead><tr><th>ID</th><th>App</th><th>Type</th><th>Status</th><th>Recovery Action</th><th></th></tr></thead><tbody id="incidentRows"></tbody></table></div><div id="detail"></div></section><section id="experiments" class="view"><div class="card"><h2>Crash Backend Pod</h2><button class="danger" onclick="crash()">Trigger Crash</button><span id="msg"></span></div></section><section id="metrics" class="view"><div class="grid"><div class="card">Cluster CPU<div id="cpu" class="metric">-</div></div><div class="card">Cluster Memory<div id="mem" class="metric">-</div></div><div class="card">Pods<div id="mpods" class="metric">-</div></div></div></section><section id="settings" class="view"><div class="panel"><h2>Automatic Detection Policy</h2><div class="setting">CPU Critical %<input id="cpuC" type="number"></div><div class="setting">Memory Critical %<input id="memC" type="number"></div><div class="setting">Restart threshold<input id="restC" type="number"></div><div class="setting">Sustain cycles<input id="cycles" type="number"></div><div class="setting">Cooldown seconds<input id="cool" type="number"></div><br><button onclick="save()">Save</button><span id="saved"></span></div></section></main><script>
document.querySelectorAll('.nav').forEach(n=>n.onclick=()=>{document.querySelectorAll('.nav,.view').forEach(x=>x.classList.remove('active'));n.classList.add('active');document.getElementById(n.dataset.p).classList.add('active');title.textContent=n.textContent});
function card(a){return `<div class="card"><h2>${a.name} <span class="badge">${a.status}</span></h2><div class="num">${a.ready}/${a.desired} Ready</div><p>CPU ${a.cpu_percent}% (${a.cpu_cores} cores)</p><p>Memory ${a.memory_percent}% (${a.memory_mib} MiB)</p></div>`}
function snap(s){if(!s)return '<div class="card">Waiting...</div>';return `<div class="card"><h3>${s.label}</h3><div class="num ${s.health==='HEALTHY'?'green':'red'}">${s.health}</div><p>${s.ready}/${s.desired} Ready</p><p>CPU ${s.cpu_percent}% | Memory ${s.memory_percent}%</p>${s.pods.map(p=>`<div class="pod">${p.name}: ${p.ready?'Ready':'Not Ready'}; restarts ${p.restarts}</div>`).join('')}</div>`}
async function refresh(){let d=await (await fetch('/api/summary',{cache:'no-store'})).json();ca.textContent=d.counts.applications;cp.textContent=d.counts.pods;ci.textContent=d.counts.active;cr.textContent=d.counts.recoveries;cpu.textContent=d.cpu+'%';mem.textContent=d.memory+'%';mpods.textContent=d.counts.pods;dashApps.innerHTML=appCards.innerHTML=d.applications.map(card).join('');podRows.innerHTML=d.pods.map(p=>`<tr><td>${p.name}</td><td>${p.app}</td><td>${p.phase}</td><td class="${p.ready?'green':'red'}">${p.ready?'Ready':'Not Ready'}</td><td>${p.restarts}</td></tr>`).join('');incidentRows.innerHTML=d.incidents.map(i=>`<tr><td>#${i.id}</td><td>${i.application}</td><td>${i.type}</td><td class="${i.status==='RECOVERED'?'green':'red'}">${i.status}</td><td>${i.recovery_action}</td><td><button onclick="detail(${i.id})">View</button></td></tr>`).join('')||'<tr><td colspan="6">No incidents</td></tr>'}
async function detail(id){let i=await (await fetch('/api/incidents/'+id)).json();detail.innerHTML=`<div class="panel"><h2>Incident #${i.id} ${i.type}</h2><p><b>Action:</b> ${i.recovery_action}</p>${i.progress.map(x=>`<div class="step">✓ ${x}</div>`).join('')}<h2>Before → During → After</h2><div class="grid">${snap(i.before)}${snap(i.during)}${snap(i.after)}</div></div>`}
async function crash(){let d=await (await fetch('/api/experiments/crash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})})).json();msg.textContent=d.ok?' Incident #'+d.id+' created':' Failed'}
async function load(){let d=await (await fetch('/api/settings')).json();cpuC.value=d.cpu_critical;memC.value=d.memory_critical;restC.value=d.restart_critical;cycles.value=d.sustain_cycles;cool.value=d.cooldown_seconds}async function save(){await fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({cpu_critical:+cpuC.value,memory_critical:+memC.value,restart_critical:+restC.value,sustain_cycles:+cycles.value,cooldown_seconds:+cool.value})});saved.textContent=' Saved'}
load();refresh();setInterval(refresh,1500);
</script></body></html>
HTML

log "Updating Dockerfile"
cat > "$APP/Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
EXPOSE 8080
CMD ["gunicorn","--bind","0.0.0.0:8080","--workers","1","--threads","4","app:app"]
DOCKER

log "Creating persistent volume"
cat >/tmp/kubeheal6-pvc.yaml <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kubeheal-data
  namespace: kubeheal-system
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
YAML
kubectl apply -f /tmp/kubeheal6-pvc.yaml

log "Validating and building"
cd "$APP"
python3 -m py_compile app.py
minikube image build -t "$IMAGE" .

log "Deploying"
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl -n "$NS" patch deployment kubeheal --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"kubeheal","env":[{"name":"DEMO_NAMESPACE","value":"kubeheal-demo"},{"name":"PROMETHEUS_URL","value":"http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"},{"name":"DB_PATH","value":"/data/kubeheal.db"}],"volumeMounts":[{"name":"kubeheal-data","mountPath":"/data"}]}],"volumes":[{"name":"kubeheal-data","persistentVolumeClaim":{"claimName":"kubeheal-data"}}]}}}}'
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s
kubectl get pods,pvc -n "$NS"
echo;echo "KubeHeal Phase 6 standalone replacement installed. Hard-refresh the browser."
