import sys, os
src=os.path.expanduser("~/telephone-fixtures/chains/real-corpora-chain/input.phext")
data=open(src,'rb').read()
os.makedirs(os.path.expanduser("~/telephone-ksh/scratch"), exist_ok=True)
for n in [int(x) for x in sys.argv[1:]]:
    open(os.path.expanduser(f"~/telephone-ksh/scratch/trunc{n}.phext"),'wb').write(data[:n])
    print(n, "written")
