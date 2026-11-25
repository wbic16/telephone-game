# Test suite for libphext-elixir -- plain assertions, no framework.
# Run: test_phext.exs [fixtures_dir]
Code.require_file("../src/phext.ex", __DIR__)

defmodule Suite do
  def start, do: Agent.start_link(fn -> {0, 0} end, name: __MODULE__)

  def ok(cond, name) do
    Agent.update(__MODULE__, fn {c, f} -> {c + 1, if(cond, do: f, else: f + 1)} end)
    unless cond, do: IO.puts(:stderr, "FAIL: #{name}")
  end

  def eq(a, b, name), do: ok(a == b, name)
  def c(s), do: Phext.coord_parse(s)

  def raises?(fun) do
    fun.()
    false
  rescue
    _ -> true
  end

  def run do
    c = &c/1
    eq(Phext.coord_string(c.("1.2.3/4.5.6/7.8.9")), "1.2.3/4.5.6/7.8.9", "coord format")
    ok(Phext.coord_compare(c.("1.1.1/1.1.1/1.1.1"), c.("1.1.1/1.1.1/1.1.2")) < 0, "order scroll")
    ok(Phext.coord_compare(c.("1.1.1/1.1.1/1.1.9"), c.("1.1.1/1.1.2/1.1.1")) < 0, "order section")
    ok(Phext.coord_compare(c.("2.1.1/1.1.1/1.1.1"), c.("1.9.9/9.9.9/9.9.9")) > 0, "order library")
    eq(c.("1.1.1/1.1.1/1.1.1"), Phext.coord_root(), "root")
    ok(raises?(fn -> c.("0.1.1/1.1.1/1.1.1") end), "coord rejects 0")
    ok(raises?(fn -> c.("1.1/1.1.1/1.1.1") end), "coord rejects short")

    sc = Phext.phokenize("hello")
    eq(length(sc), 1, "one scroll")
    eq(Phext.coord_string(elem(hd(sc), 0)), "1.1.1/1.1.1/1.1.1", "first coord")
    eq(elem(hd(sc), 1), "hello", "first text")
    sc = Phext.phokenize("a\x17b\x17\x17c\nline2")
    eq(length(sc), 3, "scroll breaks")
    eq(Phext.coord_string(elem(Enum.at(sc, 1), 0)), "1.1.1/1.1.1/1.1.2", "second coord")
    eq(Phext.coord_string(elem(Enum.at(sc, 2), 0)), "1.1.1/1.1.1/1.1.4", "gap coord advance")
    eq(elem(Enum.at(sc, 2), 1), "c\nline2", "newline is ordinary text")
    sc = Phext.phokenize("x\x01y")
    eq(Phext.coord_string(elem(Enum.at(sc, 1), 0)), "2.1.1/1.1.1/1.1.1", "library break resets")
    sc = Phext.phokenize("x\x18y")
    eq(Phext.coord_string(elem(Enum.at(sc, 1), 0)), "1.1.1/1.1.1/1.2.1", "section break")
    eq(length(Phext.phokenize("")), 0, "empty buffer")
    sc = Phext.phokenize(<<0x61, 0x00, 0xFF, 0x62>>)
    eq(length(sc), 1, "binary text is one scroll")
    eq(byte_size(elem(hd(sc), 1)), 4, "binary text preserved")

    sample = "alpha\x17beta\x18gamma\x01delta"
    eq(Phext.dephokenize(Phext.phokenize(sample)), sample, "round trip sample")
    built = Phext.dephokenize([{c.("1.1.1/1.1.1/1.1.2"), "two"}, {c.("1.1.1/1.1.1/1.1.1"), "one"}])
    eq(built, "one\x17two", "dephokenize sorts canonically")
    eq(Phext.normalize(Phext.normalize("\x17\x17lead")), Phext.normalize("\x17\x17lead"),
       "normalize idempotent")

    buf = "one\x17two\x17\x17four"
    eq(Phext.fetch(buf, c.("1.1.1/1.1.1/1.1.1")), "one", "fetch 1")
    eq(Phext.fetch(buf, c.("1.1.1/1.1.1/1.1.4")), "four", "fetch 4")
    eq(Phext.fetch(buf, c.("1.1.1/1.1.1/1.1.3")), "", "gap fetch is empty")
    eq(Phext.fetch(buf, c.("9.9.9/9.9.9/9.9.9")), "", "far gap fetch is empty")
    eq(Phext.fetch("", c.("1.1.1/1.1.1/1.1.1")), "", "fetch empty buffer")

    res = Phext.insert("base", c.("1.1.1/1.1.1/1.1.1"), "+more")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.1")), "base+more", "insert appends after existing")
    res = Phext.insert("", c.("1.1.1/1.1.1/1.1.3"), "new")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.3")), "new", "insert creates at gap")
    eq(res, "\x17\x17new", "insert at gap emits breaks")
    res = Phext.insert("a\x17c", c.("1.1.1/1.1.1/1.1.2"), "b")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.2")), "cb", "insert merges existing + inserted")

    res = Phext.replace("old\x17keep", c.("1.1.1/1.1.1/1.1.1"), "new")
    eq(res, "new\x17keep", "replace overwrites")
    res = Phext.replace("a", c.("1.1.1/1.1.1/1.1.5"), "deep")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.5")), "deep", "replace creates")
    res = Phext.remove("a\x17b\x17c", c.("1.1.1/1.1.1/1.1.2"))
    eq(res, "a\x17\x17c", "remove leaves a gap (no renumbering)")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.2")), "", "removed coordinate reads empty")
    eq(Phext.fetch(res, c.("1.1.1/1.1.1/1.1.3")), "c", "neighbour keeps its coordinate")
    eq(byte_size(Phext.remove("only", c.("1.1.1/1.1.1/1.1.1"))), 0, "remove sole scroll")
    eq(Phext.remove("a", c.("5.5.5/5.5.5/5.5.5")), "a", "remove gap is a no-op")

    map = Phext.explode("x\x17y")
    eq(map_size(map), 2, "explode count")
    eq(Phext.implode(map), "x\x17y", "implode round trip")

    step = fn op, coord, text, {dyn, trn, str_buf} ->
      cc = c.(coord)

      {dyn, trn, str_buf} =
        case op do
          "insert" ->
            {DynamicPhext.insert(dyn, cc, text), TransitivePhext.insert(trn, cc, text),
             Phext.insert(str_buf, cc, text)}

          "replace" ->
            {DynamicPhext.replace(dyn, cc, text), TransitivePhext.replace(trn, cc, text),
             Phext.replace(str_buf, cc, text)}

          "remove" ->
            {DynamicPhext.remove(dyn, cc), TransitivePhext.remove(trn, cc),
             Phext.remove(str_buf, cc)}
        end

      eq(DynamicPhext.serialize(dyn), str_buf, "dynamic == string after #{op} #{coord}")
      eq(TransitivePhext.serialize(trn), str_buf, "transitive == string after #{op} #{coord}")
      eq(DynamicPhext.fetch(dyn, cc), Phext.fetch(str_buf, cc), "dynamic fetch after op")
      eq(TransitivePhext.fetch(trn, cc), Phext.fetch(str_buf, cc), "transitive fetch after op")
      {dyn, trn, str_buf}
    end

    state = {DynamicPhext.new(), TransitivePhext.new(), ""}
    state = step.("insert", "1.1.1/1.1.1/1.1.1", "alpha", state)
    state = step.("insert", "1.1.1/1.1.1/1.1.3", "gamma", state)
    state = step.("insert", "1.1.1/1.1.1/1.1.2", "beta", state)
    state = step.("insert", "1.1.1/1.1.1/1.1.2", "+", state)
    state = step.("replace", "2.1.1/1.1.1/1.1.1", "lib2", state)
    {dyn, trn, _} = step.("remove", "1.1.1/1.1.1/1.1.3", "", state)
    eq(DynamicPhext.fetch(dyn, c.("1.1.1/1.1.1/1.1.3")), "", "dynamic removed coord is gap")
    eq(TransitivePhext.fetch(trn, c.("1.1.1/1.1.1/1.1.3")), "", "transitive removed coord is gap")
    eq(DynamicPhext.fetch(dyn, c.("2.1.1/1.1.1/1.1.1")), "lib2", "dynamic neighbour unmoved")
    eq(TransitivePhext.fetch(trn, c.("2.1.1/1.1.1/1.1.1")), "lib2", "transitive neighbour unmoved")
    dyn = dyn |> DynamicPhext.insert(c.("1.1.1/1.1.1/1.1.1"), "") |> DynamicPhext.replace(c.("1.1.1/1.1.1/1.1.1"), "")
    trn = trn |> TransitivePhext.insert(c.("1.1.1/1.1.1/1.1.1"), "") |> TransitivePhext.replace(c.("1.1.1/1.1.1/1.1.1"), "")
    eq(DynamicPhext.length(dyn), TransitivePhext.length(trn), "store lengths agree")

    cap =
      Enum.reduce(1..64, DynamicPhext.new(), fn i, d ->
        DynamicPhext.append(d, {1, 1, 1, 1, 1, 1, 1, 1, i}, "s")
      end)

    eq(cap.capacity, 64, "capacity doubles to fit 64")
    ok(cap.resize_count <= 7, "resize count is logarithmic")
  end

  def fixtures(dir) do
    files = Path.wildcard(Path.join([dir, "**", "input.phext"]))

    {identical, idem} =
      Enum.reduce(files, {0, 0}, fn path, {i1, i2} ->
        data = File.read!(path)
        i1 = if Phext.dephokenize(Phext.phokenize(data)) == data, do: i1 + 1, else: i1
        n1 = Phext.normalize(data)
        i2 = if Phext.normalize(n1) == n1, do: i2 + 1, else: i2
        {i1, i2}
      end)

    IO.puts(
      "fixtures: #{length(files)} input.phext, #{identical} byte-identical round-trips, #{idem} normalize-idempotent"
    )

    eq(length(files), 16, "16 fixtures found")
    eq(identical, length(files), "fixtures byte-identical round-trips")
    eq(idem, length(files), "all fixtures normalize idempotently")
  end
end

{:ok, _} = Suite.start()
Suite.run()

case System.argv() do
  [dir] -> Suite.fixtures(dir)
  _ -> IO.puts("fixtures: skipped (no fixtures dir)")
end

{checks, failures} = Agent.get(Suite, fn s -> s end)
IO.puts("elixir suite: #{checks} checks, #{failures} failures")
if failures > 0, do: System.halt(1)
