import os, sys
BREAKS=b"\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17"; BDIM={b:d for d,b in enumerate(BREAKS)}
def explode(data):
    out={}; coord=[1]*9; run=bytearray()
    for byte in data:
        d=BDIM.get(byte)
        if d is None: run.append(byte)
        else:
            if run: out[tuple(coord)]=bytes(run); run=bytearray()
            coord[d]+=1
            for l in range(d+1,9): coord[l]=1
    if run: out[tuple(coord)]=bytes(run)
    return out
for n in [2000000,4000000,6000000,9405538]:
    data=open(os.path.expanduser(f"~/telephone-ksh/scratch/trunc{n}.phext"),'rb').read()
    m=explode(data)
    big=sorted(m.items(), key=lambda kv:-len(kv[1]))[:3]
    print(n, "scrolls", len(m), "maxcoord", max(m), "biggest", [(k,len(v)) for k,v in big])
