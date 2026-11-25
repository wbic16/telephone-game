# Test suite for libphext-crystal — plain assertions, no framework.
# Run: test_phext [fixtures_dir]
require "../src/phext"

COUNTERS = [0, 0] # [checks, failures]

def ok(cond : Bool, name : String)
  COUNTERS[0] += 1
  unless cond
    COUNTERS[1] += 1
    STDERR.puts "FAIL: #{name}"
  end
end

def eq(a, b, name : String)
  ok(a == b, name)
end

def eqb(a : Bytes, b : Bytes, name : String)
  ok(a == b, name)
end

def b(s : String) : Bytes
  s.to_slice
end

def c(s : String) : Phext::Coord
  Phext.coord_parse(s)
end

# coordinate
eq(Phext.coord_string(c("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format")
ok(Phext.coord_compare(c("1.1.1/1.1.1/1.1.1"), c("1.1.1/1.1.1/1.1.2")) < 0, "order scroll")
ok(Phext.coord_compare(c("1.1.1/1.1.1/1.1.9"), c("1.1.1/1.1.2/1.1.1")) < 0, "order section")
ok(Phext.coord_compare(c("2.1.1/1.1.1/1.1.1"), c("1.9.9/9.9.9/9.9.9")) > 0, "order library")
eq(c("1.1.1/1.1.1/1.1.1"), Phext.coord_root, "root")
ok(raise_or_false { c("0.1.1/1.1.1/1.1.1") }, "coord rejects 0")
ok(raise_or_false { c("1.1/1.1.1/1.1.1") }, "coord rejects short")

def raise_or_false
  yield
  false
rescue
  true
end

# phokenize
sc = Phext.phokenize(b("hello"))
eq(sc.size, 1, "one scroll")
eq(Phext.coord_string(sc[0].coord), "1.1.1/1.1.1/1.1.1", "first coord")
eqb(sc[0].text, b("hello"), "first text")
sc = Phext.phokenize(b("a\x17b\x17\x17c\nline2"))
eq(sc.size, 3, "scroll breaks")
eq(Phext.coord_string(sc[1].coord), "1.1.1/1.1.1/1.1.2", "second coord")
eq(Phext.coord_string(sc[2].coord), "1.1.1/1.1.1/1.1.4", "gap coord advance")
eqb(sc[2].text, b("c\nline2"), "newline is ordinary text")
sc = Phext.phokenize(b("x\x01y"))
eq(Phext.coord_string(sc[1].coord), "2.1.1/1.1.1/1.1.1", "library break resets")
sc = Phext.phokenize(b("x\x18y"))
eq(Phext.coord_string(sc[1].coord), "1.1.1/1.1.1/1.2.1", "section break")
eq(Phext.phokenize(b("")).size, 0, "empty buffer")
sc = Phext.phokenize(Bytes[0x61, 0x00, 0xFF, 0x62])
eq(sc.size, 1, "binary text is one scroll")
eq(sc[0].text.size, 4, "binary text preserved")

# round trip
sample = b("alpha\x17beta\x18gamma\x01delta")
eqb(Phext.dephokenize(Phext.phokenize(sample)), sample, "round trip sample")
built = Phext.dephokenize([Phext::PositionedScroll.new(c("1.1.1/1.1.1/1.1.2"), b("two")),
                           Phext::PositionedScroll.new(c("1.1.1/1.1.1/1.1.1"), b("one"))])
eqb(built, b("one\x17two"), "dephokenize sorts canonically")
eqb(Phext.normalize(Phext.normalize(b("\x17\x17lead"))),
    Phext.normalize(b("\x17\x17lead")), "normalize idempotent")

# fetch incl. gaps
buf = b("one\x17two\x17\x17four")
eqb(Phext.fetch(buf, c("1.1.1/1.1.1/1.1.1")), b("one"), "fetch 1")
eqb(Phext.fetch(buf, c("1.1.1/1.1.1/1.1.4")), b("four"), "fetch 4")
eqb(Phext.fetch(buf, c("1.1.1/1.1.1/1.1.3")), b(""), "gap fetch is empty")
eqb(Phext.fetch(buf, c("9.9.9/9.9.9/9.9.9")), b(""), "far gap fetch is empty")
eqb(Phext.fetch(b(""), c("1.1.1/1.1.1/1.1.1")), b(""), "fetch empty buffer")

# insert
res = Phext.insert(b("base"), c("1.1.1/1.1.1/1.1.1"), b("+more"))
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.1")), b("base+more"), "insert appends after existing")
res = Phext.insert(b(""), c("1.1.1/1.1.1/1.1.3"), b("new"))
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.3")), b("new"), "insert creates at gap")
eqb(res, b("\x17\x17new"), "insert at gap emits breaks")
res = Phext.insert(b("a\x17c"), c("1.1.1/1.1.1/1.1.2"), b("b"))
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.2")), b("cb"), "insert merges existing + inserted")

# replace / remove — remove is coordinate-preserving
res = Phext.replace(b("old\x17keep"), c("1.1.1/1.1.1/1.1.1"), b("new"))
eqb(res, b("new\x17keep"), "replace overwrites")
res = Phext.replace(b("a"), c("1.1.1/1.1.1/1.1.5"), b("deep"))
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.5")), b("deep"), "replace creates")
res = Phext.remove(b("a\x17b\x17c"), c("1.1.1/1.1.1/1.1.2"))
eqb(res, b("a\x17\x17c"), "remove leaves a gap (no renumbering)")
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.2")), b(""), "removed coordinate reads empty")
eqb(Phext.fetch(res, c("1.1.1/1.1.1/1.1.3")), b("c"), "neighbour keeps its coordinate")
eq(Phext.remove(b("only"), c("1.1.1/1.1.1/1.1.1")).size, 0, "remove sole scroll")
eqb(Phext.remove(b("a"), c("5.5.5/5.5.5/5.5.5")), b("a"), "remove gap is a no-op")

# explode / implode
map = Phext.explode(b("x\x17y"))
eq(map.size, 2, "explode count")
eqb(Phext.implode(map), b("x\x17y"), "implode round trip")

# Dynamic + Transitive equivalence with the string path
dyn = DynamicPhext.new
trn = TransitivePhext.new
str_buf = Bytes.empty
step = ->(op : String, coord : String, text : String) {
  cc = c(coord)
  t = b(text)
  case op
  when "insert"
    str_buf = Phext.insert(str_buf, cc, t); dyn.insert(cc, t); trn.insert(cc, t)
  when "replace"
    str_buf = Phext.replace(str_buf, cc, t); dyn.replace(cc, t); trn.replace(cc, t)
  when "remove"
    str_buf = Phext.remove(str_buf, cc); dyn.remove(cc); trn.remove(cc)
  end
  eqb(dyn.serialize, str_buf, "dynamic == string after #{op} #{coord}")
  eqb(trn.serialize, str_buf, "transitive == string after #{op} #{coord}")
  eqb(dyn.fetch(cc), Phext.fetch(str_buf, cc), "dynamic fetch after op")
  eqb(trn.fetch(cc), Phext.fetch(str_buf, cc), "transitive fetch after op")
}
step.call("insert", "1.1.1/1.1.1/1.1.1", "alpha")
step.call("insert", "1.1.1/1.1.1/1.1.3", "gamma")
step.call("insert", "1.1.1/1.1.1/1.1.2", "beta")
step.call("insert", "1.1.1/1.1.1/1.1.2", "+")
step.call("replace", "2.1.1/1.1.1/1.1.1", "lib2")
step.call("remove", "1.1.1/1.1.1/1.1.3", "")
eqb(dyn.fetch(c("1.1.1/1.1.1/1.1.3")), b(""), "dynamic removed coord is gap")
eqb(trn.fetch(c("1.1.1/1.1.1/1.1.3")), b(""), "transitive removed coord is gap")
eqb(dyn.fetch(c("2.1.1/1.1.1/1.1.1")), b("lib2"), "dynamic neighbour unmoved")
eqb(trn.fetch(c("2.1.1/1.1.1/1.1.1")), b("lib2"), "transitive neighbour unmoved")
step.call("insert", "1.1.1/1.1.1/1.1.1", "")
step.call("replace", "1.1.1/1.1.1/1.1.1", "")
eq(dyn.length, trn.length, "store lengths agree")

# DynamicPhext capacity discipline
cap = DynamicPhext.new
(1..64).each { |i| cap.append([1i64, 1i64, 1i64, 1i64, 1i64, 1i64, 1i64, 1i64, i.to_i64], b("s")) }
eq(cap.capacity, 64, "capacity doubles to fit 64")
ok(cap.resize_count <= 7, "resize count is logarithmic")

# fixtures
if ARGV.size > 0
  files = 0
  identical = 0
  idem = 0
  Dir.glob(File.join(ARGV[0], "**", "input.phext")).each do |path|
    files += 1
    data = File.read(path).to_slice
    identical += 1 if Phext.dephokenize(Phext.phokenize(data)) == data
    n1 = Phext.normalize(data)
    idem += 1 if Phext.normalize(n1) == n1
  end
  puts "fixtures: #{files} input.phext, #{identical} byte-identical round-trips, #{idem} normalize-idempotent"
  eq(files, 16, "16 fixtures found")
  eq(identical, files, "fixtures byte-identical round-trips")
  eq(idem, files, "all fixtures normalize idempotently")
else
  puts "fixtures: skipped (no fixtures dir)"
end

puts "crystal suite: #{COUNTERS[0]} checks, #{COUNTERS[1]} failures"
exit(COUNTERS[1] == 0 ? 0 : 1)
