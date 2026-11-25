import collections, os
p=os.path.expanduser("~/telephone-fixtures/chains/real-corpora-chain/input.phext")
data=open(p,'rb').read()
print("size",len(data))
c=collections.Counter(data)
for b in [0x01,0x1f,0x1e,0x1d,0x1c,0x1a,0x19,0x18,0x17,0x02,0x03,0x0a]:
    print(hex(b), c[b])
print("breaks total", sum(c[b] for b in [0x01,0x1f,0x1e,0x1d,0x1c,0x1a,0x19,0x18,0x17]))
print("sentinel parts est", sum(c[b] for b in [0x01,0x1f,0x1e,0x1d,0x1c,0x1a,0x19,0x18,0x17])+c[0x02]+1)
# scroll count approx breaks+1 runs
# also check other fixtures sizes
import glob
for f in sorted(glob.glob(os.path.expanduser("~/telephone-fixtures/**/input.phext"), recursive=True)):
    print(os.path.getsize(f), f)
