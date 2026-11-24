-- wire.lua - pure-Lua wire helpers for the telephone CLI: SHA-256,
-- base64, JSON decode/encode, canonical JSON (Python json.dumps with
-- sort_keys=True, separators=(",",":"), ensure_ascii=True compatible).
-- Lua 5.1 compatible: no bitwise operators in the language, so 32-bit
-- ops are built from byte tables (XOR/AND) and exact double arithmetic
-- (all intermediates stay below 2^53).
local W = {}
local MOD = 4294967296

local XOR8, AND8 = {}, {}
for a=0,255 do
  XOR8[a]={}; AND8[a]={}
  for b=0,255 do
    local x,y,p,av,bv = 0,0,1,a,b
    for _=1,8 do
      local abit,bbit = av%2, bv%2
      if abit~=bbit then x=x+p end
      if abit==1 and bbit==1 then y=y+p end
      av=(av-abit)/2; bv=(bv-bbit)/2; p=p*2
    end
    XOR8[a][b]=x; AND8[a][b]=y
  end
end
local function b1(v) return math.floor(v/16777216)%256 end
local function b2(v) return math.floor(v/65536)%256 end
local function b3(v) return math.floor(v/256)%256 end
local function b4(v) return v%256 end
local function pack(w,x,y,z) return ((w*256+x)*256+y)*256+z end
local function bxor(a,b) return pack(XOR8[b1(a)][b1(b)],XOR8[b2(a)][b2(b)],XOR8[b3(a)][b3(b)],XOR8[b4(a)][b4(b)]) end
local function band(a,b) return pack(AND8[b1(a)][b1(b)],AND8[b2(a)][b2(b)],AND8[b3(a)][b3(b)],AND8[b4(a)][b4(b)]) end
local function bnot(a) return MOD-1-a end
local function rotr(a,n)
  local p = 2^n
  return math.floor(a/p) + (a%p) * (MOD/p)
end
local function shr(a,n) return math.floor(a/(2^n)) end
local function add(...)
  local s=0
  for _,v in ipairs({...}) do s=s+v end
  return s % MOD
end

-- ---------- SHA-256 ----------
local K = {
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}

