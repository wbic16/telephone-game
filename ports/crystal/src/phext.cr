# libphext-crystal — a Crystal port of libphext (0.6.1 parity).
#
# Semantics are normative from libphext-py: a phext is a byte buffer;
# nine dimension-break bytes walk a 9-component coordinate; scroll text
# is a maximal run of non-break bytes (newline 0x0A is ordinary text).
# All buffers are Bytes (Slice(UInt8)) so control bytes are never
# reinterpreted. Coordinates are Array(Int64) of length 9, ordered
# lexicographically; string form a.b.c/d.e.f/g.h.i.

module Phext
  DIMENSION_BREAKS = [0x01u8, 0x1Fu8, 0x1Eu8, 0x1Du8, 0x1Cu8, 0x1Au8, 0x19u8, 0x18u8, 0x17u8]
  BREAK_DIM = begin
    h = {} of UInt8 => Int32
    DIMENSION_BREAKS.each_with_index { |b, d| h[b] = d }
    h
  end

  alias Coord = Array(Int64)

  def self.coord_root : Coord
    Array(Int64).new(9, 1i64)
  end

  def self.coord_parse(s : String) : Coord
    groups = s.strip.split('/')
    raise "coordinate must be a.b.c/d.e.f/g.h.i: #{s}" unless groups.size == 3
    nums = [] of Int64
    groups.each { |g| g.split('.').each { |p| nums << p.to_i64 } }
    raise "coordinate needs 9 parts: #{s}" unless nums.size == 9
    raise "components must be >= 1: #{s}" if nums.any? { |v| v < 1 }
    nums
  end

  def self.coord_string(c : Coord) : String
    "#{c[0]}.#{c[1]}.#{c[2]}/#{c[3]}.#{c[4]}.#{c[5]}/#{c[6]}.#{c[7]}.#{c[8]}"
  end

  def self.coord_compare(a : Coord, b : Coord) : Int32
    9.times do |i|
      return a[i] <=> b[i] if a[i] != b[i]
    end
    0
  end

  def self.coord_apply_break(c : Coord, d : Int32) : Coord
    out = c.dup
    out[d] += 1
    (d + 1...9).each { |lower| out[lower] = 1i64 }
    out
  end

  record PositionedScroll, coord : Coord, text : Bytes

  def self.phokenize(buffer : Bytes) : Array(PositionedScroll)
    out = [] of PositionedScroll
    coord = coord_root
    run_start = 0
    i = 0
    while i < buffer.size
      d = BREAK_DIM[buffer[i]]?
      if d
        out << PositionedScroll.new(coord, buffer[run_start...i]) if i > run_start
        coord = coord_apply_break(coord, d)
        run_start = i + 1
      end
      i += 1
    end
    out << PositionedScroll.new(coord, buffer[run_start...buffer.size]) if buffer.size > run_start
    out
  end

  private def self.emit_advance(io : IO::Memory, loc : Coord, target : Coord) : Coord
    if coord_compare(loc, target) < 0
      dim = 0
      while loc[dim] == target[dim]
        dim += 1
      end
      (target[dim] - loc[dim]).times { io.write_byte(DIMENSION_BREAKS[dim]) }
      (dim + 1...9).each do |lower|
        (target[lower] - 1).times { io.write_byte(DIMENSION_BREAKS[lower]) }
      end
    end
    target
  end

  def self.dephokenize(stack : Array(PositionedScroll)) : Bytes
    sorted = stack.sort { |a, b| coord_compare(a.coord, b.coord) }
    io = IO::Memory.new
    loc = coord_root
    sorted.each do |ps|
      next if ps.text.empty?
      loc = emit_advance(io, loc, ps.coord)
      io.write(ps.text)
    end
    io.to_slice
  end

  private def self.dephokenize_in_order(stack : Array(PositionedScroll)) : Bytes
    io = IO::Memory.new
    loc = coord_root
    stack.each do |ps|
      loc = emit_advance(io, loc, ps.coord)
      io.write(ps.text)
    end
    io.to_slice
  end

  def self.normalize(buffer : Bytes) : Bytes
    dephokenize(phokenize(buffer))
  end

  def self.fetch(buffer : Bytes, coord : Coord) : Bytes
    hit = phokenize(buffer).find { |ps| ps.coord == coord }
    hit ? hit.text : Bytes.empty
  end

  private def self.update(buffer : Bytes, coord : Coord, scroll : Bytes, overwrite : Bool) : Bytes
    items = phokenize(buffer)
    result = [] of PositionedScroll
    next_ps = PositionedScroll.new(coord, scroll)
    appended = false
    items.each do |ps|
      cmp = coord_compare(ps.coord, coord)
      if cmp > 0 && !appended
        result << next_ps
        appended = true
        result << ps
      elsif cmp == 0 && !appended
        merged = overwrite ? next_ps : PositionedScroll.new(coord, ps.text + next_ps.text)
        result << merged
        appended = true
      else
        result << ps
      end
    end
    result << next_ps unless appended
    dephokenize_in_order(result)
  end

  # insert: existing text is prepended to the inserted text.
  def self.insert(buffer : Bytes, coord : Coord, scroll : Bytes) : Bytes
    update(buffer, coord, scroll, false)
  end

  def self.replace(buffer : Bytes, coord : Coord, scroll : Bytes) : Bytes
    update(buffer, coord, scroll, true)
  end

  # remove: replace with "" then normalize — coordinate-preserving:
  # the removed coordinate reads "" and neighbours do not shift.
  def self.remove(buffer : Bytes, coord : Coord) : Bytes
    normalize(update(buffer, coord, Bytes.empty, true))
  end

  def self.explode(buffer : Bytes) : Hash(Coord, Bytes)
    out = {} of Coord => Bytes
    phokenize(buffer).each { |ps| out[ps.coord] = ps.text }
    out
  end

  def self.implode(map : Hash(Coord, Bytes)) : Bytes
    dephokenize(map.map { |c, t| PositionedScroll.new(c, t) })
  end
