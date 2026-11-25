import os
d=os.path.expanduser("~/telephone-ksh/scratch")
data=open(os.path.expanduser("~/telephone-fixtures/chains/real-corpora-chain/input.phext"),'rb').read()
b=bytearray(data); b[5000000]^=0xFF; open(f"{d}/diffmid.phext",'wb').write(bytes(b))
b=bytearray(data); b[-1]^=0xFF; open(f"{d}/diffend.phext",'wb').write(bytes(b))
print("ok")
