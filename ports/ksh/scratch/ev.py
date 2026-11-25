import sys
sys.path.insert(0,"/home/hatch/workspace/libphext-telephone/harness")
from adapter_base import Adapter
data=open("/home/hatch/workspace/libphext-telephone/games/smoke-001/stress.phext","rb").read()
class A(Adapter):
    def explode(self,data):
        # use reference impl from harness reference_adapter? simpler: import telephone reference explode via scale-test code
        return None
# reuse explode from scale-test-live.py
import importlib.util
spec=importlib.util.spec_from_file_location("st","/home/hatch/workspace/libphext-telephone/scale-test-live.py")
# that module runs main only under __main__, safe
st=importlib.util.module_from_spec(spec); spec.loader.exec_module(st)
m=st.explode(data)
evs=sorted([c for c in m if c[:8]==(1,1,1,1,1,1,2,1)])
for c in evs[:4]:
    open(f"/tmp/ev{c[8]}.json","wb").write(m[c])
    print(c, len(m[c]))
