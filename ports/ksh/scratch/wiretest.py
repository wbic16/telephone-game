import subprocess, json, sys
def wire(req):
    p=subprocess.run(["/home/hatch/workspace/bickford-llama-ranch/deploy/fleet-ssh.sh","aletheia-core","telephone-ksh/telephone"], input=json.dumps(req).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print("rc", p.returncode, "stderr", p.stderr.decode()[:500])
    lines=[l for l in p.stdout.decode().splitlines() if l.strip()]
    print(lines[-1] if lines else "NO OUTPUT")
wire({"cmd":"id"})
wire({"cmd":"echo","ping":{"game":"t","round":1,"nonce":"ab"*32}})
wire({"cmd":"elect","position":"5.5.5/5.5.5/5.5.5","candidates":["ksh","go","php"],"turn":3})
