# libphext-elixir -- an Elixir port of libphext (0.6.1 parity).
#
# Semantics normative from libphext-py: a phext is a byte buffer; nine
# dimension-break bytes walk a 9-component coordinate; scroll text is
# a maximal run of non-break bytes (newline 0x0A is ordinary text).
# Buffers are binaries; coordinates are 9-tuples of integers, ordered
# lexicographically (Elixir tuple term order); string form
# a.b.c/d.e.f/g.h.i.

defmodule Phext do
  @breaks [0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17]
  @break_dim Map.new(Enum.with_index(@breaks))

  def coord_root, do: {1, 1, 1, 1, 1, 1, 1, 1, 1}

  def coord_parse(s) do
    groups = String.split(String.trim(s), "/")
    if length(groups) != 3, do: raise("coordinate must be a.b.c/d.e.f/g.h.i: #{s}")
    nums = Enum.flat_map(groups, fn g -> Enum.map(String.split(g, "."), &String.to_integer/1) end)
    if length(nums) != 9, do: raise("coordinate needs 9 parts: #{s}")
    if Enum.any?(nums, &(&1 < 1)), do: raise("components must be >= 1: #{s}")
    List.to_tuple(nums)
  end

  def coord_string(c) do
    [a, b, cc, d, e, f, g, h, i] = Tuple.to_list(c)
    "#{a}.#{b}.#{cc}/#{d}.#{e}.#{f}/#{g}.#{h}.#{i}"
  end

  def coord_compare(a, b) do
    cond do
      a < b -> -1
      a > b -> 1
      true -> 0
    end
  end

  def coord_apply_break(c, d) do
    l = Tuple.to_list(c)
    List.to_tuple(Enum.take(l, d) ++ [Enum.at(l, d) + 1] ++ List.duplicate(1, 8 - d))
  end

  def phokenize(buffer), do: phok(buffer, coord_root(), 0, 0, [])

  defp phok(buffer, coord, i, run_start, acc) when i < byte_size(buffer) do
    b = :binary.at(buffer, i)

    case Map.fetch(@break_dim, b) do
      :error ->
        phok(buffer, coord, i + 1, run_start, acc)

      {:ok, d} ->
        acc =
          if i > run_start,
            do: [{coord, binary_part(buffer, run_start, i - run_start)} | acc],
            else: acc

        phok(buffer, coord_apply_break(coord, d), i + 1, i + 1, acc)
    end
  end

  defp phok(buffer, coord, _i, run_start, acc) do
    acc =
      if byte_size(buffer) > run_start,
        do: [{coord, binary_part(buffer, run_start, byte_size(buffer) - run_start)} | acc],
        else: acc

    Enum.reverse(acc)
  end

  defp emit_advance(loc, target, acc) do
    if loc < target do
      la = Tuple.to_list(loc)
      ta = Tuple.to_list(target)
      dim = Enum.find_index(Enum.zip(la, ta), fn {x, y} -> x != y end)
      acc = prepend_repeated(acc, Enum.at(@breaks, dim), Enum.at(ta, dim) - Enum.at(la, dim))

      acc =
        Enum.reduce((dim + 1)..8//1, acc, fn lower, a ->
          prepend_repeated(a, Enum.at(@breaks, lower), Enum.at(ta, lower) - 1)
        end)

      {target, acc}
    else
      {loc, acc}
    end
  end

  # acc is a reversed iolist of emitted bytes; prepending a repeated
  # byte keeps the reversed invariant (all bytes identical).
  defp prepend_repeated(acc, _byte, 0), do: acc
  defp prepend_repeated(acc, byte, n), do: [List.duplicate(byte, n) | acc]

  def dephokenize(stack) do
    sorted = Enum.sort_by(stack, fn {c, _t} -> c end)

    {_loc, rev} =
      Enum.reduce(sorted, {coord_root(), []}, fn
        {_c, ""}, state ->
          state

        {c, text}, {loc, acc} ->
          {loc2, acc2} = emit_advance(loc, c, acc)
          {loc2, [Enum.reverse(:binary.bin_to_list(text)) | acc2]}
      end)

    rev |> List.flatten() |> Enum.reverse() |> :erlang.list_to_binary()
  end

  defp dephokenize_in_order(stack) do
    {_loc, rev} =
      Enum.reduce(stack, {coord_root(), []}, fn {c, text}, {loc, acc} ->
        {loc2, acc2} = emit_advance(loc, c, acc)
        {loc2, [Enum.reverse(:binary.bin_to_list(text)) | acc2]}
      end)

    rev |> List.flatten() |> Enum.reverse() |> :erlang.list_to_binary()
  end

  def normalize(buffer), do: dephokenize(phokenize(buffer))

  def fetch(buffer, coord) do
    case List.keyfind(phokenize(buffer), coord, 0) do
      {_, text} -> text
      nil -> ""
    end
  end

  defp update(buffer, coord, scroll, overwrite) do
    items = phokenize(buffer)

    {result, appended} =
      Enum.reduce(items, {[], false}, fn {c, _} = ps, {acc, appended} ->
        cmp = coord_compare(c, coord)

        cond do
          cmp > 0 and not appended -> {acc ++ [{coord, scroll}, ps], true}
          cmp == 0 and not appended ->
            merged = if overwrite, do: {coord, scroll}, else: {coord, elem(ps, 1) <> scroll}
            {acc ++ [merged], true}

          true -> {acc ++ [ps], appended}
        end
      end)

    result = if appended, do: result, else: result ++ [{coord, scroll}]
    dephokenize_in_order(result)
  end

  # insert: existing text is prepended to the inserted text.
  def insert(buffer, coord, scroll), do: update(buffer, coord, scroll, false)
  def replace(buffer, coord, scroll), do: update(buffer, coord, scroll, true)

  # remove: replace with "" then normalize -- coordinate-preserving.
  def remove(buffer, coord), do: normalize(update(buffer, coord, "", true))

  def explode(buffer), do: Map.new(phokenize(buffer))
  def implode(map), do: dephokenize(Map.to_list(map))
