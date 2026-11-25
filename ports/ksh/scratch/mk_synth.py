import os
d=os.path.expanduser("~/telephone-ksh/scratch"); os.makedirs(d,exist_ok=True)
for n in [250000,500000,1000000,1500000,1700840,2000000,3000000]:
    open(f"{d}/one{n}.phext",'wb').write(b"A"*n)
    # many small scrolls: 100-byte scrolls separated by 0x17
    open(f"{d}/many{n}.phext",'wb').write(b"\x17".join(b"B"*100 for _ in range(n//101)))
print("done")
