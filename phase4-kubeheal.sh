#!/usr/bin/env bash
set -Eeuo pipefail
APP="$HOME/kubeheal-app"
NS="kubeheal-system"
DEMO="kubeheal-demo"
IMAGE="kubeheal:4.0"
log(){ printf '\n[KubeHeal Phase 4] %s\n' "$1"; }
[[ -f "$APP/app.py" ]] || { echo "Run Phase 3 first."; exit 1; }

log "Adding multi-issue backend"
# Append Phase 4 routes before building. They use bounded, demo-namespace-only experiments.
cat >> "$APP/app.py" <<'PY'

# ---------------- Phase 4 extensions ----------------
def pod_cpu_cores(appname):
    q=('sum(rate(container_cpu_usage_seconds_total{namespace="%s",pod=~"%s-.*",container!="",container!="POD"}[1m]))' % (NS, appname))
    return prom(q) or 0.0

def pod_memory_bytes(appname):
    q=('sum(container_memory_working_set_bytes{namespace="%s",pod=~"%s-.*",container!="",container!="POD"})' % (NS, appname))
    return prom(q) or 0.0

@app.get("/api/application-metrics/<name>")
def application_metrics(name):
    return jsonify({"application":name,"cpu_cores":round(pod_cpu_cores(name),4),"memory_mib":round(pod_memory_bytes(name)/1024/1024,1)})

@app.post("/api/experiments/not-ready")
def not_ready():
    # Safe demo: scale backend to zero briefly, then restore desired replicas.
    name=(request.json or {}).get("application","backend")
    d=apps.read_namespaced_deployment(name,NS); original=d.spec.replicas or 1
    inc=create_incident(name,"Replica Unavailable","Medium","Restore desired replicas")
    apps.patch_namespaced_deployment_scale(name,NS,{"spec":{"replicas":0}})
    def restore():
        time.sleep(6)
        apps.patch_namespaced_deployment_scale(name,NS,{"spec":{"replicas":original}})
        monitor_recovery(inc,name,time.time())
    threading.Thread(target=restore,daemon=True).start()
    return jsonify({"ok":True,"incident":inc})

@app.post("/api/experiments/restart")
def restart_demo():
    # Controlled rollout restart, scoped to demo namespace.
    name=(request.json or {}).get("application","backend")
    inc=create_incident(name,"Container Restart Test","Medium","Rolling restart deployment")
    stamp=str(int(time.time()))
    apps.patch_namespaced_deployment(name,NS,{"spec":{"template":{"metadata":{"annotations":{"kubeheal/restartedAt":stamp}}}}})
    threading.Thread(target=monitor_recovery,args=(inc,name,time.time()),daemon=True).start()
    return jsonify({"ok":True,"incident":inc})

@app.post("/api/experiments/cpu")
def cpu_demo():
    # Bounded CPU experiment: temporarily lower the backend CPU limit to demonstrate a CPU policy event,
    # then restore it. Does not intentionally exhaust the EC2 host.
    name=(request.json or {}).get("application","backend")
    inc=create_incident(name,"CPU Policy Test","High","Restore CPU resource policy")
    d=apps.read_namespaced_deployment(name,NS)
    container=d.spec.template.spec.containers[0]
    old_limits=dict(container.resources.limits or {})
    body={"spec":{"template":{"spec":{"containers":[{"name":container.name,"resources":{"limits":{"cpu":"50m","memory":old_limits.get("memory","128Mi")},"requests":{"cpu":"20m","memory":"32Mi"}}}]}}}}
    apps.patch_namespaced_deployment(name,NS,body)
    def restore_cpu():
        time.sleep(8)
        restore={"spec":{"template":{"spec":{"containers":[{"name":container.name,"resources":{"limits":{"cpu":old_limits.get("cpu","200m"),"memory":old_limits.get("memory","128Mi")},"requests":{"cpu":"20m","memory":"32Mi"}}}]}}}}
        apps.patch_namespaced_deployment(name,NS,restore)
        monitor_recovery(inc,name,time.time())
    threading.Thread(target=restore_cpu,daemon=True).start()
    return jsonify({"ok":True,"incident":inc})
PY

log "Injecting Phase 4 experiment controls into UI"
python3 - <<'PY'
from pathlib import Path
p=Path.home()/"kubeheal-app/templates/dashboard.html"
s=p.read_text()
s=s.replace('<button disabled>Coming Next</button></div><div class="exp"><h2>Memory Stress</h2>', '<button onclick="experiment(\'cpu\')">Trigger CPU Policy Test</button></div><div class="exp"><h2>Pod Not Ready</h2>')
s=s.replace('<p class="muted">Planned for Phase 4 with bounded demo-only memory pressure.</p><button disabled>Coming Next</button>', '<p class="muted">Temporarily remove backend replicas, then restore them automatically.</p><button onclick="experiment(\'not-ready\')">Trigger Not Ready</button>')
s=s.replace('</div></div><p id="msg"></p></section>', '</div><div class="exp"><h2>Restart Test</h2><p class="muted">Perform a controlled backend rolling restart and verify recovery.</p><button onclick="experiment(\'restart\')">Trigger Restart</button></div></div><p id="msg"></p></section>',1)
s=s.replace("async function loadSettings()", "async function experiment(kind){msg.textContent='Creating '+kind+' event...';let r=await fetch('/api/experiments/'+kind,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({application:'backend'})});let d=await r.json();msg.textContent=d.ok?'Incident created; automatic recovery in progress...':(d.message||'Failed');refresh()}\nasync function loadSettings()")
p.write_text(s)
PY

log "Building image $IMAGE"
cd "$APP"
minikube image build -t "$IMAGE" .

log "Updating KubeHeal deployment"
kubectl -n "$NS" set image deployment/kubeheal kubeheal="$IMAGE"
kubectl rollout status deployment/kubeheal -n "$NS" --timeout=180s

log "Phase 4 deployed"
kubectl get pods -n "$NS"
echo
echo "Refresh KubeHeal. Experiments now include:"
echo "  - Pod Crash"
echo "  - CPU Policy Test (bounded)"
echo "  - Pod Not Ready / replica outage and automatic restore"
echo "  - Controlled Restart Test"
echo
echo "Existing access command:"
echo "kubectl port-forward --address=0.0.0.0 svc/kubeheal 8080:8080 -n $NS"
