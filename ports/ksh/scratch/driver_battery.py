#!/usr/bin/env python3
"""Driver-form serve battery for the ksh adapter (mirrors
harness/serve-conformance.md): init(state_path) -> echo -> elect ->
choose(state_path) -> apply(state_path, state_out_path) -> attest ->
validate(driver form: state_path + event_coord + index_line, cache
from init) -> verify(state_path), on scratch copies only."""
import base64, hashlib, json, subprocess, sys
from pathlib import Path
IMPL="ksh"
ADAPTER=Path.home()/"workspace/libphext-telephone/ports/ksh/adapter"
SMOKE=Path.home()/"workspace/libphext-telephone/games/smoke-001/stress.phext"
TMP=Path("/tmp/ksh-battery"); TMP.mkdir(exist_ok=True)
def sha256(b): return hashlib.sha256(b).hexdigest()
def canon(o): return json.dumps(o,sort_keys=True,separators=(",",":"),ensure_ascii=True)
class Serve:
    def __init__(s):
        s.p=subprocess.Popen([str(ADAPTER),"serve"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    def call(s,o):
        s.p.stdin.write(json.dumps(o)+"\n"); s.p.stdin.flush()
        line=s.p.stdout.readline(); assert line,"serve closed"
        return json.loads(line)
    def close(s):
        s.p.stdin.close(); s.p.wait(timeout=60)
fails=[]
def check(c,n):
    print(("ok - " if c else "FAIL - ")+n)
    if not c: fails.append(n)
prior_path=str(TMP/"prior.phext"); Path(prior_path).write_bytes(SMOKE.read_bytes())
sv=Serve()
try:
    r=sv.call({"cmd":"init","state_path":prior_path}); check(r=={"impl":IMPL,"verdict":"pass"},f"init driver-form {r}")
    ping={"game":"battery","round":1,"nonce":"cd"*32}
    e=sv.call({"cmd":"echo","ping":ping}); check(e["impl"]==IMPL and len(e["echo"])==64,"echo")
    el=sv.call({"cmd":"elect","position":"5.5.5/5.5.5/5.5.5","candidates":[IMPL,"go","reference"],"turn":3})
    check(el["elect"] in (IMPL,"go","reference"),f"elect {el}")
    step=sv.call({"cmd":"choose","state_path":prior_path,"position":"4.4.4/4.4.4/4.4.4","turn":1005})
    check(step.get("op")=="insert",f"choose driver-form {step}")
    out_path=str(TMP/"applied.phext")
    ap=sv.call({"cmd":"apply","state_path":prior_path,"step":step,"state_out_path":out_path})
    applied=Path(out_path).read_bytes()
    check(ap.get("state_sha256")==sha256(applied),"apply state_out_path + sha")
    att=sv.call({"cmd":"attest","descriptor":{"turn":1005,"coordinate":step["coordinate"],"scroll_sha256":sha256(step["text"].encode()),"file_sha256":sha256(applied)}})
    check("BEGIN PGP SIGNATURE" in base64.b64decode(att["signature"]).decode(),"attest driver-form")
    # driver inscription on a second serve leg via wire applies: build placed file
    def wapply(state,coord,text):
        st={"op":"insert","coordinate":coord,"text":text}
        r=sv.call({"cmd":"apply","state":base64.b64encode(state).decode(),"step":st})
        return base64.b64decode(r["state_b64"])
    body={"type":"placement","turn":1005,"actor":IMPL,"elect_by":IMPL,"coord":step["coordinate"],"text_sha256":sha256(step["text"].encode()),"file_sha256":sha256(applied),"att":att["signature"],"echoes":[],"consensus_prev":{}}
    placed=wapply(applied,"1.1.1/1.1.1/2.1.1006",canon({"prev":None,"body":body}))
    # index: append line to existing index scroll via reference-free method: fetch index text through wire apply? use python explode from scale-test
    sys.path.insert(0,str(Path.home()/"workspace/libphext-telephone"))
    import importlib.util
    spec=importlib.util.spec_from_file_location("st",str(Path.home()/"workspace/libphext-telephone/scale-test-live.py"))
    st=importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
    pm=st.explode(placed); idx=pm[(1,1,1,1,1,1,1,1,1)].decode()
    line=f"1005 {step['coordinate']} {sha256(step['text'].encode())} {IMPL}"
    pm[(1,1,1,1,1,1,1,1,1)]=(idx+line+"\n").encode()
    placed=st.implode(pm)
    placed_path=str(TMP/"placed.phext"); Path(placed_path).write_bytes(placed)
    sv.call({"cmd":"init","state_path":prior_path})
    v=sv.call({"cmd":"validate","state_path":placed_path,"step":step,"event_coord":"1.1.1/1.1.1/2.1.1006","index_line":line})
    check(v.get("verdict")=="pass",f"validate driver-form {v}")
    vf=sv.call({"cmd":"verify","state_path":prior_path,"pubkeys":pm and st.explode(SMOKE.read_bytes())[(1,1,1,1,1,1,1,1,2)].decode()})
    check(vf.get("verdict")=="pass" and vf.get("placements_checked")==30,f"verify driver-form {vf}")
finally:
    sv.close()
print("PASS" if not fails else f"FAILURES: {fails}")
sys.exit(0 if not fails else 1)
