#!/usr/bin/env python3
"""Old-vs-new validate differential, run ON the hub.
Old: ~/telephone-cfml/oldsrc/cli.cfm (pre-perf phext.cfm) via one-shot box.
New: ~/telephone-cfml/run-cli.sh (warm daemon path).
Cases on the test-001 snapshot copy in cache/: pass + 4 fail modes."""
import base64, json, os, subprocess, sys, time
HOME = os.path.expanduser("~")
D = os.path.join(HOME, "telephone-cfml")
BREAKS = b"\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"
BDIM = {b: d for d, b in enumerate(BREAKS)}
INDEX = (1,1,1,1,1,1,1,1,1)
def explode(data):
    out={}; coord=[1]*9; run=bytearray()
    for byte in data:
        d=BDIM.get(byte)
        if d is None: run.append(byte)
        else:
            if run: out[tuple(coord)]=bytes(run); run=bytearray()
            coord[d]+=1
            for k in range(d+1,9): coord[k]=1
    if run: out[tuple(coord)]=bytes(run)
    return out
def implode(mapping):
    out=[]; loc=[1]*9
    for coord in sorted(mapping):
        text=mapping[coord]
        if not text: continue
        if tuple(loc) < coord:
            dim=0
            while loc[dim]==coord[dim]: dim+=1
            out.append(bytes([BREAKS[dim]])*(coord[dim]-loc[dim]))
            loc=loc[:dim]+[coord[dim]]+[1]*(8-dim)
            for lower in range(dim+1,9):
                out.append(bytes([BREAKS[lower]])*(coord[lower]-1)); loc[lower]=coord[lower]
        out.append(text)
    return b"".join(out)
def b64(b): return base64.b64encode(b).decode()
prior = base64.b64decode(open(os.path.join(D,"cache/prof-snap.b64")).read())
placed = base64.b64decode(open(os.path.join(D,"cache/prof-placed.b64")).read())
meta = {"step":{"op":"insert","coordinate":"4.4.4/4.4.4/4.4.4","text":"cfml was here, turn 1006"},
        "event_coord":"1.1.1/1.1.1/2.1.1007",
        "index_line":"1006 4.4.4/4.4.4/4.4.4 bd8c349fbd401c5c27c14980d7e8258b2c9f57ab93e2f38a3cb5088084e34609 cfml"}
pm = explode(placed)
cases = {}
cases["pass"] = (placed, meta)
m2 = dict(pm); m2[(4,4,4,4,4,4,4,4,4)] = b"tampered text"
cases["placed-tampered"] = (implode(m2), meta)
# prior overwritten: pick a non-index, non-event prior scroll
victim = [c for c in explode(prior) if c != INDEX and c[:8] != (1,1,1,1,1,1,2,1)][0]
m3 = dict(pm); m3[victim] = m3[victim] + b"X"
cases["prior-overwritten"] = (implode(m3), meta)
m4 = dict(pm); m4[(9,9,9,9,9,9,9,9,9)] = b"surprise"
cases["unexpected-scroll"] = (implode(m4), meta)
meta5 = dict(meta); meta5["index_line"] = meta["index_line"].replace("1006", "9999", 1)
cases["index-mismatch"] = (placed, meta5)

def run_old(req):
    rf = os.path.join(D, "cache/diff-req.json"); sf = os.path.join(D, "cache/diff-resp.json")
    open(rf, "w").write(json.dumps(req))
    if os.path.exists(sf): os.remove(sf)
    env = dict(os.environ, TELCFML_REQ=rf, TELCFML_RESP=sf)
    subprocess.run([os.path.join(D,"boxzip/box"), os.path.join(D,"oldsrc/cli.cfm")],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    return json.loads(open(sf).read())
def run_new(req):
    p = subprocess.run([os.path.join(D,"run-cli.sh")], input=json.dumps(req).encode(),
                       stdout=subprocess.PIPE, timeout=600)
    lines=[ln for ln in p.stdout.decode().splitlines() if ln.strip()]
    last=lines[-1]
    if last.startswith("GZ1:"):
        import gzip as gz; last=gz.decompress(base64.b64decode(last[4:])).decode()
    return json.loads(last)

ok = True
for name,(state,mm) in cases.items():
    t0=time.time(); ro = run_old({"cmd":"init","state":b64(prior)}); 
    vo = run_old({"cmd":"validate","state":b64(state),"step":mm["step"],"event_coord":mm["event_coord"],"index_line":mm["index_line"]}); t_old=time.time()-t0
    t0=time.time(); rn = run_new({"cmd":"init","state":b64(prior)})
    vn = run_new({"cmd":"validate","state":b64(state),"step":mm["step"],"event_coord":mm["event_coord"],"index_line":mm["index_line"]}); t_new=time.time()-t0
    same = vo == vn
    ok = ok and same
    print("%-18s old=%s (%.1fs) new=%s (%.1fs) identical=%s" % (name, vo, t_old, vn, t_new, same))
print("DIFFERENTIAL:", "PASS" if ok else "FAIL")