function W.sha256(msg)
  local h = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
  local bitlen = #msg * 8
  local padded = msg .. "\128"
  while (#padded % 64) ~= 56 do padded = padded .. "\0" end
  -- 64-bit length: high word zero for our sizes
  padded = padded .. "\0\0\0\0"
  for i=3,0,-1 do padded = padded .. string.char(math.floor(bitlen/(2^(i*8)))%256) end
  local w = {}
  for chunk=1,#padded,64 do
    for i=0,15 do
      local o = chunk + i*4
      w[i+1] = pack(padded:byte(o),padded:byte(o+1),padded:byte(o+2),padded:byte(o+3))
    end
    for i=17,64 do
      local s0 = bxor(bxor(rotr(w[i-15],7), rotr(w[i-15],18)), shr(w[i-15],3))
      local s1 = bxor(bxor(rotr(w[i-2],17), rotr(w[i-2],19)), shr(w[i-2],10))
      w[i] = add(w[i-16], s0, w[i-7], s1)
    end
    local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
    for i=1,64 do
      local S1 = bxor(bxor(rotr(e,6), rotr(e,11)), rotr(e,25))
      local ch = bxor(band(e,f), band(bnot(e),g))
      local t1 = add(hh, S1, ch, K[i], w[i])
      local S0 = bxor(bxor(rotr(a,2), rotr(a,13)), rotr(a,22))
      local maj = bxor(bxor(band(a,b), band(a,c)), band(b,c))
      local t2 = add(S0, maj)
      hh=g; g=f; f=e; e=add(d,t1); d=c; c=b; b=a; a=add(t1,t2)
    end
    h[1]=add(h[1],a); h[2]=add(h[2],b); h[3]=add(h[3],c); h[4]=add(h[4],d)
    h[5]=add(h[5],e); h[6]=add(h[6],f); h[7]=add(h[7],g); h[8]=add(h[8],hh)
  end
  local out={}
  for i=1,8 do out[i]=string.format("%08x",h[i]) end
  return table.concat(out)
end

-- ---------- base64 ----------
local B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64R = {}
for i=1,64 do B64R[B64C:sub(i,i)]=i-1 end
function W.b64encode(data)
  local out={}
  for i=1,#data,3 do
    local a,b,c = data:byte(i), data:byte(i+1), data:byte(i+2)
    local n = a*65536 + (b or 0)*256 + (c or 0)
    out[#out+1]=B64C:sub(math.floor(n/262144)%64+1, math.floor(n/262144)%64+1)
    out[#out+1]=B64C:sub(math.floor(n/4096)%64+1, math.floor(n/4096)%64+1)
    out[#out+1]= b and B64C:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or "="
    out[#out+1]= c and B64C:sub(n%64+1, n%64+1) or "="
  end
  return table.concat(out)
end
function W.b64decode(data)
  data = data:gsub("[^%w%+/=]","")
  local out={}
  for i=1,#data,4 do
    local c1,c2,c3,c4 = data:sub(i,i),data:sub(i+1,i+1),data:sub(i+2,i+2),data:sub(i+3,i+3)
    local n = (B64R[c1] or 0)*262144 + (B64R[c2] or 0)*4096 + (B64R[c3] or 0)*64 + (B64R[c4] or 0)
    out[#out+1]=string.char(math.floor(n/65536)%256)
    if c3~="=" and c3~="" then out[#out+1]=string.char(math.floor(n/256)%256) end
    if c4~="=" and c4~="" then out[#out+1]=string.char(n%256) end
  end
  return table.concat(out)
end

-- ---------- JSON ----------
W.null = setmetatable({}, {__tostring=function() return "null" end})
local function utf8_encode(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0+math.floor(cp/64), 0x80+(cp%64))
  elseif cp < 0x10000 then return string.char(0xE0+math.floor(cp/4096), 0x80+(math.floor(cp/64)%64), 0x80+(cp%64))
  else return string.char(0xF0+math.floor(cp/262144), 0x80+(math.floor(cp/4096)%64), 0x80+(math.floor(cp/64)%64), 0x80+(cp%64)) end
end
W.utf8_encode = utf8_encode

function W.json_decode(str)
  local pos=1
  local function skip() while pos<=#str and str:sub(pos,pos):match("%s") do pos=pos+1 end end
  local parse
  local function parse_string()
    pos=pos+1
    local out={}
    while pos<=#str do
      local ch=str:sub(pos,pos)
      if ch=='"' then pos=pos+1; return table.concat(out)
      elseif ch=="\\" then
        local esc=str:sub(pos+1,pos+1)
        if esc=="u" then
          local cp=tonumber(str:sub(pos+2,pos+5),16); pos=pos+6
          if cp>=0xD800 and cp<=0xDBFF and str:sub(pos,pos+1)=="\\u" then
            local lo=tonumber(str:sub(pos+2,pos+5),16)
            if lo and lo>=0xDC00 and lo<=0xDFFF then
              cp=0x10000+(cp-0xD800)*1024+(lo-0xDC00); pos=pos+6
            end
          end
          out[#out+1]=utf8_encode(cp)
        else
          local map={n="\n",t="\t",r="\r",b="\b",f="\f",["/"]="/",["\\"]="\\",['"']='"'}
          out[#out+1]=map[esc] or esc; pos=pos+2
        end
      else out[#out+1]=ch; pos=pos+1 end
    end
    error("unterminated string")
  end
  function parse()
    skip()
    local ch=str:sub(pos,pos)
    if ch=="{" then
      pos=pos+1; local obj={_obj=true,_keys={}}
      skip()
      if str:sub(pos,pos)=="}" then pos=pos+1; return obj end
      while true do
        skip(); local k=parse_string(); skip()
        assert(str:sub(pos,pos)==":"); pos=pos+1
        obj[k]=parse(); obj._keys[#obj._keys+1]=k
        skip(); local c=str:sub(pos,pos); pos=pos+1
        if c=="}" then break end
      end
      return obj
    elseif ch=="[" then
      pos=pos+1; local arr={_arr=true}
      skip()
      if str:sub(pos,pos)=="]" then pos=pos+1; return arr end
      while true do
        arr[#arr+1]=parse()
        skip(); local c=str:sub(pos,pos); pos=pos+1
        if c=="]" then break end
      end
      return arr
    elseif ch=='"' then return parse_string()
    elseif str:sub(pos,pos+3)=="true" then pos=pos+4; return true
    elseif str:sub(pos,pos+4)=="false" then pos=pos+5; return false
    elseif str:sub(pos,pos+3)=="null" then pos=pos+4; return W.null
    else
      local s,e = str:find("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not s then error("bad JSON at "..pos) end
      local num = str:sub(s,e)
      pos=e+1
      return tonumber(num)
    end
  end
  return parse()
end

local function utf8_iter(s)
  local i=1
  return function()
    if i>#s then return nil end
    local b=s:byte(i)
    if b<0x80 then i=i+1; return b
    elseif b<0xE0 then local cp=(b%32)*64+(s:byte(i+1)%64); i=i+2; return cp
    elseif b<0xF0 then local cp=(b%16)*4096+(s:byte(i+1)%64)*64+(s:byte(i+2)%64); i=i+3; return cp
    else local cp=(b%8)*262144+(s:byte(i+1)%64)*4096+(s:byte(i+2)%64)*64+(s:byte(i+3)%64); i=i+4; return cp end
  end
end

local function canon_string(s)
  local out={'"'}
  for cp in utf8_iter(s) do
    if cp==0x22 then out[#out+1]='\\"'
    elseif cp==0x5C then out[#out+1]='\\\\'
    elseif cp==0x08 then out[#out+1]='\\b'
    elseif cp==0x0C then out[#out+1]='\\f'
    elseif cp==0x0A then out[#out+1]='\\n'
    elseif cp==0x0D then out[#out+1]='\\r'
    elseif cp==0x09 then out[#out+1]='\\t'
    elseif cp<0x20 or cp>0x7E then
      if cp>0xFFFF then
        local v=cp-0x10000
        out[#out+1]=string.format("\\u%04x\\u%04x", 0xD800+math.floor(v/1024), 0xDC00+(v%1024))
      else out[#out+1]=string.format("\\u%04x", cp) end
    else out[#out+1]=string.char(cp) end
  end
  out[#out+1]='"'
  return table.concat(out)
end
W.canon_string = canon_string

function W.canon(v)
  if v==W.null or v==nil then return "null" end
  local t=type(v)
  if t=="boolean" then return v and "true" or "false" end
  if t=="number" then
    if v==math.floor(v) then return string.format("%d", v) end
    return string.format("%.14g", v)
  end
  if t=="string" then return canon_string(v) end
  if t=="table" then
    if v._arr then
      local parts={}
      for i=1,#v do parts[i]=W.canon(v[i]) end
      return "["..table.concat(parts,",").."]"
    end
    local keys={}
    for k in pairs(v) do if k~="_obj" and k~="_keys" and k~="_arr" then keys[#keys+1]=k end end
    table.sort(keys)
    local parts={}
    for i,k in ipairs(keys) do parts[i]=canon_string(k)..":"..W.canon(v[k]) end
    return "{"..table.concat(parts,",").."}"
  end
  error("cannot canonicalize "..t)
end

function W.json_encode(v) return W.canon(v) end

return W
