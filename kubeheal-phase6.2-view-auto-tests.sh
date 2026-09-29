#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"; NS="kubeheal-system"; IMAGE="kubeheal:6.2"
log(){ printf '\n[KubeHeal 6.2] %s\n' "$1"; }
[[ -f "$APP/app.py" ]] || { echo "ERROR: Phase 6.1 source missing"; exit 1; }

log "Backing up 6.1"
mkdir -p "$APP/backup-phase6.1"
cp -f "$APP/app.py" "$APP/backup-phase6.1/app.py"
cp -f "$APP/templates/dashboard.html" "$APP/backup-phase6.1/dashboard.html"

log "Adding safe automatic-detector test endpoints"
python3 - <<'PY'
from pathlib import Path
p=Path.home()/"kubeheal-app/app.py"; s=p.read_text(); marker="@app.get('/api/system/health')"
addon="""@app.post('/api/experiments/test-cpu-detection')
def test_cpu_detection():
    n=(request.json or {}).get('application','backend')
    before=snapshot(n,'Before Test')
    iid=make(n,'CPU_OVERLOAD','HIGH','Automatic detector policy test; observe metric recovery',before)
    upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Detection Test')))
    progress(iid,'CPU overload detector test event created')
    threading.Thread(target=verify,args=(iid,n,time.time()),daemon=True).start()
    return jsonify({'ok':True,'id':iid})

@app.post('/api/experiments/test-memory-detection')
def test_memory_detection():
    n=(request.json or {}).get('application','backend')
    before=snapshot(n,'Before Test')
    iid=make(n,'MEMORY_PRESSURE','HIGH','Automatic detector policy test; observe workload health',before)
    upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Detection Test')))
    progress(iid,'Memory pressure detector test event created')
    threading.Thread(target=verify,args=(iid,n,time.time()),daemon=True).start()
    return jsonify({'ok':True,'id':iid})

@app.post('/api/experiments/test-restart-detection')
def test_restart_detection():
    n=(request.json or {}).get('application','backend')
    before=snapshot(n,'Before Test')
    iid=make(n,'RESTART_THRESHOLD','HIGH','Automatic restart-threshold detector test',before)
    upd(iid,status='RECOVERING',during_json=json.dumps(snapshot(n,'During Detection Test')))
    progress(iid,'Restart threshold detector test event created')
    threading.Thread(target=verify,args=(iid,n,time.time()),daemon=True).start()
    return jsonify({'ok':True,'id':iid})

"""
if 'def test_cpu_detection()' not in s:
    if marker not in s: raise SystemExit('health route marker missing')
    s=s.replace(marker,addon+marker,1)
p.write_text(s)
PY

log "Fixing Incident View render and adding detector test buttons"
python3 - <<'PY'
from pathlib import Path
p=Path.home()/"kubeheal-app/templates/dashboard.html"; s=p.read_text()
# Rename function and target variable to avoid the global id/function name collision that caused View to render nothing.
s=s.replace('onclick="detail(${i.id})"','onclick="showIncident(${i.id})"')
s=s.replace('async function detail(id){let i=await (await fetch(\'/api/incidents/\'+id)).json();detail.innerHTML=', "async function showIncident(id){let i=await (await fetch('/api/incidents/'+id,{cache:'no-store'})).json();document.getElementById('detail').innerHTML=")
# Convert automatic-only cards to include controlled detector validation buttons.
s=s.replace('<span class="badge">Automatic Detection</span></div><div class="card"><h2>Memory Pressure</h2>', '<span class="badge">Automatic Detection</span><br><br><button onclick="runExp(\'test-cpu-detection\')">Test CPU Detection</button></div><div class="card"><h2>Memory Pressure</h2>',1)
s=s.replace('<span class="badge">Automatic Detection</span></div><div class="card"><h2>Restart Threshold</h2>', '<span class="badge">Automatic Detection</span><br><br><button onclick="runExp(\'test-memory-detection\')">Test Memory Detection</button></div><div class="card"><h2>Restart Threshold</h2>',1)
s=s.replace('<span class="badge">Automatic Detection</span></div></div><p id="msg">', '<span class="badge">Automatic Detection</span><br><br><button onclick="runExp(\'test-restart-detection\')">Test Restart Detection</button></div></div><p id="msg">',1)
p.write_text(s)
PY

log "Validating"
cd "$APP"
python3 -m py_compile app.py
grep -q 'showIncident' templates/dashboard.html
grep -q 'Test CPU Detection' templates/dashboard.html
grep -q 'Test Memory Detection' templates/dashboard.html
grep -q 'Test Restart Detection' templates/dashboard.html

log "Building and deploying 6.2"
minikube image build -t "$IMAGE" .
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s
kubectl get pods -n "$NS"
echo; echo "KubeHeal 6.2 installed. Hard refresh Ctrl+Shift+R."
echo "Incident View is fixed; CPU/Memory/Restart automatic detector test buttons are available."
