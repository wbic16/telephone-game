import subprocess, json
F="/home/hatch/workspace/bickford-llama-ranch/deploy/fleet-ssh.sh"
subprocess.run([F,"aletheia-core","cp","telephone-ksh/port/src/telephone.ksh","telephone-ksh/port/src/telephone-dbg.ksh"],check=True)
subprocess.run([F,"aletheia-core","sed","-i","s|2>/dev/null||g","telephone-ksh/port/src/telephone-dbg.ksh"],check=True)
req={"cmd":"attest","descriptor":{"turn":1,"coordinate":"1.1.1/1.1.1/1.1.1","scroll_sha256":"a"*64,"file_sha256":"b"*64}}
p=subprocess.run([F,"aletheia-core","env","LC_ALL=C","telephone-ksh/ksh93/ksh","telephone-ksh/port/src/telephone-dbg.ksh"],input=json.dumps(req).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
print("rc",p.returncode)
print("stdout",p.stdout.decode()[:400])
print("stderr",p.stderr.decode()[:2000])