end

defmodule DynamicPhext do
  @moduledoc "Capacity-managed dynamic array scroll store: capacity 1,
  double when full, shrink only at quarter load."
  defstruct data: {}, n: 0, capacity: 1, resize_count: 0, elements_copied: 0, shrink_divisor: 4

  def new(buffer \\ "", shrink_divisor \\ 4) do
    if shrink_divisor < 2, do: raise("shrink_divisor must be >= 2")
    dp = %__MODULE__{data: {nil}, shrink_divisor: shrink_divisor}
    if buffer == "", do: dp, else: load(dp, buffer)
  end

  def load(dp, buffer) do
    fresh = %__MODULE__{data: {nil}, shrink_divisor: dp.shrink_divisor}
    Enum.reduce(Phext.phokenize(buffer), fresh, fn ps, acc -> push(acc, ps) end)
  end

  def length(%__MODULE__{n: n}), do: n

  defp resize(dp, new_capacity) do
    nd =
      List.to_tuple(
        Enum.map(0..(dp.n - 1)//1, fn i -> elem(dp.data, i) end) ++
          List.duplicate(nil, new_capacity - dp.n)
      )

    %__MODULE__{
      dp
      | data: nd,
        capacity: new_capacity,
        resize_count: dp.resize_count + 1,
        elements_copied: dp.elements_copied + dp.n
    }
  end

  defp grow_if_full(dp), do: if(dp.n == dp.capacity, do: resize(dp, 2 * dp.capacity), else: dp)

  defp shrink_if_sparse(dp) do
    if dp.capacity > 1 and dp.n <= div(dp.capacity, dp.shrink_divisor),
      do: resize(dp, max(1, div(dp.capacity, 2))),
      else: dp
  end

  defp push(dp, ps) do
    dp = grow_if_full(dp)
    %__MODULE__{dp | data: put_elem(dp.data, dp.n, ps), n: dp.n + 1}
  end

  def scrolls(dp), do: Enum.map(0..(dp.n - 1)//1, fn i -> elem(dp.data, i) end)
  def serialize(dp), do: Phext.dephokenize(scrolls(dp))

  defp find(dp, coord), do: find(dp.data, coord, 0, dp.n)
  defp find(_data, _coord, lo, hi) when lo >= hi, do: {lo, false}

  defp find(data, coord, lo, hi) do
    mid = div(lo + hi, 2)
    {c, _} = elem(data, mid)

    case Phext.coord_compare(c, coord) do
      -1 -> find(data, coord, mid + 1, hi)
      1 -> find(data, coord, lo, mid)
      0 -> {mid, true}
    end
  end

  def fetch(dp, coord) do
    case find(dp, coord) do
      {idx, true} -> elem(elem(dp.data, idx), 1)
      _ -> ""
    end
  end

  def contains?(dp, coord), do: elem(find(dp, coord), 1)

  def append(dp, coord, text) do
    if dp.n > 0 do
      {tail, _} = elem(dp.data, dp.n - 1)
      if Phext.coord_compare(coord, tail) <= 0,
        do: raise("append requires a coordinate past the current tail")
    end

    if text == "", do: dp, else: push(dp, {coord, text})
  end

  def update(dp, coord, text, overwrite) do
    {idx, found} = find(dp, coord)

    cond do
      found and text == "" ->
        if overwrite, do: remove_at(dp, idx), else: dp

      found ->
        {_, old} = elem(dp.data, idx)
        t = if overwrite, do: text, else: old <> text
        %__MODULE__{dp | data: put_elem(dp.data, idx, {coord, t})}

      text == "" ->
        dp

      true ->
        dp = grow_if_full(dp)

        data =
          Enum.reduce(dp.n..(idx + 1)//-1, dp.data, fn i, d ->
            put_elem(d, i, elem(d, i - 1))
          end)

        %__MODULE__{dp | data: put_elem(data, idx, {coord, text}), n: dp.n + 1}
    end
  end

  def insert(dp, coord, text), do: update(dp, coord, text, false)
  def replace(dp, coord, text), do: update(dp, coord, text, true)

  defp remove_at(dp, idx) do
    data =
      Enum.reduce(idx..(dp.n - 2)//1, dp.data, fn i, d ->
        put_elem(d, i, elem(d, i + 1))
      end)

    dp = %__MODULE__{dp | data: put_elem(data, dp.n - 1, nil), n: dp.n - 1}
    shrink_if_sparse(dp)
  end

  def remove(dp, coord) do
    case find(dp, coord) do
      {idx, true} -> remove_at(dp, idx)
      _ -> dp
    end
  end
end

defmodule BranchingMap do
  @moduledoc "A hash map of dimension `depth` branching into maps of
  one fewer dimension, recursively, down to leaves holding scroll
  text. One map lookup per dimension."
  defstruct depth: 9, root: %{}, count: 0

  def new(depth) do
    if depth < 1, do: raise("depth must be >= 1")
    %__MODULE__{depth: depth}
  end

  def length(%__MODULE__{count: n}), do: n

  def fetch(%__MODULE__{depth: depth, root: root}, key) do
    fetch_rec(root, Tuple.to_list(key), depth)
  end

  defp fetch_rec(node, [comp], 1), do: Map.get(node, comp)
  defp fetch_rec(node, [comp | rest], level) do
    case Map.fetch(node, comp) do
      {:ok, child} -> fetch_rec(child, rest, level - 1)
      :error -> nil
    end
  end

  def contains?(bm, key), do: fetch(bm, key) != nil

  def put(bm, key, value) do
    {root, created} = put_rec(bm.root, Tuple.to_list(key), bm.depth, value)
    {%__MODULE__{bm | root: root, count: bm.count + if(created, do: 1, else: 0)}, created}
  end

  defp put_rec(node, [comp], 1, value) do
    {Map.put(node, comp, value), not Map.has_key?(node, comp)}
  end

  defp put_rec(node, [comp | rest], level, value) do
    {child, created} = put_rec(Map.get(node, comp, %{}), rest, level - 1, value)
    {Map.put(node, comp, child), created}
  end

  def remove(bm, key) do
    {root, removed} = remove_rec(bm.root, Tuple.to_list(key), bm.depth)
    {%__MODULE__{bm | root: root, count: bm.count - if(removed, do: 1, else: 0)}, removed}
  end

  defp remove_rec(node, [comp], 1) do
    if Map.has_key?(node, comp), do: {Map.delete(node, comp), true}, else: {node, false}
  end

  defp remove_rec(node, [comp | rest], level) do
    case Map.fetch(node, comp) do
      :error ->
        {node, false}

      {:ok, child} ->
        {new_child, removed} = remove_rec(child, rest, level - 1)

        cond do
          removed and map_size(new_child) == 0 -> {Map.delete(node, comp), true}
          removed -> {Map.put(node, comp, new_child), true}
          true -> {node, false}
        end
    end
  end

  def items(%__MODULE__{depth: depth, root: root}) do
    items_rec(root, [], depth) |> Enum.sort()
  end

  defp items_rec(node, prefix, 1) do
    Enum.map(node, fn {comp, v} -> {List.to_tuple(prefix ++ [comp]), v} end)
  end

  defp items_rec(node, prefix, level) do
    Enum.flat_map(node, fn {comp, child} -> items_rec(child, prefix ++ [comp], level - 1) end)
  end
end

defmodule TransitivePhext do
  @moduledoc "Scroll store over a BranchingMap at depth 9."
  defstruct map: nil

  def new(buffer \\ "") do
    tp = %__MODULE__{map: BranchingMap.new(9)}
    if buffer == "", do: tp, else: load(tp, buffer)
  end

  def depth(%__MODULE__{map: m}), do: m.depth
  def length(%__MODULE__{map: m}), do: BranchingMap.length(m)

  def load(_tp, buffer) do
    Enum.reduce(Phext.phokenize(buffer), %__MODULE__{map: BranchingMap.new(9)}, fn {c, t}, acc ->
      {m, _} = BranchingMap.put(acc.map, c, t)
      %__MODULE__{acc | map: m}
    end)
  end

  def scrolls(tp), do: BranchingMap.items(tp.map)
  def serialize(tp), do: Phext.dephokenize(scrolls(tp))
  def fetch(tp, coord), do: BranchingMap.fetch(tp.map, coord) || ""
  def contains?(tp, coord), do: BranchingMap.contains?(tp.map, coord)

  def update(tp, coord, text, overwrite) do
    cond do
      text == "" ->
        if overwrite, do: remove(tp, coord), else: tp

      overwrite ->
        {m, _} = BranchingMap.put(tp.map, coord, text)
        %__MODULE__{tp | map: m}

      true ->
        {m, _} = BranchingMap.put(tp.map, coord, fetch(tp, coord) <> text)
        %__MODULE__{tp | map: m}
    end
  end

  def insert(tp, coord, text), do: update(tp, coord, text, false)
  def replace(tp, coord, text), do: update(tp, coord, text, true)
  def append(tp, coord, text), do: insert(tp, coord, text)

  def remove(tp, coord) do
    {m, _} = BranchingMap.remove(tp.map, coord)
    %__MODULE__{tp | map: m}
  end
end
