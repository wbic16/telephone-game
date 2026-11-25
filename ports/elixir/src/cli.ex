# Hub-side CLI for libphext-elixir (Exocortical Telephone Game,
# contract v2). Transport: argument `serve` = one JSON request per
# line on stdin, one response per line on stdout; no argument = ONE
# JSON object on stdin, ONE response. State crosses the wire as
# base64 under "state". Serve lines over 8 KB travel GZ1-framed:
# "GZ1:" + base64(gzip(line)). Wraps only this port's own libphext.
# JSON is hand-written (canonical form must match Python json.dumps);
# SHA-256/base64/gzip are the Erlang/Elixir standard library's; PGP
# goes through subprocess gpg with per-port GNUPGHOME
# (~/telephone-elixir/gnupg unless TELEPHONE_GNUPGHOME).

Code.require_file("phext.ex", __DIR__)

defmodule Wire do
  def sha256hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  def b64(bin), do: Base.encode64(bin)
  def unb64(s), do: Base.decode64!(s)
  def gzip(bin), do: :zlib.gzip(bin)
  def gunzip(bin), do: :zlib.gunzip(bin)

  # JSON strings are held as UTF-8 binaries; latin-1 conversion maps
  # codepoints (each <= 255 for scroll text) back to raw bytes.
  def latin1_binary(s) do
    s |> String.to_charlist() |> :erlang.list_to_binary()
  end

  def latin1_string(bin), do: :erlang.binary_to_list(bin) |> :erlang.list_to_binary()

  # ---------------- JSON parse ----------------
  def parse(bin) do
    {v, rest} = value(skip_ws(bin))
    "" = skip_ws(rest)
    v
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(s), do: s

  defp value(<<?{, rest::binary>>), do: object(skip_ws(rest), %{})
  defp value(<<?[, rest::binary>>), do: array(skip_ws(rest), [])
  defp value(<<?", rest::binary>>), do: string(rest, [])
  defp value(<<"true", rest::binary>>), do: {true, rest}
  defp value(<<"false", rest::binary>>), do: {false, rest}
  defp value(<<"null", rest::binary>>), do: {nil, rest}
  defp value(s), do: number(s, [])

  defp object(<<?}, rest::binary>>, acc), do: {acc, rest}

  defp object(s, acc) do
    {key, rest1} = value(skip_ws(s))
    <<?:, rest2::binary>> = skip_ws(rest1)
    {val, rest3} = value(skip_ws(rest2))
    acc = Map.put(acc, key, val)

    case skip_ws(rest3) do
      <<?,, rest::binary>> -> object(skip_ws(rest), acc)
      <<?}, rest::binary>> -> {acc, rest}
    end
  end

  defp array(<<?], rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp array(s, acc) do
    {val, rest} = value(skip_ws(s))

    case skip_ws(rest) do
      <<?,, rest2::binary>> -> array(skip_ws(rest2), [val | acc])
      <<?], rest2::binary>> -> {Enum.reverse([val | acc]), rest2}
    end
  end

  defp string(<<?", rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  defp string(<<?\\, ?u, a, b, c, d, rest::binary>>, acc) do
    cp = List.to_integer([a, b, c, d], 16)

    cond do
      cp >= 0xD800 and cp <= 0xDBFF ->
        case rest do
          <<?\\, ?u, e, f, g, h, rest2::binary>> ->
            lo = List.to_integer([e, f, g, h], 16)

            if lo >= 0xDC00 and lo <= 0xDFFF do
              full = 0x10000 + Bitwise.<<<(cp - 0xD800, 10) + (lo - 0xDC00)
              string(rest2, prepend_cp(acc, full))
            else
              string(rest, prepend_cp(acc, cp))
            end

          _ ->
            string(rest, prepend_cp(acc, cp))
        end

      true ->
        string(rest, prepend_cp(acc, cp))
    end
  end

  defp string(<<?\\, e, rest::binary>>, acc) do
    cp =
      case e do
        ?n -> ?\n
        ?r -> ?\r
        ?t -> ?\t
        ?b -> ?\b
        ?f -> ?\f
        other -> other
      end

    string(rest, prepend_cp(acc, cp))
  end

  defp string(bin, acc) do
    <<cp::utf8, rest::binary>> = bin
    string(rest, prepend_cp(acc, cp))
  end

  # accumulate a codepoint as reversed UTF-8 bytes
  defp prepend_cp(acc, cp) do
    bytes = <<cp::utf8>> |> :binary.bin_to_list() |> Enum.reverse()
    bytes ++ acc
  end

  defp number(<<c, rest::binary>>, acc)
       when (c >= ?0 and c <= ?9) or c in [?-, ?+, ?., ?e, ?E],
       do: number(rest, [c | acc])

  defp number(rest, acc) do
    txt = acc |> Enum.reverse() |> :erlang.list_to_binary()

    v =
      if String.contains?(txt, [".", "e", "E"]) do
        {f, ""} = Float.parse(ensure_float(txt))
        f
      else
        String.to_integer(txt)
      end

    {v, rest}
  end

  defp ensure_float(txt) do
    if String.contains?(txt, ".") do
      txt
    else
      case String.split(txt, ~r/[eE]/, parts: 2) do
        [i] -> i <> ".0"
        [i, e] -> i <> ".0e" <> e
      end
    end
  end

  # ---------------- JSON write (canonical) ----------------
  def canon(v), do: write(v)

  def write(v) when is_map(v) do
    inner =
      v
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn k -> escape(k) <> ":" <> write(Map.fetch!(v, k)) end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  def write(v) when is_list(v),
    do: "[" <> Enum.map_join(v, ",", &write/1) <> "]"

  def write(v) when is_binary(v), do: escape(v)
  def write(true), do: "true"
  def write(false), do: "false"
  def write(nil), do: "null"
  def write(v) when is_integer(v), do: Integer.to_string(v)
  def write(v) when is_float(v), do: :erlang.float_to_binary(v, [:short])

  defp escape(s) do
    inner =
      s
      |> String.codepoints()
      |> Enum.map(&escape_cp/1)
      |> Enum.join()

    "\"" <> inner <> "\""
  end

  defp escape_cp("\""), do: "\\\""
  defp escape_cp("\\"), do: "\\\\"
  defp escape_cp("\n"), do: "\\n"
  defp escape_cp("\r"), do: "\\r"
  defp escape_cp("\t"), do: "\\t"
  defp escape_cp("\b"), do: "\\b"
  defp escape_cp("\f"), do: "\\f"

  defp escape_cp(cp_str) do
    <<cp::utf8>> = cp_str

    if cp < 0x20 or cp > 0x7E do
      if cp > 0xFFFF do
        v = cp - 0x10000

        "\\u" <>
          hex4(0xD800 + Bitwise.>>>(v, 10)) <> "\\u" <> hex4(0xDC00 + Bitwise.band(v, 0x3FF))
      else
        "\\u" <> hex4(cp)
      end
    else
      cp_str
    end
  end

  defp hex4(n), do: n |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()
end

defmodule TelephoneCLI do
  @impl_name "elixir"
  @index {1, 1, 1, 1, 1, 1, 1, 1, 1}
  @keys {1, 1, 1, 1, 1, 1, 1, 1, 2}
  @kh {1, 1, 1, 1, 1, 1, 1, 1, 3}
  @evprefix [1, 1, 1, 1, 1, 1, 2, 1]

  def main(args) do
    case args do
      ["serve"] ->
        serve_loop(nil)

      _ ->
        input = IO.read(:stdio, :eof) |> String.trim()

        if input != "" do
          {out, _} = handle_line_state(input, nil)
          IO.puts(out)
        end
    end
  end

  defp serve_loop(cache) do
    case IO.gets(:stdio, "") do
      :eof ->
        :ok

      line ->
        if String.trim(line) == "" do
          serve_loop(cache)
        else
          {out, cache2} = handle_line_state(String.trim(line), cache)
          IO.puts(out)
          serve_loop(cache2)
        end
    end
  end

  defp handle_line_state(line, cache) do
    try do
      req = Wire.parse(unframe(line))
      {resp, cache2} = dispatch(req, cache)
      out = Wire.write(resp)
      framed = if byte_size(out) > 8192, do: "GZ1:" <> Wire.b64(Wire.gzip(out)), else: out
      {framed, cache2}
    rescue
      e -> {Wire.write(%{"error" => "#{inspect(e.__struct__)}: #{Exception.message(e)}"}), cache}
    end
  end

  defp unframe("GZ1:" <> rest), do: Wire.gunzip(Wire.unb64(rest))
  defp unframe(line), do: line

  defp state_of(req), do: Wire.unb64(req["state"] || req["state_b64"])

  # ---------------- gpg ----------------
  defp gnupg_home do
    home =
      System.get_env("TELEPHONE_GNUPGHOME") ||
        Path.join([System.get_env("HOME"), "telephone-#{@impl_name}", "gnupg"])

    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    home
  end

  defp run_gpg(home, args, input) do
    dir = Path.join(System.tmp_dir!(), "tel-elixir-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    in_f = Path.join(dir, "in")
    File.write!(in_f, input)
    cmd = "gpg --batch --yes " <> Enum.map_join(args, " ", &shell_quote/1) <> " < " <> shell_quote(in_f)

    result =
      case System.cmd("sh", ["-c", cmd], env: [{"GNUPGHOME", home}], stderr_to_stdout: false) do
        {out, 0} -> {:ok, out}
        {_, _} -> :error
      end

    File.rm_rf!(dir)

    case result do
      {:ok, out} -> out
      :error -> raise "gpg failed"
    end
  end

  defp shell_quote(s),
    do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp keygen do
    home = gnupg_home()
    uid = "telephone-#{@impl_name}"
    keys = run_gpg(home, ["--list-keys", "--with-colons"], "")

    unless String.contains?(keys, "pub") do
      run_gpg(
        home,
        ["--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key", uid,
         "ed25519", "sign", "never"],
        ""
      )
    end

    pub = run_gpg(home, ["--armor", "--export", uid], "")
    %{"impl" => @impl_name, "pubkey" => pub}
  end

  defp attest(descriptor) do
    home = gnupg_home()
    uid = "telephone-#{@impl_name}"

    sig =
      run_gpg(
        home,
        ["--pinentry-mode", "loopback", "--passphrase", "", "--detach-sign", "--armor", "-u", uid],
        Wire.canon(descriptor)
      )

    %{"signature" => sig}
  end

  defp verify_signature(pubkeys_text, data, sig_b64) do
    dir = Path.join(System.tmp_dir!(), "telverify-#{:erlang.unique_integer([:positive])}")
    home = Path.join(dir, "gnupg")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    sig_f = Path.join(dir, "sig.asc")
    data_f = Path.join(dir, "data")
    File.write!(sig_f, Wire.unb64(sig_b64))
    File.write!(data_f, data)
    keys_f = Path.join(dir, "keys")
    File.write!(keys_f, pubkeys_text)

    ok =
      case System.cmd("sh", ["-c", "gpg --batch --yes --import < " <> shell_quote(keys_f)],
             env: [{"GNUPGHOME", home}], stderr_to_stdout: true) do
        {_, 0} ->
          case System.cmd("sh", ["-c", "gpg --batch --yes --verify " <> shell_quote(sig_f) <> " " <> shell_quote(data_f)],
                 env: [{"GNUPGHOME", home}], stderr_to_stdout: true) do
            {_, 0} -> true
            _ -> false
          end

        _ ->
          false
      end

    File.rm_rf!(dir)
    ok
  rescue
    _ -> false
  end

  # ---------------- game ----------------
  defp do_echo(ping) do
    %{"impl" => @impl_name, "echo" => Wire.sha256hex(Wire.canon(%{"impl" => @impl_name, "ping" => ping}))}
  end

  defp do_elect(position, candidates, turn) do
    pool0 = Enum.reject(candidates, &(&1 == @impl_name))
    pool = if pool0 == [], do: candidates, else: pool0

    seed =
      Wire.sha256hex(
        "#{@impl_name}-elect:#{position}:#{turn}:#{Enum.join(candidates, ",")}"
      )

    idx = seed |> String.slice(0, 8) |> String.to_integer(16) |> rem(length(pool))
    %{"elect" => Enum.at(pool, idx)}
  end

  defp do_choose(data, position, turn) do
    m = Phext.explode(data)
    pos = bump(Phext.coord_parse(position), m)
    %{"op" => "insert", "coordinate" => Phext.coord_string(pos),
      "text" => "#{@impl_name} was here, turn #{turn}"}
  end

  defp bump(pos, m) do
    if Map.has_key?(m, pos) do
      l = Tuple.to_list(pos)
      bump(List.to_tuple(Enum.take(l, 8) ++ [Enum.at(l, 8) + 1]), m)
    else
      pos
    end
  end

  defp do_apply(data, step) do
    coord = Phext.coord_parse(step["coordinate"])
    m = Phext.explode(data)
    if Map.has_key?(m, coord), do: raise("coordinate already occupied")
    result = Phext.implode(Map.put(m, coord, Wire.latin1_binary(step["text"])))
    %{"state_b64" => Wire.b64(result), "state_sha256" => Wire.sha256hex(result)}
  end

  defp vfail(detail), do: %{"impl" => @impl_name, "verdict" => "fail", "detail" => detail}

  defp do_validate(data, step, event_coord_s, index_line, old) do
    new_map = Phext.explode(data)
    coord = Phext.coord_parse(step["coordinate"])
    ev = Phext.coord_parse(event_coord_s)
    placed = Map.get(new_map, coord)

    cond do
      placed == nil or Wire.latin1_string(placed) != step["text"] ->
        {old, vfail("placed scroll missing or altered")}

      true ->
        with :ok <- check_prior(old, new_map),
             :ok <- check_new(old, new_map, coord, ev) do
          idx = Wire.latin1_string(Map.get(new_map, @index, ""))

          if String.ends_with?(String.trim_trailing(idx, "\n"),
                 String.trim_trailing(index_line, "\n")) do
            {new_map, %{"impl" => @impl_name, "verdict" => "pass"}}
          else
            {old, vfail("index does not record the placement")}
          end
        else
          {:fail, d} -> {old, vfail(d)}
        end
    end
  end

  defp check_prior(old, new_map) do
    Enum.reduce_while(old, :ok, fn {c, t}, :ok ->
      cond do
        c == @index -> {:cont, :ok}
        Map.get(new_map, c) == t -> {:cont, :ok}
        true -> {:halt, {:fail, "prior scroll overwritten at #{Phext.coord_string(c)}"}}
      end
    end)
  end

  defp check_new(old, new_map, coord, ev) do
    Enum.reduce_while(new_map, :ok, fn {c, _}, :ok ->
      if Map.has_key?(old, c) or c == coord or c == ev,
        do: {:cont, :ok},
        else: {:halt, {:fail, "unexpected new scroll at #{Phext.coord_string(c)}"}}
    end)
  end

  defp vfail_n(n, msg) do
    %{"impl" => @impl_name, "verdict" => "fail", "placements_checked" => n,
      "first_failure" => %{"detail" => msg}}
  end

  defp do_verify(data) do
    m = Phext.explode(data)
    keys_text = Map.get(m, @keys, "")
    kh = String.trim(Wire.latin1_string(Map.get(m, @kh, "")))

    if Wire.sha256hex(keys_text) != kh do
      vfail_n(0, "keys-hash scroll does not match keys")
    else
      events =
        Enum.reduce(m, %{}, fn {c, t}, acc ->
          if Enum.take(Tuple.to_list(c), 8) == @evprefix,
            do: Map.put(acc, elem(c, 8), Wire.parse(t)),
            else: acc
        end)

      seqs = events |> Map.keys() |> Enum.sort()

      case verify_chain(seqs, events, m, keys_text, nil, %{}, 1) do
        {:ok, placements} -> verify_index(m, placements)
        {:fail, n, msg} -> vfail_n(n, msg)
      end
    end
  end

  defp verify_chain([], _e, _m, _k, _prev, placements, _exp), do: {:ok, placements}

  defp verify_chain([s | rest], events, m, keys, prev, placements, expect) do
    n = map_size(placements)

    cond do
      s != expect ->
        {:fail, n, "event seq gap at #{s}"}

      events[s]["prev"] != prev ->
        {:fail, n, "event chain broken at seq #{s}"}

      true ->
        body = events[s]["body"]
        prev2 = Wire.sha256hex(Wire.canon(body))

        if body["type"] == "placement" do
          case check_placement(body, m, keys, placements, s) do
            {:ok, p2} -> verify_chain(rest, events, m, keys, prev2, p2, expect + 1)
            {:fail, msg} -> {:fail, n, msg}
          end
        else
          verify_chain(rest, events, m, keys, prev2, placements, expect + 1)
        end
    end
  end

  defp check_placement(body, m, keys, placements, s) do
    coord = Phext.coord_parse(body["coord"])
    t = Map.get(m, coord)

    cond do
      Map.has_key?(placements, coord) ->
        {:fail, "coordinate reused at seq #{s}"}

      t == nil or Wire.sha256hex(t) != body["text_sha256"] ->
        {:fail, "placement scroll hash mismatch seq #{s}"}

      true ->
        desc = %{
          "turn" => body["turn"],
          "coordinate" => body["coord"],
          "scroll_sha256" => body["text_sha256"],
          "file_sha256" => body["file_sha256"]
        }

        if verify_signature(keys, Wire.canon(desc), body["att"]) do
          {:ok, Map.put(placements, coord, body)}
        else
          {:fail, "attestation fails at seq #{s}"}
        end
    end
  end

  defp verify_index(m, placements) do
    n = map_size(placements)
    idx_text = Wire.latin1_string(Map.get(m, @index, ""))

    lines =
      idx_text
      |> String.split("\n")
      |> Enum.reject(fn ln -> ln == "" or String.starts_with?(ln, "#") end)

    if length(lines) != n do
      vfail_n(n, "index lines != placements")
    else
      bad =
        Enum.find(lines, fn ln ->
          parts = String.split(ln, " ")
          body = Map.get(placements, Phext.coord_parse(Enum.at(parts, 1)))
          body == nil or body["text_sha256"] != Enum.at(parts, 2)
        end)

      if bad,
        do: vfail_n(n, "index hash mismatch: #{String.slice(bad, 0, 40)}"),
        else: %{"impl" => @impl_name, "verdict" => "pass", "placements_checked" => n,
                "first_failure" => nil}
    end
  end

  # ---------------- dispatch ----------------
  defp dispatch(req, cache) do
    case req["cmd"] do
      "id" -> {%{"impl" => @impl_name}, cache}
      "keygen" -> {keygen(), cache}
      "echo" -> {do_echo(req["ping"]), cache}
      "elect" -> {do_elect(req["position"], req["candidates"], req["turn"]), cache}
      "choose" -> {do_choose(state_of(req), req["position"], req["turn"]), cache}
      "apply" -> {do_apply(state_of(req), req["step"]), cache}
      "attest" -> {attest(req["descriptor"]), cache}
      "init" -> {%{"impl" => @impl_name, "verdict" => "pass"}, Phext.explode(state_of(req))}
      "validate" ->
        old = cache || raise("validate before init")
        do_validate(state_of(req), req["step"], req["event_coord"], req["index_line"], old)
          |> then(fn {new_cache, resp} -> {resp, new_cache} end)

      "verify" -> {do_verify(state_of(req)), cache}
      other -> raise "unknown cmd #{other}"
    end
  end
end

TelephoneCLI.main(System.argv())