end

# ------------------------------------------------------------------
# DynamicPhext: capacity-managed dynamic array scroll store.
# Start at capacity 1, double when full on append, shrink only at
# quarter load (never half — that thrashes).
class DynamicPhext
  getter capacity : Int32
  getter resize_count : Int32
  getter elements_copied : Int64
  getter shrink_divisor : Int32

  def initialize(buffer : Bytes = Bytes.empty, @shrink_divisor : Int32 = 4)
    raise "shrink_divisor must be >= 2" if @shrink_divisor < 2
    @data = Array(Phext::PositionedScroll?).new(1) { nil }
    @capacity = 1
    @n = 0
    @resize_count = 0
    @elements_copied = 0i64
    load(buffer) unless buffer.empty?
  end

  def length : Int32
    @n
  end

  private def resize(new_capacity : Int32)
    nd = Array(Phext::PositionedScroll?).new(new_capacity) { nil }
    @n.times { |i| nd[i] = @data[i] }
    @data = nd
    @capacity = new_capacity
    @resize_count += 1
    @elements_copied += @n
  end

  private def grow_if_full
    resize(2 * @capacity) if @n == @capacity
  end

  private def shrink_if_sparse
    resize(Math.max(1, @capacity // 2)) if @capacity > 1 && @n <= @capacity // @shrink_divisor
  end

  private def push(ps : Phext::PositionedScroll)
    grow_if_full
    @data[@n] = ps
    @n += 1
  end

  def load(buffer : Bytes)
    @capacity = 1
    @data = Array(Phext::PositionedScroll?).new(1) { nil }
    @n = 0
    @resize_count = 0
    @elements_copied = 0i64
    Phext.phokenize(buffer).each { |ps| push(ps) }
  end

  def scrolls : Array(Phext::PositionedScroll)
    out = [] of Phext::PositionedScroll
    @n.times { |i| out << @data[i].not_nil! }
    out
  end

  def serialize : Bytes
    Phext.dephokenize(scrolls)
  end

  # Binary search: {index, found}; index is the insertion point.
  private def find(coord : Phext::Coord) : Tuple(Int32, Bool)
    lo = 0
    hi = @n
    while lo < hi
      mid = (lo + hi) // 2
      cmp = Phext.coord_compare(@data[mid].not_nil!.coord, coord)
      if cmp < 0
        lo = mid + 1
      elsif cmp > 0
        hi = mid
      else
        return {mid, true}
      end
    end
    {lo, false}
  end

  def fetch(coord : Phext::Coord) : Bytes
    index, found = find(coord)
    found ? @data[index].not_nil!.text : Bytes.empty
  end

  def contains?(coord : Phext::Coord) : Bool
    find(coord)[1]
  end

  def append(coord : Phext::Coord, text : Bytes)
    if @n > 0 && Phext.coord_compare(coord, @data[@n - 1].not_nil!.coord) <= 0
      raise "append requires a coordinate past the current tail"
    end
    push(Phext::PositionedScroll.new(coord, text)) unless text.empty?
  end

  def update(coord : Phext::Coord, text : Bytes, overwrite : Bool)
    index, found = find(coord)
    if found
      if text.empty?
        remove_at(index) if overwrite
      else
        t = overwrite ? text : @data[index].not_nil!.text + text
        @data[index] = Phext::PositionedScroll.new(coord, t)
      end
    elsif !text.empty?
      grow_if_full
      i = @n
      while i > index
        @data[i] = @data[i - 1]
        i -= 1
      end
      @data[index] = Phext::PositionedScroll.new(coord, text)
      @n += 1
    end
  end

  def insert(coord : Phext::Coord, text : Bytes)
    update(coord, text, false)
  end

  def replace(coord : Phext::Coord, text : Bytes)
    update(coord, text, true)
  end

  private def remove_at(index : Int32)
    i = index
    while i < @n - 1
      @data[i] = @data[i + 1]
      i += 1
    end
    @n -= 1
    @data[@n] = nil
    shrink_if_sparse
  end

  def remove(coord : Phext::Coord)
    index, found = find(coord)
    remove_at(index) if found
  end
end

# ------------------------------------------------------------------
# BranchingMap: a hash map of dimension `depth` branching into hash
# maps of one fewer dimension, recursively, down to leaves holding
# scroll text. One map lookup per dimension.
class BranchingMap
  getter depth : Int32

  private class Node
    property children = {} of Int64 => Node
    property leaf : Bytes? = nil
  end

  def initialize(@depth : Int32)
    raise "depth must be >= 1" if @depth < 1
    @root = Node.new
    @count = 0
  end

  def length : Int32
    @count
  end

  def fetch(key : Phext::Coord) : Bytes?
    node = @root
    level = 0
    loop do
      child = node.children[key[level]]?
      return nil if child.nil?
      return child.leaf if level == @depth - 1
      node = child
      level += 1
    end
  end

  def contains?(key : Phext::Coord) : Bool
    !fetch(key).nil?
  end

  # Returns true when a new leaf was created.
  def put(key : Phext::Coord, value : Bytes) : Bool
    node = @root
    level = 0
    loop do
      comp = key[level]
      child = node.children[comp] ||= Node.new
      if level == @depth - 1
        created = child.leaf.nil?
        child.leaf = value
        @count += 1 if created
        return created
      end
      node = child
      level += 1
    end
  end

  def remove(key : Phext::Coord) : Bool
    removed = remove_rec(@root, key, 0)
    @count -= 1 if removed
    removed
  end

  private def remove_rec(node : Node, key : Phext::Coord, level : Int32) : Bool
    comp = key[level]
    child = node.children[comp]?
    return false if child.nil?
    if level == @depth - 1
      return false if child.leaf.nil?
      node.children.delete(comp)
      true
    else
      removed = remove_rec(child, key, level + 1)
      node.children.delete(comp) if removed && child.children.empty? && child.leaf.nil?
      removed
    end
  end

  # Items in lexicographic (coordinate) order.
  def items : Array(Tuple(Phext::Coord, Bytes))
    acc = [] of Tuple(Phext::Coord, Bytes)
    items_rec(@root, [] of Int64, 0, acc)
    acc
  end

  private def items_rec(node : Node, prefix : Phext::Coord, level : Int32,
                        acc : Array(Tuple(Phext::Coord, Bytes)))
    node.children.keys.sort.each do |comp|
      child = node.children[comp]
      if level == @depth - 1
        acc << {prefix + [comp], child.leaf.not_nil!}
      else
        items_rec(child, prefix + [comp], level + 1, acc)
      end
    end
  end
end

# ------------------------------------------------------------------
# TransitivePhext: scroll store over a BranchingMap at depth 9.
class TransitivePhext
  def initialize(buffer : Bytes = Bytes.empty)
    @map = BranchingMap.new(9)
    load(buffer) unless buffer.empty?
  end

  def depth : Int32
    @map.depth
  end

  def length : Int32
    @map.length
  end

  def load(buffer : Bytes)
    @map = BranchingMap.new(9)
    Phext.phokenize(buffer).each { |ps| @map.put(ps.coord, ps.text) }
  end

  def scrolls : Array(Phext::PositionedScroll)
    @map.items.map { |k, t| Phext::PositionedScroll.new(k, t) }
  end

  def serialize : Bytes
    Phext.dephokenize(scrolls)
  end

  def fetch(coord : Phext::Coord) : Bytes
    @map.fetch(coord) || Bytes.empty
  end

  def contains?(coord : Phext::Coord) : Bool
    @map.contains?(coord)
  end

  def update(coord : Phext::Coord, text : Bytes, overwrite : Bool)
    if text.empty?
      @map.remove(coord) if overwrite
    elsif overwrite
      @map.put(coord, text)
    else
      existing = @map.fetch(coord)
      @map.put(coord, existing ? existing + text : text)
    end
  end

  def insert(coord : Phext::Coord, text : Bytes)
    update(coord, text, false)
  end

  def replace(coord : Phext::Coord, text : Bytes)
    update(coord, text, true)
  end

  def remove(coord : Phext::Coord)
    @map.remove(coord)
  end

  def append(coord : Phext::Coord, text : Bytes)
    insert(coord, text)
  end
end
