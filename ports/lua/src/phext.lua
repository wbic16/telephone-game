-- phext.lua - libphext port for Lua (0.6.1 parity semantics; normative
-- reference: libphext-py). Phext is a 9-dimensional plain-text format:
-- scrolls addressed by a coordinate, separated by dimension-break bytes.
-- Breaks (dim -> byte): 0 library 0x01, 1 shelf 0x1F, 2 series 0x1E,
-- 3 collection 0x1D, 4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19,
-- 7 section 0x18, 8 scroll 0x17. Newline is ordinary text.
-- Coordinates are tables of 9 integers >= 1. All ops on byte strings.
local M = { _VERSION = "0.6.1" }

local BREAKS = {0x01,0x1F,0x1E,0x1D,0x1C,0x1A,0x19,0x18,0x17}
local BREAK_DIM = {}
for d,b in ipairs(BREAKS) do BREAK_DIM[b]=d-1 end
local BREAK_SET = {}
for _,b in ipairs(BREAKS) do BREAK_SET[string.char(b)]=true end

function M.parse_coordinate(s)
  if type(s)~="string" then return nil end
  s = s:match("^%s*(.-)%s*$")
  local parts = {}
  for grp in (s.."/"):gmatch("([^/]*)/") do
    for p in (grp.."."):gmatch("([^%.]*).") do
      if not p:match("^%d+$") then return nil end
      local n = tonumber(p)
      if n < 1 then return nil end
      parts[#parts+1]=n
    end
  end
  if #parts~=9 then return nil end
  return parts
end

function M.format_coordinate(c)
  return string.format("%d.%d.%d/%d.%d.%d/%d.%d.%d", c[1],c[2],c[3],c[4],c[5],c[6],c[7],c[8],c[9])
end

function M.compare(a,b)
  for i=1,9 do if a[i]~=b[i] then return a[i]<b[i] and -1 or 1 end end
  return 0
end

local function apply_break(coord,d)
  coord[d+1]=coord[d+1]+1
  for k=d+2,9 do coord[k]=1 end
end

-- phokenize(buffer) -> array of {coord={...}, text=...}
function M.phokenize(buffer)
  buffer = buffer or ""
  local out, walker = {}, {1,1,1,1,1,1,1,1,1}
  local i, len = 1, #buffer
  while i<=len do
    local b = buffer:byte(i)
    if BREAK_DIM[b]~=nil then
      apply_break(walker, BREAK_DIM[b]); i=i+1
    else
      local start=i
      while i<=len and BREAK_DIM[buffer:byte(i)]==nil do i=i+1 end
      local coord={}; for k=1,9 do coord[k]=walker[k] end
      out[#out+1]={coord=coord, text=buffer:sub(start,i-1)}
    end
  end
  return out
end

local function advance(loc,target)
  if M.compare(loc,target)>=0 then return "" end
  local d=1
  while loc[d]==target[d] do d=d+1 end
  local out = string.char(BREAKS[d]):rep(target[d]-loc[d])
  local reached={}; for k=1,9 do reached[k]=loc[k] end
  reached[d]=target[d]
  for k=d+1,9 do reached[k]=1 end
  for lower=d+1,9 do
    out = out .. string.char(BREAKS[lower]):rep(target[lower]-1)
    reached[lower]=target[lower]
  end
  for k=1,9 do loc[k]=reached[k] end
  return out
end

function M.dephokenize(scrolls)
  local out, loc = {}, {1,1,1,1,1,1,1,1,1}
  for _,ps in ipairs(scrolls) do
    out[#out+1]=advance(loc, ps.coord)
    out[#out+1]=ps.text
  end
  return table.concat(out)
end

function M.normalize(buffer) return M.dephokenize(M.phokenize(buffer)) end

function M.fetch(buffer,coord)
  for _,ps in ipairs(M.phokenize(buffer)) do
    if M.compare(ps.coord,coord)==0 then return ps.text end
  end
  return ""
end

local function update(buffer,coord,text,overwrite)
  local items=M.phokenize(buffer)
  local nxt={coord=coord,text=text}
  local result, appended = {}, false
  for _,ps in ipairs(items) do
    if not appended and M.compare(ps.coord,coord)>0 then
      result[#result+1]=nxt; appended=true
    end
    if not appended and M.compare(ps.coord,coord)==0 then
      if not overwrite then nxt.text=ps.text..nxt.text end
      result[#result+1]=nxt; appended=true
    else
      result[#result+1]=ps
    end
  end
  if not appended then result[#result+1]=nxt end
  return M.dephokenize(result)
end

function M.insert(buffer,coord,text) return update(buffer,coord,text,false) end
function M.replace(buffer,coord,text) return update(buffer,coord,text,true) end
-- remove is COORDINATE-PRESERVING: scroll becomes empty, delimiters stay,
-- later scrolls do NOT shift.
function M.remove(buffer,coord) return M.normalize(update(buffer,coord,"",true)) end

function M.explode(buffer)
  local map={}
  for _,ps in ipairs(M.phokenize(buffer)) do map[M.format_coordinate(ps.coord)]=ps.text end
  return map
end

function M.implode(map)
  local scrolls={}
  for k,v in pairs(map) do scrolls[#scrolls+1]={coord=M.parse_coordinate(k),text=v} end
  table.sort(scrolls,function(a,b) return M.compare(a.coord,b.coord)<0 end)
  return M.dephokenize(scrolls)
end

-- DynamicPhext: capacity-managed dynamic array (double on full, shrink
-- only at quarter-full). Holds PositionedScroll-like {coord,text} in
-- strictly increasing coordinate order; never stores an empty scroll.
local Dynamic = {}
Dynamic.__index = Dynamic
M.DynamicPhext = Dynamic

function Dynamic.new(buffer, shrink_divisor)
  local self=setmetatable({},Dynamic)
  self._shrink_divisor = shrink_divisor or 4
  if self._shrink_divisor < 2 then error("shrink_divisor must be >= 2") end
  self._capacity=1; self._data={}; self._n=0
  self._resize_count=0; self._elements_copied=0
  if buffer and #buffer>0 then self:load(buffer) end
  return self
end
function Dynamic:_resize(newcap)
  local nd={}
  for i=1,self._n do nd[i]=self._data[i] end
  self._data=nd; self._capacity=newcap
  self._resize_count=self._resize_count+1
  self._elements_copied=self._elements_copied+self._n
end
function Dynamic:_grow_if_full()
  if self._n==self._capacity then self:_resize(2*self._capacity) end
end
function Dynamic:_shrink_if_sparse()
  if self._capacity>1 and self._n <= math.floor(self._capacity/self._shrink_divisor) then
    self:_resize(math.max(1, math.floor(self._capacity/2)))
  end
end
function Dynamic:capacity() return self._capacity end
function Dynamic:resize_count() return self._resize_count end
function Dynamic:elements_copied() return self._elements_copied end
function Dynamic:reset_stats() self._resize_count=0; self._elements_copied=0 end
function Dynamic:load(buffer)
  self._capacity=1; self._data={}; self._n=0; self:reset_stats()
  for _,ps in ipairs(M.phokenize(buffer)) do self:_push(ps) end
end
function Dynamic:_push(ps)
  self:_grow_if_full(); self._n=self._n+1; self._data[self._n]=ps
end
function Dynamic:scrolls()
  local out={}; for i=1,self._n do out[i]=self._data[i] end; return out
end
function Dynamic:serialize() return M.dephokenize(self:scrolls()) end
function Dynamic:_find(coord)
  local lo,hi=1,self._n+1
  while lo<hi do
    local mid=math.floor((lo+hi)/2)
    local c=M.compare(self._data[mid].coord,coord)
    if c<0 then lo=mid+1 elseif c>0 then hi=mid else return mid,true end
  end
  return lo,false
end
function Dynamic:fetch(coord)
  local idx,found=self:_find(coord)
  return found and self._data[idx].text or ""
end
function Dynamic:contains(coord) local _,f=self:_find(coord); return f end
function Dynamic:len() return self._n end
function Dynamic:append(coord,text)
  if self._n>0 and M.compare(coord,self._data[self._n].coord)<=0 then
    error("append requires a coordinate past the current tail")
  end
  if #text==0 then return end
  self:_push({coord=coord,text=text})
end
function Dynamic:_remove_at(idx)
  for i=idx,self._n-1 do self._data[i]=self._data[i+1] end
  self._data[self._n]=nil; self._n=self._n-1
  self:_shrink_if_sparse()
end
function Dynamic:update(coord,text,overwrite)
  local idx,found=self:_find(coord)
  if found then
    if #text==0 then if overwrite then self:_remove_at(idx) end; return end
    if not overwrite then text=self._data[idx].text..text end
    self._data[idx]={coord=coord,text=text}
    return
  end
  if #text==0 then return end
  self:_grow_if_full()
  for i=self._n,idx,-1 do self._data[i+1]=self._data[i] end
  self._data[idx]={coord=coord,text=text}; self._n=self._n+1
end
function Dynamic:insert(coord,text) self:update(coord,text,false) end
function Dynamic:replace(coord,text) self:update(coord,text,true) end
function Dynamic:remove(coord)
  local idx,found=self:_find(coord)
  if found then self:_remove_at(idx) end
end

-- TransitivePhext: branching hash map, one map per dimension (depth 9,
-- dimension-generic BranchingMap underneath).
local Branching = {}
Branching.__index = Branching
M.BranchingMap = Branching
function Branching.new(depth)
  if depth<1 then error("depth must be >= 1") end
  local self=setmetatable({},Branching)
  self.depth=depth; self._root={}; self._count=0
  return self
end
function Branching:len() return self._count end
function Branching:fetch(key)
  local node=self._root
  for level=1,self.depth do
    local child=node[key[level]]
    if child==nil then return nil end
    if level==self.depth then return child end
    node=child
  end
end
function Branching:put(key,value)
  local node=self._root
  for level=1,self.depth do
    local comp=key[level]
    if level==self.depth then
      local created = node[comp]==nil
      node[comp]=value
      if created then self._count=self._count+1 end
      return created
    end
    local child=node[comp]
    if child==nil then child={}; node[comp]=child end
    node=child
  end
end
function Branching:remove(key)
  local function rec(node,level)
    local comp=key[level]
    if level==self.depth then
      if node[comp]~=nil then node[comp]=nil; return true end
      return false
    end
    local child=node[comp]
    if child==nil then return false end
    local removed=rec(child,level+1)
    if removed and next(child)==nil then node[comp]=nil end
    return removed
  end
  local removed=rec(self._root,1)
  if removed then self._count=self._count-1 end
  return removed
end
function Branching:items()
  local out={}
  local function rec(node,prefix)
    local keys={}
    for k in pairs(node) do keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do
      local v=node[k]
      local p={}; for i=1,#prefix do p[i]=prefix[i] end; p[#p+1]=k
      if type(v)=="table" then rec(v,p) else out[#out+1]={p,v} end
    end
  end
  rec(self._root,{})
  return out
end

local Transitive = {}
Transitive.__index = Transitive
M.TransitivePhext = Transitive
function Transitive.new(buffer)
  local self=setmetatable({},Transitive)
  self._depth=9
  self._map=Branching.new(self._depth)
  if buffer and #buffer>0 then self:load(buffer) end
  return self
end
function Transitive:depth() return self._depth end
function Transitive:load(buffer)
  self._map=Branching.new(self._depth)
  for _,ps in ipairs(M.phokenize(buffer)) do self._map:put(ps.coord,ps.text) end
end
function Transitive:scrolls()
  local out={}
  for _,kv in ipairs(self._map:items()) do out[#out+1]={coord=kv[1],text=kv[2]} end
  return out
end
function Transitive:serialize() return M.dephokenize(self:scrolls()) end
function Transitive:fetch(coord)
  local v=self._map:fetch(coord)
  return v==nil and "" or v
end
function Transitive:contains(coord) return self._map:fetch(coord)~=nil end
function Transitive:len() return self._map:len() end
function Transitive:update(coord,text,overwrite)
  if #text==0 then if overwrite then self._map:remove(coord) end; return end
  if not overwrite then
    local ex=self._map:fetch(coord)
    if ex~=nil then text=ex..text end
  end
  self._map:put(coord,text)
end
function Transitive:insert(coord,text) self:update(coord,text,false) end
function Transitive:replace(coord,text) self:update(coord,text,true) end
function Transitive:remove(coord) self._map:remove(coord) end
function Transitive:append(coord,text) self:insert(coord,text) end

return M
