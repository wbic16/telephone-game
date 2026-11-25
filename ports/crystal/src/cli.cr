# Hub-side CLI for libphext-crystal (Exocortical Telephone Game,
# contract v2).
#
# Transport: with the argument `serve`, stdin carries one JSON
# request per line and stdout carries one JSON response per line.
# With no argument, stdin carries ONE JSON object and stdout ONE
# response. State crosses the wire as base64 under "state".
# Serve lines over 8 KB travel GZ1-framed: "GZ1:" + base64(gzip(line)).
#
# This CLI wraps only this port's own libphext (src/phext.cr).
# JSON is hand-written here (canonical form must match the harness's
# Python json.dumps exactly); SHA-256/base64/gzip are the Crystal
# standard library's; PGP goes through subprocess gpg with a per-port
# GNUPGHOME (~/telephone-crystal/gnupg unless TELEPHONE_GNUPGHOME).

require "./phext"
require "base64"
require "digest/sha256"
require "compress/gzip"
require "file_utils"

alias JVal = Nil | Bool | Int64 | Float64 | String | Array(JVal) | Hash(String, JVal)

IMPL = "crystal"
INDEX_COORD = Array(Int64).new(9, 1i64)
KEYS_COORD = [1i64, 1, 1, 1, 1, 1, 1, 1, 2]
KH_COORD = [1i64, 1, 1, 1, 1, 1, 1, 1, 3]
EVENT_PREFIX = [1i64, 1, 1, 1, 1, 1, 2, 1]

# ---------------------------------------------------------------- JSON
class JsonParser
  def initialize(@s : String)
    @pos = 0
    @n = @s.size
  end

  def parse : JVal
    v = value
    skip_ws
    v
  end

  private def peek : Char
    @s[@pos]
  end

  private def next_ch : Char
    c = @s[@pos]
    @pos += 1
    c
  end

  private def skip_ws
    while @pos < @n && " \t\n\r".includes?(@s[@pos])
      @pos += 1
    end
  end

  private def expect(c : Char)
    got = next_ch
    raise "expected #{c} got #{got}" if got != c
  end

  private def value : JVal
    skip_ws
    case peek
    when '{' then parse_obj
    when '[' then parse_arr
    when '"' then parse_str
    when 't' then "true".each_char { |c| expect(c) }; true
    when 'f' then "false".each_char { |c| expect(c) }; false
    when 'n' then "null".each_char { |c| expect(c) }; nil
    else parse_num
    end
  end

  private def parse_obj : JVal
    expect('{')
    skip_ws
    out = {} of String => JVal
    if (peek == '}')
      next_ch
    else
      loop do
        skip_ws
        k = parse_str
        skip_ws
        expect(':')
        out[k] = value
        skip_ws
        case next_ch
        when '}' then break
        when ',' then next
        else raise "expected , or }"
        end
      end
    end
    out
  end

  private def parse_arr : JVal
    expect('[')
    skip_ws
    out = [] of JVal
    if (peek == ']')
      next_ch
    else
      loop do
        out << value
        skip_ws
        case next_ch
        when ']' then break
        when ',' then next
        else raise "expected , or ]"
        end
      end
    end
    out
  end

  private def parse_str : String
    expect('"')
    sb = String::Builder.new
    loop do
      c = next_ch
      case c
      when '"' then break
      when '\\'
        e = next_ch
        case e
        when 'n' then sb << '\n'
        when 'r' then sb << '\r'
        when 't' then sb << '\t'
        when 'b' then sb << '\b'
        when 'f' then sb << '\f'
        when 'u'
          cp = @s[@pos, 4].to_i(16)
          @pos += 4
          if cp >= 0xD800 && cp <= 0xDBFF && @s[@pos, 2] == "\\u"
            lo = @s[@pos + 2, 4].to_i(16)
            if lo >= 0xDC00 && lo <= 0xDFFF
              @pos += 6
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            end
          end
          sb << cp.chr
        else sb << e
        end
      else sb << c
      end
    end
    sb.to_s
  end

  private def parse_num : JVal
    start = @pos
    while @pos < @n && "-+0123456789.eE".includes?(@s[@pos])
      @pos += 1
    end
    txt = @s[start...@pos]
    txt.matches?(/[.eE]/) ? txt.to_f64 : txt.to_i64
  end
end

