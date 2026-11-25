import os
d=os.path.expanduser("~/telephone-ksh/scratch")
for n in [2200000,2500000,2800000]:
    open(f"{d}/one{n}.phext",'wb').write(b"A"*n)
print("ok")
