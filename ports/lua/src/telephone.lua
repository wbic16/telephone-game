#!/usr/bin/env lua
-- telephone.lua - Exocortical Telephone Game CLI (contract v2) for the
-- Lua libphext port. Wire: one JSON request in, one response out;
-- arg "serve" loops over JSON lines. PGP via the language's own
-- subprocess gpg call (io.popen/os.execute), key home
-- $TELEPHONE_GNUPG_HOME or ~/telephone-lua/gnupg.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local Phext = require("phext")
local W = require("wire")

local IMPL = "lua"
local KEY_UID = "libphext telephone " .. IMPL
local INDEX_COORD = "1.1.1/1.1.1/1.1.1"
local KEYS_COORD = "1.1.1/1.1.1/1.1.2"
local KEYS_HASH_COORD = "1.1.1/1.1.1/1.1.3"
local RESERVED = {INDEX_COORD, KEYS_COORD, KEYS_HASH_COORD}

local function state_bytes(req)
  local s = req.state or req.state_b64 or ""
  return W.b64decode(s)
end
local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
local function obj(t) t._obj=true; t._keys={}; for k in pairs(t) do if type(k)=="string" then t._keys[#t._keys+1]=k end end; return t end
local function arr(t) t._arr=true; return t end

-- ---- gpg via subprocess (this language's own calls) ----
local function gnupg_home()
  return os.getenv("TELEPHONE_GNUPG_HOME") or (os.getenv("HOME") .. "/telephone-" .. IMPL .. "/gnupg")
end
local function shq(s) return "'" .. s:gsub("'","'\\''") .. "'" end
local function run(cmd)
  local tmp = os.tmpname()
  local rc = os.execute(cmd .. " > " .. shq(tmp) .. " 2>/tmp/telephone-lua-gpg.err")
  local f = io.open(tmp, "rb")
  local out = f and f:read("*a") or ""
  if f then f:close() end
  os.remove(tmp)
  if rc ~= 0 then
    local ef = io.open("/tmp/telephone-lua-gpg.err","r")
    local err = ef and ef:read("*a") or ""
    if ef then ef:close() end
    error("command failed (" .. tostring(rc) .. "): " .. err)
  end
  return out
end
local function gpg(args, input)
  local home = gnupg_home()
  os.execute("mkdir -p " .. shq(home) .. " && chmod 700 " .. shq(home))
  local cmd = "gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir " .. shq(home) .. " " .. args
  if input ~= nil then
    local tmp = os.tmpname()
    local f = assert(io.open(tmp,"wb")); f:write(input); f:close()
    local out = run(cmd .. " < " .. shq(tmp))
    os.remove(tmp)
    return out
  end
  return run(cmd)
end
local function keygen()
  local listing = gpg("--list-keys --with-colons")
  if not listing:match("\npub:") and not listing:match("^pub:") then
    gpg("--quick-gen-key " .. shq(KEY_UID) .. " ed25519 sign never")
  end
  return gpg("--armor --export " .. shq(KEY_UID))
end
local function detach_sign(data)
  local dir = os.tmpname() .. "d"
  os.execute("mkdir -p " .. shq(dir))
  local f = assert(io.open(dir.."/descriptor.json","wb")); f:write(data); f:close()
  gpg("--detach-sign --armor --local-user " .. shq(KEY_UID) ..
      " --output " .. shq(dir.."/descriptor.asc") .. " " .. shq(dir.."/descriptor.json"))
  local sf = assert(io.open(dir.."/descriptor.asc","rb"))
  local sig = sf:read("*a"); sf:close()
  os.execute("rm -rf " .. shq(dir))
  return sig
end
local function verify_signature(pubkeys, data, signature)
  local dir = os.tmpname() .. "d"
  os.execute("mkdir -p " .. shq(dir.."/gnupg") .. " && chmod 700 " .. shq(dir.."/gnupg"))
  local function wf(name, content)
    local f = assert(io.open(dir.."/"..name,"wb")); f:write(content); f:close()
  end
  wf("keys.asc", pubkeys); wf("descriptor.json", data); wf("descriptor.asc", signature)
  local rc1 = os.execute("gpg --batch --yes --homedir " .. shq(dir.."/gnupg") .. " --import " .. shq(dir.."/keys.asc") .. " >/dev/null 2>&1") == 0
  local rc2 = rc1 and (os.execute("gpg --batch --yes --homedir " .. shq(dir.."/gnupg") .. " --verify " .. shq(dir.."/descriptor.asc") .. " " .. shq(dir.."/descriptor.json") .. " >/dev/null 2>&1") == 0)
  os.execute("rm -rf " .. shq(dir))
  return rc2 and true or false
end

-- ---- game logic ----
local function echo_value(ping)
  local game = ping.game or ""
  local round = ping.round or ping.turn or ""
  local nonce = ping.nonce or ""
  return W.sha256(IMPL .. "|" .. tostring(game) .. "|" .. tostring(round) .. "|" .. tostring(nonce))
end
local function seed_bytes(s) -- raw sha256 bytes from hex
  local hex = W.sha256(s)
  local out = {}
  for i=1,#hex,2 do out[#out+1]=tonumber(hex:sub(i,i+1),16) end
  return out
end
local function elect_winner(position, candidates, turn)
  local hex = W.sha256(position .. string.char((turn or 0)%256) .. table.concat(candidates,","))
  local b0 = tonumber(hex:sub(1,2),16)
  return candidates[(b0 % #candidates)+1]
end
local function next_coord(c)
  local out={}; for i=1,9 do out[i]=c[i] end
  for d=9,1,-1 do
    if out[d]<999 then out[d]=out[d]+1; return out end
    out[d]=1
  end
  return out
end
local function choose_adventure(state, position, turn)
  local pos = Phext.parse_coordinate(position)
  if not pos then error("invalid position "..tostring(position)) end
  local used = Phext.explode(state)
  for _,r in ipairs(RESERVED) do used[r]="\0" end
  local sb = seed_bytes(position .. string.char((turn or 0)%256) .. state)
  local cand={}; for i=1,9 do cand[i]=pos[i] end
  local dim = (sb[2] % 9) + 1
  cand[dim] = ((cand[dim]-1 + 1 + (sb[3]%3)) % 999) + 1
  while used[Phext.format_coordinate(cand)] ~= nil do cand = next_coord(cand) end
  local cs = Phext.format_coordinate(cand)
  return obj{op="insert", coordinate=cs, text=IMPL.." turn "..tostring(turn).." at "..cs}
end
local function apply_step(state, step)
  local coord = Phext.parse_coordinate(step.coordinate or "")
  if not coord then return state, W.null end
  local text = step.text or ""
  local op = step.op or ""
  if op=="insert" then return Phext.insert(state,coord,text), W.null end
  if op=="replace" then return Phext.replace(state,coord,text), W.null end
  if op=="remove" then return Phext.remove(state,coord), W.null end
  if op=="fetch" then return state, W.sha256(Phext.fetch(state,coord)) end
  return state, W.null
end
local function validate_step(new_state, step, prior_state)
  if (step.op or "") ~= "insert" then return "fail","step op is not insert" end
  local coord = Phext.parse_coordinate(step.coordinate or "")
  if not coord then return "fail","unparseable coordinate" end
  if Phext.fetch(new_state,coord) ~= (step.text or "") then
    return "fail","placed scroll absent or content differs at "..(step.coordinate or "")
  end
  if prior_state ~= nil then
    if Phext.fetch(prior_state,coord) ~= "" then return "fail","coordinate was not unused in the prior state" end
    local before = Phext.explode(prior_state)
    local after = Phext.explode(new_state)
    local nb, na = 0,0
    for _ in pairs(before) do nb=nb+1 end
    for _ in pairs(after) do na=na+1 end
    if na ~= nb+1 then return "fail","scroll count did not grow by exactly one" end
    for c,t in pairs(before) do
      if after[c] ~= t then return "fail","a prior scroll was overwritten: "..c end
    end
    return "pass","placed at unused coordinate; all prior scrolls intact"
  end
  return "pass","placed scroll present with attested content (no prior state supplied)"
end

-- ---- serve-mode validator cache (init / driver-form validate) ----
local cache_map = nil
local function init_cache(state)
  cache_map = Phext.explode(state)
  return obj{impl=IMPL, verdict="pass"}
end
local function validate_driver(new_state, step, event_coord_s, index_line)
  local function fail(d) return obj{impl=IMPL, verdict="fail", detail=d} end
  if cache_map == nil then return fail("no prior state (init not called)") end
  local new_map = Phext.explode(new_state)
  local coord = Phext.parse_coordinate(step.coordinate or "")
  if not coord then return fail("unparseable coordinate") end
  local coord_s = Phext.format_coordinate(coord)
  if new_map[coord_s] ~= (step.text or "") then
    return fail("placed scroll missing or altered")
  end
  for c, text in pairs(cache_map) do
    if c ~= INDEX_COORD and new_map[c] ~= text then
      return fail("prior scroll overwritten at " .. c)
    end
  end
  for c in pairs(new_map) do
    if cache_map[c] == nil and c ~= coord_s and c ~= event_coord_s then
      return fail("unexpected new scroll at " .. c)
    end
  end
  local idx = new_map[INDEX_COORD] or ""
  local function rstrip_nl(s) return (s:gsub("\n+$", "")) end
  if rstrip_nl(idx):sub(-#rstrip_nl(index_line)) ~= rstrip_nl(index_line) then
    return fail("index does not record the placement")
  end
  cache_map = new_map
  return obj{impl=IMPL, verdict="pass"}
end

local function verify_game(state, pubkeys)
  local function fail(msg, checked)
    return obj{impl=IMPL, verdict="fail", placements_checked=checked,
               first_failure=obj{detail=msg}}
  end
  local scrolls = Phext.explode(state)
  local keys_text = scrolls[KEYS_COORD] or ""
  if keys_text=="" then return fail("no public-keys scroll at "..KEYS_COORD, 0) end
  if trim(pubkeys) ~= trim(keys_text) then return fail("supplied pubkeys do not match the inscribed keys scroll",0) end
  if scrolls[KEYS_HASH_COORD]==nil then return fail("no keys-hash scroll at "..KEYS_HASH_COORD,0) end
  local kh = trim(scrolls[KEYS_HASH_COORD])
  if kh ~= W.sha256(keys_text) then return fail("keys-hash scroll does not match the keys scroll",0) end
  local index = {}
  for line in ((scrolls[INDEX_COORD] or "").."\n"):gmatch("([^\n]*)\n") do
    local l = trim(line)
    if l~="" and l:sub(1,1)~="#" then
      local flds = {}
      for f in l:gmatch("%S+") do flds[#flds+1]=f end
      if #flds~=4 then return fail("malformed index line: "..l,0) end
      index[flds[2]] = {turn=flds[1], hash=flds[3], actor=flds[4]}
    end
  end
  local checked=0; local seen={}; local prev_hash=nil
  local seq=1
  while true do
    local ecoord = Phext.format_coordinate({1,1,1,1,1,1,2,1,seq})
    if scrolls[ecoord]==nil then break end
    local ok, ev = pcall(W.json_decode, scrolls[ecoord])
    if not ok or type(ev)~="table" or type(ev.body)~="table" then
      return fail("event "..seq.." is not a JSON object", checked)
    end
    local body = ev.body
    if seq==1 then
      if ev.prev ~= nil and ev.prev ~= W.null then return fail("event 1 prev is not null", checked) end
    else
      if ev.prev ~= prev_hash then return fail("event chain broken at seq "..seq, checked) end
    end
    prev_hash = W.sha256(W.canon(body))
    if body.type=="placement" then
      local coord_str = body.coord or ""
      local text_hash = body.text_sha256 or ""
      local file_hash = body.file_sha256 or ""
      local att_b64 = body.att or ""
      if coord_str=="" or text_hash=="" or file_hash=="" or att_b64=="" then
        return fail("event "..seq.." lacks coord/text_sha256/file_sha256/att", checked)
      end
      if seen[coord_str] then return fail("coordinate reused at "..coord_str, checked) end
      if scrolls[coord_str]==nil then return fail("placement missing at "..coord_str, checked) end
      if W.sha256(scrolls[coord_str]) ~= text_hash then return fail("placement hash mismatch at "..coord_str, checked) end
      local ie = index[coord_str]
      if not ie or ie.hash~=text_hash or ie.turn~=tostring(body.turn) or ie.actor~=(body.actor or "") then
        return fail("index mismatch at "..coord_str, checked)
      end
      local desc = obj{turn=body.turn, coordinate=coord_str, scroll_sha256=text_hash, file_sha256=file_hash}
      local canon = W.canon(desc)
      local signature = W.b64decode(att_b64)
      if not verify_signature(pubkeys, canon, signature) then
        return fail("event "..seq.." signature invalid", checked)
      end
      seen[coord_str]=true; checked=checked+1
    end
    seq=seq+1
  end
  if checked==0 then return fail("no placement events found",0) end
  for cs in pairs(index) do
    if not seen[cs] then return fail("index lists a placement with no event: "..cs, checked) end
  end
  return obj{impl=IMPL, verdict="pass", placements_checked=checked, first_failure=W.null}
end

local function handle(req)
  local cmd = req.cmd or ""
  if cmd=="id" then return obj{impl=IMPL} end
  if cmd=="echo" then return obj{impl=IMPL, echo=echo_value(req.ping or obj{})} end
  if cmd=="elect" then
    local cands = req.candidates or arr{}
    if #cands==0 then error("elect: no candidates") end
    return obj{elect=elect_winner(req.position or "", cands, req.turn or 0)}
  end
  if cmd=="choose" then return choose_adventure(state_bytes(req), req.position, req.turn) end
  if cmd=="apply" then
    local ns, fh = apply_step(state_bytes(req), req.step)
    return obj{state_b64=W.b64encode(ns), state_sha256=W.sha256(ns), fetch_sha256=fh}
  end
  if cmd=="keygen" then return obj{impl=IMPL, pubkey=keygen()} end
  if cmd=="attest" then return obj{signature=detach_sign(W.canon(req.descriptor))} end
  if cmd=="init" then return init_cache(state_bytes(req)) end
  if cmd=="validate" then
    if req.event_coord ~= nil and req.event_coord ~= W.null then
      return validate_driver(state_bytes(req), req.step, req.event_coord, req.index_line or "")
    end
    local prior = nil
    if req.prior_state ~= nil and req.prior_state ~= W.null then prior = W.b64decode(req.prior_state) end
    local verdict, detail = validate_step(state_bytes(req), req.step, prior)
    return obj{impl=IMPL, verdict=verdict, detail=detail}
  end
  if cmd=="verify" then return verify_game(state_bytes(req), req.pubkeys or "") end
  error("unknown cmd "..cmd)
end

-- Game-scale framing (2026-11-24): lines over 8 KB may arrive gzip-framed as
-- "GZ1:" + base64(gzip(line)) — the fleet-ssh channel is ~25-70 KB/s
-- and raw base64 state lines took minutes at 1,000 placements. Lua
-- has no zlib, so (de)compression shells to the system gzip(1) on
-- temp files. Lossless; plain lines unchanged.
local function gz_unframe(s)
  local raw = W.b64decode(s:sub(5))
  local fin, fout = os.tmpname(), os.tmpname()
  local f = io.open(fin, "wb"); f:write(raw); f:close()
  os.execute("gzip -dc " .. fin .. " > " .. fout)
  local g = io.open(fout, "rb"); local out = g:read("*a"); g:close()
  os.remove(fin); os.remove(fout)
  return out
end
local function gz_frame(s)
  local fin, fout = os.tmpname(), os.tmpname()
  local f = io.open(fin, "wb"); f:write(s); f:close()
  os.execute("gzip -c " .. fin .. " > " .. fout)
  local g = io.open(fout, "rb"); local gz = g:read("*a"); g:close()
  os.remove(fin); os.remove(fout)
  return "GZ1:" .. W.b64encode(gz)
end

io.stdout:setvbuf("line")
if arg[1]=="serve" then
  for line in io.stdin:lines() do
    if line:match("%S") then
      if line:sub(1, 4) == "GZ1:" then line = gz_unframe(line) end
      local ok, out = pcall(function() return handle(W.json_decode(line)) end)
      if not ok then out = obj{error=tostring(out)} end
      local outj = W.json_encode(out)
      if #outj > 8192 then outj = gz_frame(outj) end
      io.stdout:write(outj, "\n")
    end
  end
else
  local raw = io.stdin:read("*a") or ""
  local req = W.json_decode(raw)
  local out = handle(req)
  io.stdout:write(W.json_encode(out), "\n")
end
