#!/usr/bin/env lua
-- Test suite for the Lua libphext port. Run: lua tests/test_phext.lua
-- Fixtures via PHEXT_FIXTURES env (shared harness set).
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path
local P = require("phext")
local failures = 0
local function check(cond, name)
  if cond then print("ok - "..name) else failures=failures+1; print("FAIL - "..name) end
end
local function coord(s) local c=P.parse_coordinate(s); assert(c, "bad coord "..s); return c end

check(P.format_coordinate(coord("1.2.3/4.5.6/7.8.9"))=="1.2.3/4.5.6/7.8.9", "coordinate round trip")
check(P.parse_coordinate("0.1.1/1.1.1/1.1.1")==nil, "coordinate rejects 0")
check(P.parse_coordinate("1.1.1/1.1.1")==nil, "coordinate rejects short")
check(P.compare(coord("1.1.1/1.1.1/1.1.9"), coord("1.1.1/1.1.2/1.1.1"))==-1, "order: section beats scroll")
check(P.compare(coord("2.1.1/1.1.1/1.1.1"), coord("10.1.1/1.1.1/1.1.1"))==-1, "order: numeric not string")

local buf = "a\23b\24c\1d"
local scrolls = P.phokenize(buf)
local got = {}
for i,ps in ipairs(scrolls) do got[i]=P.format_coordinate(ps.coord)..":"..ps.text end
check(table.concat(got,",")=="1.1.1/1.1.1/1.1.1:a,1.1.1/1.1.1/1.1.2:b,1.1.1/1.1.1/1.2.1:c,2.1.1/1.1.1/1.1.1:d", "phokenize breaks")
check(P.dephokenize(scrolls)==buf, "dephokenize round trip")
local s = P.phokenize("line1\nline2")
check(#s==1 and s[1].text=="line1\nline2", "newline is text")
check(P.fetch("hello", coord("1.1.1/1.1.1/1.1.2"))=="", "gap fetch is empty")
check(P.fetch("hello", coord("9.9.9/9.9.9/9.9.9"))=="", "far gap fetch is empty")
check(P.fetch("hello", coord("1.1.1/1.1.1/1.1.1"))=="hello", "fetch hit")
buf = P.insert("base", coord("1.1.1/1.1.1/1.1.1"), "+more")
check(P.fetch(buf, coord("1.1.1/1.1.1/1.1.1"))=="base+more", "insert merges existing+inserted")
buf = P.insert(buf, coord("1.1.1/1.1.1/1.1.3"), "third")
check(buf=="base+more\23\23third", "insert creates in canonical position")
buf = P.replace("a\23b\23c", coord("1.1.1/1.1.1/1.1.2"), "B")
check(buf=="a\23B\23c", "replace overwrites")
buf = P.remove(buf, coord("1.1.1/1.1.1/1.1.2"))
check(buf=="a\23\23c", "remove coordinate-preserving: c stays at scroll 3")
check(P.fetch(buf, coord("1.1.1/1.1.1/1.1.2"))=="", "fetch after remove is empty")
check(P.fetch(buf, coord("1.1.1/1.1.1/1.1.3"))=="c", "later scroll did NOT shift after remove")
check(P.remove(buf, coord("5.5.5/5.5.5/5.5.5"))==buf, "remove gap is no-op")
local m = P.explode("x\23y\1z")
local n=0; for _ in pairs(m) do n=n+1 end
check(n==3 and P.implode(m)=="x\23y\1z", "explode/implode round trip")

-- DynamicPhext + TransitivePhext equivalence with the string path
local function seq_test(make, name)
  local store = make("a\23b")
  local ref = "a\23b"
  local ops = {
    {"insert","1.1.1/1.1.1/1.1.1","+X"}, {"insert","1.1.1/1.1.1/1.1.3","third"},
    {"replace","1.1.1/1.1.1/1.1.2","B"}, {"remove","1.1.1/1.1.1/1.1.1",nil},
    {"insert","2.1.1/1.1.1/1.1.1","lib2"}, {"remove","1.1.1/1.1.1/1.1.3",nil},
    {"replace","9.9.9/9.9.9/9.9.9","far"}, {"insert","1.1.1/1.1.1/1.1.2","-tail"},
  }
  for _,op in ipairs(ops) do
    local c = coord(op[2])
    if op[1]=="insert" then store:insert(c,op[3]); ref=P.insert(ref,c,op[3])
    elseif op[1]=="replace" then store:replace(c,op[3]); ref=P.replace(ref,c,op[3])
    else store:remove(c); ref=P.remove(ref,c) end
    check(store:serialize()==P.normalize(ref), name.." serialize matches string path after "..op[1].." "..op[2])
    check(store:fetch(c)==P.fetch(P.normalize(ref),c), name.." fetch matches after "..op[1].." "..op[2])
  end
end
seq_test(function(b) return P.DynamicPhext.new(b) end, "DynamicPhext")
seq_test(function(b) return P.TransitivePhext.new(b) end, "TransitivePhext")
-- Dynamic capacity discipline: grows by doubling, shrinks at quarter
local d = P.DynamicPhext.new()
for i=1,20 do d:append(coord("1.1.1/1.1.1/1.1."..i), "s"..i) end
check(d:len()==20 and d:capacity()>=20 and d:capacity()<40, "DynamicPhext capacity doubling (cap="..d:capacity()..")")
for i=20,6,-1 do d:remove(coord("1.1.1/1.1.1/1.1."..i)) end
check(d:len()==5, "DynamicPhext removals")
check(P.TransitivePhext.new():depth()==9, "TransitivePhext depth 9")

-- Fixtures
local dir = os.getenv("PHEXT_FIXTURES")
if dir then
  local count, identical = 0, 0
  local f = io.popen("find " .. dir .. " -name input.phext | sort")
  for path in f:lines() do
    local fh = assert(io.open(path,"rb")); local data = fh:read("*a") or ""; fh:close()
    count = count + 1
    if P.dephokenize(P.phokenize(data))==data then identical=identical+1 end
    local n1 = P.normalize(data)
    check(P.normalize(n1)==n1, "fixture normalize idempotent: "..path)
  end
  f:close()
  check(count>0, "fixtures found ("..count..")")
  check(identical>=count-2, "fixtures byte-identical round-trips ("..identical.."/"..count..")")
else
  print("skip - fixtures (PHEXT_FIXTURES not set)")
end

print(failures==0 and "PASS" or ("FAILURES: "..failures))
os.exit(failures==0 and 0 or 1)
