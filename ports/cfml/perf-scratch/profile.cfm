<cfscript>
include "/home/wbic16/telephone-cfml/port/src/phext.cfm";
function bufOfB64(required string b64) { return bufFromBinary(binaryDecode(arguments.b64, "base64")); }
t0 = getTickCount();
function ms(required numeric a, required numeric b) { return b - a; }
out = [];
// phase: read+b64 decode prior (as validate does from cache) and placed via files
tA = getTickCount();
priorB64 = fileRead("/home/wbic16/telephone-cfml/cache/prof-snap.b64", "utf-8");
placedB64 = fileRead("/home/wbic16/telephone-cfml/cache/prof-placed.b64", "utf-8");
tB = getTickCount();
prior = bufOfB64(priorB64);
tC = getTickCount();
data = bufOfB64(placedB64);
tD = getTickCount();
old = phextExplode(prior);
tE = getTickCount();
newMap = phextExplode(data);
tF = getTickCount();
// comparisons like doValidate
cs = "4.4.4/4.4.4/4.4.4";
chk1 = newMap[cs];
cnt=0;
for (var c in old) { if (c == "1.1.1/1.1.1/1.1.1") continue; if (newMap[c] != old[c]) { } cnt++; }
tG = getTickCount();
for (var c in newMap) { if (!structKeyExists(old, c)) { } }
tH = getTickCount();
// json parse phase: read validate request file
reqText = fileRead("/home/wbic16/telephone-cfml/cache/prof-req.json", "utf-8");
tI = getTickCount();
req = deserializeJSON(reqText);
tJ = getTickCount();
data2 = bufOfB64(req.state);
tK = getTickCount();
res = "boot+include_to_first_code_ms=" & (tA-t0) & " read_b64_files=" & (tB-tA) & " b64decode_prior=" & (tC-tB) & " b64decode_placed=" & (tD-tC) & " explode_prior=" & (tE-tD) & " explode_placed=" & (tF-tE) & " compare_old_loop=" & (tG-tF) & " scan_new_loop=" & (tH-tG) & " read_req=" & (tI-tH) & " json_parse_req=" & (tJ-tI) & " b64decode_req_state=" & (tK-tJ) & " total=" & (tK-t0) & " priorLen=" & len(prior) & " scrollsOld=" & structCount(old) & " scrollsNew=" & structCount(newMap);
fileWrite("/home/wbic16/telephone-cfml/cache/prof-out.txt", res, "utf-8");
</cfscript>
