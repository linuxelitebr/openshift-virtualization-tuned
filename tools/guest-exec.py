#!/usr/bin/env python3
# Run a command inside a running KubeVirt VM via the qemu-guest-agent (no SSH).
#
#   guest-exec.py "<bash command>" <virt-launcher-pod> <libvirt-domain>
#
# The libvirt domain is usually  <namespace>_<vm-name>  (e.g. vm-tuning-lab_vm-hugepages-1gi).
# Requires the guest to have qemu-guest-agent installed and running, and your
# oc/kubectl context pointed at the cluster. Override the namespace with NS=...
import json, subprocess, base64, time, sys, os
NS=os.environ.get("NS","vm-tuning-lab")
if len(sys.argv)<4:
    sys.stderr.write('usage: guest-exec.py "<cmd>" <virt-launcher-pod> <libvirt-domain>\n'); sys.exit(2)
cmd=sys.argv[1]; POD=sys.argv[2]; DOM=sys.argv[3]
def vc(j):
    r=subprocess.run(["oc","exec",POD,"-n",NS,"-c","compute","--","virsh","qemu-agent-command",DOM,j],
                     capture_output=True,text=True)
    return r.stdout, r.stderr
ej=json.dumps({"execute":"guest-exec","arguments":{"path":"/bin/bash","arg":["-c",cmd],"capture-output":True}})
out,err=vc(ej)
try: pid=json.loads(out)["return"]["pid"]
except Exception: sys.stderr.write("EXEC FAIL: %s %s\n"%(out,err)); sys.exit(1)
for _ in range(900):
    out,err=vc(json.dumps({"execute":"guest-exec-status","arguments":{"pid":pid}}))
    try: st=json.loads(out)["return"]
    except Exception: sys.stderr.write("STATUS FAIL: %s\n"%out); sys.exit(1)
    if st.get("exited"):
        if st.get("out-data"): sys.stdout.write(base64.b64decode(st["out-data"]).decode(errors="replace"))
        if st.get("err-data"): sys.stderr.write(base64.b64decode(st["err-data"]).decode(errors="replace"))
        sys.exit(st.get("exitcode",0) or 0)
    time.sleep(1)
sys.stderr.write("TIMEOUT\n"); sys.exit(2)
