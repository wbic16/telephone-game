# Test suite for libphext-ruby — plain assertions, no gem dependencies.
# Run: ruby test/test_phext.rb [fixtures_dir]
$LOAD_PATH.unshift(File.expand_path('../src', __dir__))
require 'phext'

$failures = 0
$checks = 0

def ok(cond, name)
  $checks += 1
  return if cond

  $failures += 1
  warn "FAIL: #{name}"
end

def eq(a, b, name)
  ok(a == b, "#{name} (got #{a.inspect}, want #{b.inspect})")
end

def b(str)
  str.b
end

def c(str)
  Phext::Coordinate.parse(str)
end

# coordinate
eq(c('1.2.3/4.5.6/7.8.9').to_s, '1.2.3/4.5.6/7.8.9', 'coord format')
ok(c('1.1.1/1.1.1/1.1.1') < c('1.1.1/1.1.1/1.1.2'), 'order scroll')
ok(c('1.1.1/1.1.1/1.1.9') < c('1.1.1/1.1.2/1.1.1'), 'order section')
ok(c('2.1.1/1.1.1/1.1.1') > c('1.9.9/9.9.9/9.9.9'), 'order library')
eq(c('1.1.1/1.1.1/1.1.1'), Phext::Coordinate.root, 'root')
begin
  c('0.1.1/1.1.1/1.1.1')
  ok(false, 'coord rejects 0')
rescue ArgumentError
  ok(true, 'coord rejects 0')
end
begin
  c('1.1/1.1.1/1.1.1')
  ok(false, 'coord rejects short')
rescue ArgumentError
  ok(true, 'coord rejects short')
end

# phokenize
sc = Phext.phokenize(b('hello'))
eq(sc.length, 1, 'one scroll')
eq(sc[0].coord.to_s, '1.1.1/1.1.1/1.1.1', 'first coord')
eq(sc[0].text, 'hello', 'first text')
sc = Phext.phokenize(b("a\x17b\x17\x17c\nline2"))
eq(sc.length, 3, 'scroll breaks')
eq(sc[1].coord.to_s, '1.1.1/1.1.1/1.1.2', 'second coord')
eq(sc[2].coord.to_s, '1.1.1/1.1.1/1.1.4', 'gap coord advance')
eq(sc[2].text, "c\nline2", 'newline is ordinary text')
sc = Phext.phokenize(b("x\x01y"))
eq(sc[1].coord.to_s, '2.1.1/1.1.1/1.1.1', 'library break resets')
sc = Phext.phokenize(b("x\x18y"))
eq(sc[1].coord.to_s, '1.1.1/1.1.1/1.2.1', 'section break')
eq(Phext.phokenize(''.b).length, 0, 'empty buffer')
# binary safety: NUL and high bytes are ordinary text
sc = Phext.phokenize("a\x00\xffb".b)
eq(sc.length, 1, 'binary text is one scroll')
eq(sc[0].text.bytesize, 4, 'binary text preserved')

# round trip
sample = b("alpha\x17beta\x18gamma\x01delta")
eq(Phext.dephokenize(Phext.phokenize(sample)), sample, 'round trip sample')
built = Phext.dephokenize([Phext::PositionedScroll.new(c('1.1.1/1.1.1/1.1.2'), b('two')),
                           Phext::PositionedScroll.new(c('1.1.1/1.1.1/1.1.1'), b('one'))])
eq(built, b("one\x17two"), 'dephokenize sorts canonically')
eq(Phext.normalize(Phext.normalize(b("\x17\x17lead"))),
   Phext.normalize(b("\x17\x17lead")), 'normalize idempotent')

# fetch incl. gaps
buf = b("one\x17two\x17\x17four")
eq(Phext.fetch(buf, c('1.1.1/1.1.1/1.1.1')), 'one', 'fetch 1')
eq(Phext.fetch(buf, c('1.1.1/1.1.1/1.1.4')), 'four', 'fetch 4')
eq(Phext.fetch(buf, c('1.1.1/1.1.1/1.1.3')), '', 'gap fetch is empty')
eq(Phext.fetch(buf, c('9.9.9/9.9.9/9.9.9')), '', 'far gap fetch is empty')
eq(Phext.fetch(''.b, c('1.1.1/1.1.1/1.1.1')), '', 'fetch empty buffer')

# insert: existing + inserted (existing prepended)
out = Phext.insert(b('base'), c('1.1.1/1.1.1/1.1.1'), b('+more'))
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.1')), 'base+more', 'insert appends after existing')
out = Phext.insert(''.b, c('1.1.1/1.1.1/1.1.3'), b('new'))
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.3')), 'new', 'insert creates at gap')
eq(out, b("\x17\x17new"), 'insert at gap emits breaks')
out = Phext.insert(b("a\x17c"), c('1.1.1/1.1.1/1.1.2'), b('b'))
eq(out, b("a\x17cb"), 'insert at existing scroll merges (existing + inserted)')
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.2')), 'cb', 'merged scroll at coordinate')

# replace / remove
out = Phext.replace(b("old\x17keep"), c('1.1.1/1.1.1/1.1.1'), b('new'))
eq(out, b("new\x17keep"), 'replace overwrites')
out = Phext.replace(b('a'), c('1.1.1/1.1.1/1.1.5'), b('deep'))
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.5')), 'deep', 'replace creates')
out = Phext.remove(b("a\x17b\x17c"), c('1.1.1/1.1.1/1.1.2'))
eq(out, b("a\x17\x17c"), 'remove + normalize leaves a gap (no renumbering)')
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.2')), '', 'removed coordinate is a gap')
eq(Phext.fetch(out, c('1.1.1/1.1.1/1.1.3')), 'c', 'later scroll keeps its coordinate')
eq(Phext.remove(b('only'), c('1.1.1/1.1.1/1.1.1')).bytesize, 0, 'remove sole scroll')
eq(Phext.remove(b('a'), c('5.5.5/5.5.5/5.5.5')), 'a', 'remove gap is a no-op')

# explode / implode
map = Phext.explode(b("x\x17y"))
eq(map.length, 2, 'explode count')
eq(Phext.implode(map), b("x\x17y"), 'implode round trip')

# fixtures
fx = ARGV[0] || ENV['PHEXT_FIXTURES']
if fx && File.directory?(fx)
  files = 0
  identical = 0
  idem = 0
  Dir.glob(File.join(fx, '**', 'input.phext')).each do |path|
    files += 1
    data = File.binread(path)
    identical += 1 if Phext.dephokenize(Phext.phokenize(data)) == data
    n1 = Phext.normalize(data)
    idem += 1 if Phext.normalize(n1) == n1
  end
  puts "fixtures: #{files} input.phext, #{identical} byte-identical " \
       "round-trips, #{idem} normalize-idempotent"
  eq(idem, files, 'all fixtures normalize idempotently')
  ok(identical >= files - 2, "fixtures byte-identical round-trips (#{identical}/#{files})")
else
  puts 'fixtures: skipped (no fixtures dir)'
end

puts "ruby suite: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
