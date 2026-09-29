#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
IMAGE="kubeheal:6.1"
log(){ printf '\n[KubeHeal 6.1] %s\n' "$1"; }
[[ -f "$APP/app.py" ]] || { echo "ERROR: Phase 6 app.py not found"; exit 1; }
[[ -f "$APP/templates/dashboard.html" ]] || { echo "ERROR: Phase 6 dashboard not found"; exit 1; }

log "Backing up Phase 6.0"
mkdir -p "$APP/backup-phase6.0"
cp -f "$APP/app.py" "$APP/backup-phase6.0/app.py"
cp -f "$APP/templates/dashboard.html" "$APP/backup-phase6.0/dashboard.html"

log "Adding experiment APIs"
cat >/tmp/kubeheal61_patch.py <<'PATCHPY'
from pathlib import Path
p=Path.home()/"kubeheal-app/app.py"
s=p.read_text()
marker="@app.get('/api/system/health')"
addon="""@app.post('/api/experiments/not-ready')
def experiment_not_ready():
    n=(request.json or {}).get('application','backend')
    before=snapshot(n,'Before Incident')
    d=apps.read_namespaced_deployment(n,NS)
    original=d.spec.replicas or 1
    iid=make(n,'REPLICA_UNAVAILABLE','MEDIUM',f'KubeHeal restore replicas 0 -> {original}',before)
    start=time.time()
    apps.patch_namespaced_deployment_scale(n,NS,{'spec':{'replicas':0}})
    time.sleep(1)
    upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Incident')))
    progress(iid,'Controlled availability fault injected')
    def restore():
        time.sleep(6)
        apps.patch_namespaced_deployment_scale(n,NS,{'spec':{'replicas':original}})
        progress(iid,'KubeHeal restored desired replicas')
        verify(iid,n,start)
    threading.Thread(target=restore,daemon=True).start()
    return jsonify({'ok':True,'id':iid})

@app.post('/api/experiments/restart')
def experiment_restart():
    n=(request.json or {}).get('application','backend')
    before=snapshot(n,'Before Incident')
    iid=make(n,'CONTROLLED_RESTART','MEDIUM','KubeHeal rolling Deployment restart',before)
    start=time.time()
    stamp=str(int(time.time()))
    apps.patch_namespaced_deployment(n,NS,{'spec':{'template':{'metadata':{'annotations':{'kubeheal/restartedAt':stamp}}}}})
    time.sleep(1)
    upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Incident')))
    progress(iid,'Rolling restart initiated')
    threading.Thread(target=verify,args=(iid,n,start),daemon=True).start()
    return jsonify({'ok':True,'id':iid})

"""
if 'def experiment_not_ready()' not in s:
    if marker not in s: raise SystemExit('Phase 6 health route marker not found')
    s=s.replace(marker,addon+marker,1)
p.write_text(s)
PATCHPY
python3 /tmp/kubeheal61_patch.py

log "Writing complete Phase 6.1 UI"
# Copy current dashboard, then replace only the experiments section and its JS handler.
cat >/tmp/kubeheal61_ui_patch.py <<'PATCHPY'
from pathlib import Path
p=Path.home()/"kubeheal-app/templates/dashboard.html"
s=p.read_text()
start=s.index('<section id="experiments"')
end=s.index('</section>',start)+len('</section>')
section="""<section id="experiments" class="view"><div class="grid"><div class="card"><h2>Crash Backend Pod</h2><p>Delete one backend Pod and observe Kubernetes replacement.</p><button class="danger" onclick="runExp('crash')">Trigger Crash</button></div><div class="card"><h2>Pod Not Ready</h2><p>Temporarily remove backend replicas and automatically restore the original desired count.</p><button onclick="runExp('not-ready')">Trigger Not Ready</button></div><div class="card"><h2>Controlled Restart</h2><p>Initiate a rolling Deployment restart and verify readiness returns.</p><button onclick="runExp('restart')">Trigger Restart</button></div><div class="card"><h2>CPU Overload</h2><p>Automatically detected from Prometheus when application CPU stays above the configured critical threshold.</p><span class="badge">Automatic Detection</span></div><div class="card"><h2>Memory Pressure</h2><p>Automatically detected from Prometheus when memory stays above the configured critical threshold.</p><span class="badge">Automatic Detection</span></div><div class="card"><h2>Restart Threshold</h2><p>Automatically detected when container restart count reaches the configured threshold.</p><span class="badge">Automatic Detection</span></div></div><p id="msg"></p></section>"""
s=s[:start]+section+s[end:]
# Replace the old crash-only JS function with generic experiment handler.
old="async function crash(){let d=await (await fetch('/api/experiments/crash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})})).json();msg.textContent=d.ok?' Incident #'+d.id+' created':' Failed'}"
new="async function runExp(kind){msg.textContent=' Triggering '+kind+'...';let d=await (await fetch('/api/experiments/'+kind,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})})).json();msg.textContent=d.ok?' Incident #'+d.id+' created. Open Incidents to watch recovery.':' Failed'}"
if old not in s: raise SystemExit('Phase 6 crash JS handler not found')
s=s.replace(old,new,1)
p.write_text(s)
PATCHPY
python3 /tmp/kubeheal61_ui_patch.py

log "Validating Python and shell-generated artifacts"
cd "$APP"
python3 -m py_compile app.py

grep -q "experiment_not_ready" app.py
grep -q "experiment_restart" app.py
grep -q "CPU Overload" templates/dashboard.html
grep -q "Memory Pressure" templates/dashboard.html
grep -q "Restart Threshold" templates/dashboard.html

log "Building image $IMAGE"
minikube image build -t "$IMAGE" .
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s

log "Verification"
kubectl get pods -n "$NS"
echo
echo "KubeHeal 6.1 installed successfully."
echo "Experiments: Crash Pod, Pod Not Ready, Controlled Restart."
echo "Automatic incident cards: CPU Overload, Memory Pressure, Restart Threshold."
echo "Hard-refresh the browser with Ctrl+Shift+R."