def json_escape(s : String) : String
  # Matches Python json.dumps(..., ensure_ascii=True).
  sb = String::Builder.new
  sb << '"'
  s.each_codepoint do |cp|
    case cp
    when 0x22 then sb << "\\\""
    when 0x5C then sb << "\\\\"
    when 0x0A then sb << "\\n"
    when 0x0D then sb << "\\r"
    when 0x09 then sb << "\\t"
    when 0x08 then sb << "\\b"
    when 0x0C then sb << "\\f"
    else
      if cp < 0x20 || cp > 0x7E
        if cp > 0xFFFF
          v = cp - 0x10000
          sb << sprintf("\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
        else
          sb << sprintf("\\u%04x", cp)
        end
      else
        sb << cp.chr
      end
    end
  end
  sb << '"'
  sb.to_s
end

def json_write(v : JVal) : String
  sb = String::Builder.new
  json_write_into(v, sb)
  sb.to_s
end

def json_write_into(v : JVal, sb : String::Builder)
  case v
  when Nil then sb << "null"
  when Bool then sb << v.to_s
  when Int64 then sb << v.to_s
  when Float64 then sb << v.to_s
  when String then sb << json_escape(v)
  when Hash
    sb << '{'
    v.keys.sort.each_with_index do |k, i|
      sb << ',' if i > 0
      sb << json_escape(k)
      sb << ':'
      json_write_into(v[k], sb)
    end
    sb << '}'
  when Array
    sb << '['
    v.each_with_index do |x, i|
      sb << ',' if i > 0
      json_write_into(x, sb)
    end
    sb << ']'
  end
end

def canon_bytes(v : JVal) : Bytes
  json_write(v).to_slice
end

# ---------------------------------------------------------------- util
def sha256hex(bs : Bytes) : String
  Digest::SHA256.hexdigest(bs)
end

def b64(bs : Bytes) : String
  Base64.strict_encode(bs)
end

def unb64(s : String) : Bytes
  Base64.decode(s)
end

def latin1_bytes(s : String) : Bytes
  io = IO::Memory.new
  s.each_codepoint do |cp|
    raise "latin-1 overflow" if cp > 255
    io.write_byte(cp.to_u8)
  end
  io.to_slice
end

def latin1_string(bs : Bytes) : String
  String.build do |io|
    bs.each { |b| io << b.chr }
  end
end

def utf8_string(bs : Bytes) : String
  String.new(bs)
end

def state_of(req : Hash(String, JVal)) : Bytes
  unb64((req["state"]? || req["state_b64"]).as(String))
end

def gzip_bytes(bs : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.write(bs) }
  io.to_slice
end

def gunzip_bytes(bs : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Reader.open(IO::Memory.new(bs)) { |r| IO.copy(r, io) }
  io.to_slice
end

# ---------------------------------------------------------------- gpg
def gnupg_home : String
  home = ENV["TELEPHONE_GNUPGHOME"]? || File.join(Path.home, "telephone-#{IMPL}", "gnupg")
  FileUtils.mkdir_p(home)
  File.chmod(home, 0o700)
  home
end

def run_gpg(home : String, args : Array(String), input : Bytes?) : Bytes
  in_io = IO::Memory.new(input || Bytes.empty)
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  status = Process.run("gpg", ["--batch", "--yes"] + args,
                       env: {"GNUPGHOME" => home},
                       input: in_io, output: out_io, error: err_io)
  raise "gpg failed: #{err_io.to_s}" unless status.success?
  out_io.to_slice
end

def keygen : Hash(String, JVal)
  home = gnupg_home
  uid = "telephone-#{IMPL}"
  keys = String.new(run_gpg(home, ["--list-keys", "--with-colons"], nil))
  unless keys.includes?("pub")
    run_gpg(home, ["--pinentry-mode", "loopback", "--passphrase", "",
                   "--quick-generate-key", uid, "ed25519", "sign", "never"], nil)
  end
  pub = String.new(run_gpg(home, ["--armor", "--export", uid], nil))
  return {"impl" => IMPL, "pubkey" => pub} of String => JVal
end

def attest(descriptor : JVal) : Hash(String, JVal)
  home = gnupg_home
  uid = "telephone-#{IMPL}"
  sig = run_gpg(home, ["--pinentry-mode", "loopback", "--passphrase", "",
                       "--detach-sign", "--armor", "-u", uid],
                canon_bytes(descriptor))
  return {"signature" => String.new(sig)} of String => JVal
end

def verify_signature(pubkeys_text : String, data : Bytes, sig_b64 : String) : Bool
  dir = File.tempname("telverify")
  home = File.join(dir, "gnupg")
  FileUtils.mkdir_p(home)
  File.chmod(home, 0o700)
  run = ->(args : Array(String), input : Bytes?) {
    Process.run("gpg", ["--batch", "--yes"] + args,
                env: {"GNUPGHOME" => home},
                input: IO::Memory.new(input || Bytes.empty),
                output: IO::Memory.new, error: IO::Memory.new)
  }
  return false unless run.call(["--import"], pubkeys_text.to_slice).success?
  sigfile = File.join(dir, "sig.asc")
  File.write(sigfile, unb64(sig_b64))
  run.call(["--verify", sigfile, "-"], data).success?
rescue
  false
ensure
  FileUtils.rm_rf(dir) if dir
end

# ---------------------------------------------------------------- game
class Cache
  property map : Hash(Phext::Coord, Bytes)? = nil
  property hash : String = ""
end

CACHE = Cache.new

def do_echo(ping : JVal) : Hash(String, JVal)
  return {"impl" => IMPL,
   "echo" => sha256hex(canon_bytes({"impl" => IMPL, "ping" => ping} of String => JVal))} of String => JVal
end

def do_elect(position : String, candidates : Array(JVal), turn : Int64) : Hash(String, JVal)
  names = candidates.map(&.as(String))
  pool = names.reject { |c| c == IMPL }
  pool = names if pool.empty?
  seed = sha256hex("#{IMPL}-elect:#{position}:#{turn}:#{names.join(",")}".to_slice)
  return {"elect" => pool[(seed[0, 8].to_i64(16) % pool.size)]} of String => JVal
end

def do_choose(data : Bytes, position : String, turn : Int64) : Hash(String, JVal)
  m = Phext.explode(data)
  pos = Phext.coord_parse(position)
  while m.has_key?(pos)
    pos[8] += 1
  end
  return {"op" => "insert", "coordinate" => Phext.coord_string(pos),
   "text" => "#{IMPL} was here, turn #{turn}"} of String => JVal
end

def do_apply(data : Bytes, step : Hash(String, JVal)) : Hash(String, JVal)
  coord = Phext.coord_parse(step["coordinate"].as(String))
  m = Phext.explode(data)
  raise "coordinate already occupied" if m.has_key?(coord)
  m[coord] = latin1_bytes(step["text"].as(String))
  result = Phext.implode(m)
  return {"state_b64" => b64(result), "state_sha256" => sha256hex(result)} of String => JVal
end

def do_init(data : Bytes) : Hash(String, JVal)
  CACHE.map = Phext.explode(data)
  CACHE.hash = sha256hex(data)
  return {"impl" => IMPL, "verdict" => "pass"} of String => JVal
end

def vfail(detail : String) : Hash(String, JVal)
  return {"impl" => IMPL, "verdict" => "fail", "detail" => detail} of String => JVal
end

def do_validate(data : Bytes, step : Hash(String, JVal),
                event_coord_s : String, index_line : String) : Hash(String, JVal)
  new_map = Phext.explode(data)
  coord = Phext.coord_parse(step["coordinate"].as(String))
  ev = Phext.coord_parse(event_coord_s)
  old = CACHE.map.not_nil!
  placed = new_map[coord]?
  return vfail("placed scroll missing or altered") if placed.nil? || latin1_string(placed) != step["text"].as(String)
  old.each do |c, t|
    next if c == INDEX_COORD
    nv = new_map[c]?
    return vfail("prior scroll overwritten at #{Phext.coord_string(c)}") if nv.nil? || nv != t
  end
  new_map.each_key do |c|
    if !old.has_key?(c) && c != coord && c != ev
      return vfail("unexpected new scroll at #{Phext.coord_string(c)}")
    end
  end
  idx = latin1_string(new_map[INDEX_COORD]? || Bytes.empty)
  unless idx.rstrip('\n').ends_with?(index_line.rstrip('\n'))
    return vfail("index does not record the placement")
  end
  CACHE.map = new_map
  CACHE.hash = sha256hex(data)
  return {"impl" => IMPL, "verdict" => "pass"} of String => JVal
end

def vfail_n(n : Int32, msg : String) : Hash(String, JVal)
  return {"impl" => IMPL, "verdict" => "fail", "placements_checked" => n.to_i64,
   "first_failure" => ({"detail" => msg} of String => JVal)} of String => JVal
end

def do_verify(data : Bytes) : Hash(String, JVal)
  m = Phext.explode(data)
  keys_text = utf8_string(m[KEYS_COORD]? || Bytes.empty)
  if sha256hex(keys_text.to_slice) != latin1_string(m[KH_COORD]? || Bytes.empty).strip
    return vfail_n(0, "keys-hash scroll does not match keys")
  end
  events = {} of Int64 => Hash(String, JVal)
  m.each do |c, t|
    events[c[8]] = JsonParser.new(utf8_string(t)).parse.as(Hash(String, JVal)) if c[0, 8] == EVENT_PREFIX
  end
  prev_hash = nil.as(String?)
  placements = {} of Phext::Coord => Hash(String, JVal)
  seqs = events.keys.sort
  seqs.each_with_index do |s, i|
    return vfail_n(placements.size, "event seq gap at #{s}") if s != i + 1
    ev = events[s]
    return vfail_n(placements.size, "event chain broken at seq #{s}") if ev["prev"]? != prev_hash
    body = ev["body"].as(Hash(String, JVal))
    prev_hash = sha256hex(canon_bytes(body))
    next unless body["type"]? == "placement"
    coord = Phext.coord_parse(body["coord"].as(String))
    return vfail_n(placements.size, "coordinate reused at seq #{s}") if placements.has_key?(coord)
    t = m[coord]?
    if t.nil? || sha256hex(t) != body["text_sha256"].as(String)
      return vfail_n(placements.size, "placement scroll hash mismatch seq #{s}")
    end
    desc = {"turn" => body["turn"], "coordinate" => body["coord"],
            "scroll_sha256" => body["text_sha256"],
            "file_sha256" => body["file_sha256"]} of String => JVal
    unless verify_signature(keys_text, canon_bytes(desc), body["att"].as(String))
      return vfail_n(placements.size, "attestation fails at seq #{s}")
    end
    placements[coord] = body
  end
  idx_lines = latin1_string(m[INDEX_COORD]? || Bytes.empty).lines.reject { |ln| ln.empty? || ln.starts_with?("#") }
  return vfail_n(placements.size, "index lines != placements") if idx_lines.size != placements.size
  idx_lines.each do |ln|
    parts = ln.split(" ", 4)
    body = placements[Phext.coord_parse(parts[1])]?
    if body.nil? || body["text_sha256"] != parts[2]
      return vfail_n(placements.size, "index hash mismatch: #{ln[0, 40]}")
    end
  end
  return {"impl" => IMPL, "verdict" => "pass",
   "placements_checked" => placements.size.to_i64,
   "first_failure" => nil} of String => JVal
end

# ---------------------------------------------------------------- dispatch
def dispatch(req : Hash(String, JVal)) : Hash(String, JVal)
  case req["cmd"].as(String)
  when "id" then {"impl" => IMPL} of String => JVal
  when "keygen" then keygen
  when "echo" then do_echo(req["ping"])
  when "elect"
    do_elect(req["position"].as(String), req["candidates"].as(Array(JVal)), req["turn"].as(Int64))
  when "choose"
    do_choose(state_of(req), req["position"].as(String), req["turn"].as(Int64))
  when "apply" then do_apply(state_of(req), req["step"].as(Hash(String, JVal)))
  when "attest" then attest(req["descriptor"])
  when "init" then do_init(state_of(req))
  when "validate"
    do_validate(state_of(req), req["step"].as(Hash(String, JVal)),
                req["event_coord"].as(String), req["index_line"].as(String))
  when "verify" then do_verify(state_of(req))
  else raise "unknown cmd #{req["cmd"]}"
  end
end

def handle_line(line : String) : String
  req = JsonParser.new(line).parse.as(Hash(String, JVal))
  resp = json_write(dispatch(req))
  resp.size > 8192 ? "GZ1:#{b64(gzip_bytes(resp.to_slice))}" : resp
rescue ex
  json_write({"error" => "#{ex.class}: #{ex.message}"} of String => JVal)
end

def unframe(line : String) : String
  line.starts_with?("GZ1:") ? String.new(gunzip_bytes(unb64(line[4..]))) : line
end

if ARGV.includes?("serve")
  STDIN.each_line do |line|
    next if line.blank?
    puts handle_line(unframe(line.strip))
    STDOUT.flush
  end
else
  text = STDIN.gets_to_end.strip
  puts handle_line(unframe(text)) unless text.empty?
end
