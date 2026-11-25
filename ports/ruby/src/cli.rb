# Hub-side CLI for libphext-ruby (Exocortical Telephone Game, contract v2).
#
# Transport: with no argument, stdin carries ONE JSON object and stdout
# carries ONE JSON response. With the argument `serve`, the CLI reads
# one JSON request per line and answers one JSON object per line.
# Requests carry phext state as base64 under "state" (v2) or
# "state_b64" (v1 wire compat).
#
# v2 subcommands: id, keygen, seek, echo, elect, choose (insert-only),
# apply, attest, validate, verify (stress.phext walk). v1 `fetch` and
# tar-based `verify` (game_tar_b64) remain for the v1 harness.
#
# choose — this port's own deterministic adventure rule (insert-only):
#   start from the tracked position; while the candidate coordinate
#   already holds a scroll, advance it by one scroll break. Insert
#   "ruby was here, turn N" at the first unused coordinate found.
# elect — popcorn: sha256("ruby-elect:<position>:<turn>:<candidates>")
#   picks from the candidates other than itself (when there are any).
# echo — sha256 hex of "ruby-echo:" + the ping nonce.
# attest — PGP detached armored signature (gpg, key home
#   ~/telephone-ruby/keys on the hub) over the canonical descriptor
#   JSON (sorted keys, "," / ":" separators, ASCII-escaped).
# JSON, Base64 and Digest::SHA256 are Ruby stdlib.
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'stringio'
require 'zlib'
require 'tmpdir'
require_relative 'phext'

IMPL = 'ruby'
ZERO = '0' * 64
KEY_HOME = '/home/wbic16/telephone-ruby/keys'

def sha256hex(bytes)
  Digest::SHA256.hexdigest(bytes)
end

def state_of(req)
  Base64.decode64(req['state'] || req['state_b64'])
end

def apply_step(data, step)
  op = step['op']
  coord = Phext::Coordinate.parse(step['coordinate'])
  fetch_sha = op == 'fetch' ? sha256hex(Phext.fetch(data, coord)) : nil
  return [data, fetch_sha] if %w[fetch navigate].include?(op)

  map = Phext.explode(data)
  case op
  when 'insert'
    map[coord] = (map[coord] || ''.b) + Phext.text_to_bytes(step['text'] || '')
  when 'replace'
    map[coord] = Phext.text_to_bytes(step['text'] || '')
  when 'remove'
    map.delete(coord)
  else
    raise "unknown op #{op}"
  end
  [Phext.implode(map), fetch_sha]
end

# Canonical JSON matching python json.dumps(sort_keys=True,
# separators=(",", ":"), ensure_ascii=True).
def canon(v)
  case v
  when nil then 'null'
  when true then 'true'
  when false then 'false'
  when Integer then v.to_s
  when Float then v == v.truncate ? v.truncate.to_s : v.to_s
  when String then canon_str(v)
  when Array then "[#{v.map { |x| canon(x) }.join(',')}]"
  when Hash
    keys = v.keys.map(&:to_s).sort
    "{#{keys.map { |k| "#{canon_str(k)}:#{canon(v[k])}" }.join(',')}}"
  else
    raise "cannot canonicalize #{v.class}"
  end
end

def canon_str(str)
  out = +'"'
  str.each_codepoint do |cp|
    case cp
    when 0x22 then out << '\\"'
    when 0x5C then out << '\\\\'
    when 0x0A then out << '\\n'
    when 0x0D then out << '\\r'
    when 0x09 then out << '\\t'
    when 0x08 then out << '\\b'
    when 0x0C then out << '\\f'
    when 0x20...0x7F then out << cp
    when 0x00..0xFFFF then out << format('\\u%04x', cp)
    else
      x = cp - 0x10000
      out << format('\\u%04x\\u%04x', 0xD800 + (x >> 10), 0xDC00 + (x & 0x3FF))
    end
  end
  out << '"'
end

# ------------------------------------------------------------ gpg
def gpg_run(args, home: KEY_HOME)
  FileUtils.mkdir_p(home)
  out, _err, status = Open3.capture3({ 'GNUPGHOME' => home }, 'gpg', *args)
  [status.success?, out]
end

def ensure_key
  ok, listing = gpg_run(['--batch', '--list-keys', '--with-colons'])
  unless ok && listing.include?('pub:')
    ok, = gpg_run(['--batch', '--pinentry-mode', 'loopback', '--passphrase',
                   '', '--quick-generate-key',
                   'libphext-ruby <ruby@telephone.exocortex>',
                   'ed25519', 'sign', 'never'])
    raise 'keygen failed' unless ok
  end
  ok, pubkey = gpg_run(['--batch', '--armor', '--export', 'libphext-ruby'])
  raise 'pubkey export failed' unless ok

  pubkey.strip
end

def sign_descriptor(descriptor)
  ensure_key
  Dir.mktmpdir do |dir|
    data = File.join(dir, 'descriptor.json')
    File.write(data, canon(descriptor))
    sig = File.join(dir, 'descriptor.sig')
    ok, = gpg_run(['--batch', '--yes', '--pinentry-mode', 'loopback',
                   '--passphrase', '', '--detach-sign', '--armor',
                   '--output', sig, data])
    raise 'attest signing failed' unless ok

    File.read(sig).strip
  end
end

def verify_signature(pubkeys, signature, data)
  Dir.mktmpdir do |dir|
    home = File.join(dir, 'gnupg')
    FileUtils.mkdir_p(home)
    FileUtils.chmod(0o700, home)
    keyfile = File.join(dir, 'keys.asc')
    File.write(keyfile, pubkeys)
    ok, = gpg_run(['--batch', '--import', keyfile], home: home)
    next false unless ok

    datafile = File.join(dir, 'data')
    File.binwrite(datafile, data)
    sigfile = File.join(dir, 'data.sig')
    File.write(sigfile, signature)
    ok, = gpg_run(['--batch', '--verify', sigfile, datafile], home: home)
    ok
  end
end

# ------------------------------------------------------------ seek
# Raw file I/O only: in-process directory walk + byte reads; the break
# walker runs in-process. No subprocesses, no search tools, no indexes.
def seek(root)
  target = [13] * 9
  return nil unless File.directory?(root)

  files = Dir.children(root).sort.map { |n| File.join(root, n) }
             .select { |p| File.file?(p) && p.end_with?('.phext') }
  Dir.glob(File.join(root, '**', '*.phext')).sort.each do |p|
    files << p unless files.include?(p)
  end
  files.each do |path|
    data = File.binread(path)
    coord = [1] * 9
    run_start = 0
    data.each_byte.with_index do |byte, i|
      d = Phext::BREAK_DIM[byte]
      next if d.nil?

      if coord == target && i > run_start
        text = data.byteslice(run_start, i - run_start)
        return { 'impl' => IMPL, 'path' => path, 'offset' => run_start,
                 'coordinate' => '13.13.13/13.13.13/13.13.13',
                 'title' => text.force_encoding('UTF-8').split("\n").first.strip }
      end
      coord[d] += 1
      (d + 1...9).each { |lower| coord[lower] = 1 }
      run_start = i + 1
    end
    if coord == target && data.bytesize > run_start
      text = data.byteslice(run_start, data.bytesize - run_start)
      return { 'impl' => IMPL, 'path' => path, 'offset' => run_start,
               'coordinate' => '13.13.13/13.13.13/13.13.13',
               'title' => text.force_encoding('UTF-8').split("\n").first.strip }
    end
  end
  nil
end

# ------------------------------------------------------------ v1 verify
def untar(data)
  out = {}
  off = 0
  while off + 512 <= data.bytesize
    header = data.byteslice(off, 512)
    break if header.bytes.all?(&:zero?)

    name = header.byteslice(0, 100).split("\0").first.to_s
    prefix = header.byteslice(345, 155).split("\0").first.to_s
    name = "#{prefix}/#{name}" unless prefix.empty?
    size_field = header.byteslice(124, 12).strip
    size = size_field.empty? ? 0 : size_field.to_i(8)
    type = header.getbyte(156)
    off += 512
    out[name] = data.byteslice(off, size) if type == 0x30 || type.zero?
    off += ((size + 511) / 512) * 512
  end
  out
end

def fail(n, msg)
  { 'impl' => IMPL, 'verdict' => 'fail', 'steps_checked' => n,
    'first_failure' => { 'detail' => msg } }
end

def verify_tar(tar_bytes)
  files = untar(tar_bytes)
  tkey = files.keys.find { |k| k == 'transcript.jsonl' || k.end_with?('/transcript.jsonl') }
  gkey = files.keys.find { |k| k == 'genesis.phext' || k.end_with?('/genesis.phext') }
  return fail(0, 'missing transcript/genesis') if tkey.nil? || gkey.nil?

  records = files[tkey].lines.map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) }
  return fail(0, 'empty transcript') if records.empty?

  head = ZERO
  records.each do |rec|
    return fail(0, 'chain prev mismatch') if rec['prev'] != head

    body = rec.reject { |k, _| %w[prev hash].include?(k) }
    digest = sha256hex([head].pack('H*') + canon(body))
    return fail(0, 'chain hash mismatch') if digest != rec['hash']

    head = rec['hash']
  end
  state = files[gkey]
  return fail(0, 'genesis hash mismatch') if sha256hex(state) != records[0]['genesis_sha256']

  pings = {}
  records.each { |r| pings[r['turn']] = r['nonce'] if r['type'] == 'ping' }
  echoes = Hash.new { |h, k| h[k] = [] }
  checked = 0
  records.each do |rec|
    case rec['type']
    when 'echo'
      if rec['impl'] == IMPL
        want = sha256hex("ruby-echo:#{pings[rec['turn']]}")
        return fail(checked, "own echo mismatch turn #{rec['turn']}") if want != rec['echo']
      end
      echoes[rec['turn']] << rec
    when 'handoff'
      es = echoes[rec['turn']]
      return fail(checked, 'handoff with no echoes') if es.empty?

      best = es.min_by { |e| [e['echo'], e['impl']] }
      if best['impl'] != rec['to']
        return fail(checked, "echolocation outcome mismatch turn #{rec['turn']}")
      end
    when 'turn'
      step = rec['step']
      if step['op'] == 'fetch'
        got = sha256hex(Phext.fetch(state, Phext::Coordinate.parse(step['coordinate'])))
        return fail(checked, "fetch mismatch turn #{rec['turn']}") if got != rec['fetch_sha256']
      end
      state, = apply_step(state, step)
      return fail(checked, "state mismatch turn #{rec['turn']}") if sha256hex(state) != rec['state_sha256']

      checked += 1
    end
  end
  { 'impl' => IMPL, 'verdict' => 'pass', 'steps_checked' => checked,
    'first_failure' => nil }
end

# ------------------------------------------------------------ v2 verify
def vfail(n, msg)
  { 'impl' => IMPL, 'verdict' => 'fail', 'placements_checked' => n,
    'first_failure' => { 'detail' => msg } }
end

def reserved_coord?(c)
  c.v[0, 8] == [1] * 8 && c.v[8] <= 3
end

def event_coord?(c)
  c.v[0, 6] == [1] * 6 && c.v[6] == 2 && c.v[7] == 1
end

def verify_stress(data, pubkeys_arg)
  map = Phext.explode(data)
  keys_coord = Phext::Coordinate.parse('1.1.1/1.1.1/1.1.2')
  hash_coord = Phext::Coordinate.parse('1.1.1/1.1.1/1.1.3')
  index_coord = Phext::Coordinate.parse('1.1.1/1.1.1/1.1.1')
  pubkeys = pubkeys_arg || ''
  if map.key?(keys_coord)
    inscribed = Phext.bytes_to_text(map[keys_coord])
    pubkeys = inscribed if pubkeys.empty?
    if map.key?(hash_coord)
      want = Phext.bytes_to_text(map[hash_coord]).strip
      return vfail(0, 'keys-hash scroll does not match keys scroll') if sha256hex(map[keys_coord]) != want
    end
  end
  index = {}
  if map.key?(index_coord)
    text = Phext.bytes_to_text(map[index_coord]).strip
    if !text.empty?
      if text.start_with?('{')
        JSON.parse(text).each { |k, v| index[k] = v }
      else
        text.each_line do |line|
          parts = line.strip.split(/\s+/)
          index[parts[0]] = parts[1] if parts.length == 2
        end
      end
    end
  end
  head = ZERO
  attested = {}
  checked = 0
  map.keys.select { |c| event_coord?(c) }.sort.each do |ec|
    begin
      ev = JSON.parse(Phext.bytes_to_text(map[ec]))
    rescue JSON::ParserError
      return vfail(checked, "event at #{ec} is not JSON")
    end
    return vfail(checked, "event chain prev mismatch at #{ec}") if ev['prev'] != head

    body = ev.reject { |k, _| %w[prev hash].include?(k) }
    digest = sha256hex([head].pack('H*') + canon(body))
    return vfail(checked, "event chain hash mismatch at #{ec}") if digest != ev['hash']

    head = ev['hash']
    next unless ev['type'] == 'placement'

    desc = ev['descriptor']
    coord_str = desc['coordinate']
    coord = Phext::Coordinate.parse(coord_str)
    return vfail(checked, "placement scroll missing at #{coord_str}") unless map.key?(coord)
    return vfail(checked, "placement scroll hash mismatch at #{coord_str}") if sha256hex(map[coord]) != desc['scroll_sha256']
    return vfail(checked, "index hash mismatch at #{coord_str}") if index[coord_str] != desc['scroll_sha256']

    sig = ev['signature'] || ''
    if pubkeys.empty? || !verify_signature(pubkeys, sig, canon(desc))
      return vfail(checked, "attestation signature fails at #{coord_str}")
    end

    attested[coord_str] = true
    checked += 1
  end
  map.each do |coord, text|
    next if reserved_coord?(coord) || event_coord?(coord)

    coord_str = coord.to_s
    return vfail(checked, "unindexed placement at #{coord_str}") if index[coord_str] != sha256hex(text)
    return vfail(checked, "unattested placement at #{coord_str}") unless attested[coord_str]
  end
  return vfail(checked, 'index/attestation count mismatch') if index.length != attested.length

  { 'impl' => IMPL, 'verdict' => 'pass', 'placements_checked' => checked,
    'first_failure' => nil }
end

# ------------------------------------------------------------ dispatch
def dispatch(req)
  case req['cmd']
  when 'id'
    { 'impl' => IMPL }
  when 'keygen'
    { 'impl' => IMPL, 'pubkey' => ensure_key }
  when 'seek'
    seek(req['root'] || '') || { 'impl' => IMPL, 'error' => 'not found' }
  when 'echo'
    ping = req['ping'] || req
    { 'impl' => IMPL, 'echo' => sha256hex("ruby-echo:#{ping['nonce']}") }
  when 'elect'
    candidates = req['candidates'].map(&:to_s)
    pool = candidates.reject { |c| c == IMPL }
    pool = candidates if pool.empty?
    seed = sha256hex("ruby-elect:#{req['position']}:#{req['turn']}:#{candidates.join(',')}")
    { 'elect' => pool[seed[0, 8].to_i(16) % pool.length] }
  when 'choose'
    data = state_of(req)
    map = Phext.explode(data)
    candidate = Phext::Coordinate.parse(req['position'])
    candidate = candidate.apply_break(8) while map.key?(candidate)
    { 'op' => 'insert', 'coordinate' => candidate.to_s,
      'text' => "ruby was here, turn #{req['turn']}" }
  when 'apply'
    out, = apply_step(state_of(req), req['step'])
    { 'state_b64' => Base64.strict_encode64(out),
      'state_sha256' => sha256hex(out) }
  when 'attest'
    { 'signature' => sign_descriptor(req['descriptor']) }
  when 'validate'
    data = state_of(req)
    step = req['step']
    coord = Phext::Coordinate.parse(step['coordinate'])
    map = Phext.explode(data)
    if !map.key?(coord)
      { 'impl' => IMPL, 'verdict' => 'fail',
        'detail' => "placed scroll missing at #{coord}" }
    else
      placed = map[coord]
      desc = req['descriptor']
      detail = nil
      if desc && sha256hex(placed) != desc['scroll_sha256']
        detail = 'placed scroll hash != attested scroll_sha256'
      elsif step['text'] && Phext.bytes_to_text(placed) != step['text']
        detail = 'placed scroll text != step text'
      elsif req['prior_state']
        prior_bytes = Base64.decode64(req['prior_state'])
        if desc && sha256hex(prior_bytes) != desc['prior_file_sha256']
          detail = 'prior file hash != attested prior_file_sha256'
        else
          prior = Phext.explode(prior_bytes)
          prior.each do |k, v|
            if !map.key?(k) || map[k] != v
              detail = "prior scroll overwritten or lost at #{k}"
              break
            end
          end
          if detail.nil?
            added = map.keys - prior.keys
            detail = "expected exactly one added scroll at #{coord}" if added != [coord]
          end
        end
      end
      if detail
        { 'impl' => IMPL, 'verdict' => 'fail', 'detail' => detail }
      else
        { 'impl' => IMPL, 'verdict' => 'pass',
          'detail' => 'placed scroll present at unused coordinate; no prior scroll overwritten' }
      end
    end
  when 'verify'
    if req['game_tar_b64']
      verify_tar(Base64.decode64(req['game_tar_b64']))
    else
      verify_stress(state_of(req), req['pubkeys'])
    end
  when 'fetch'
    got = Phext.fetch(state_of(req), Phext::Coordinate.parse(req['coordinate']))
    { 'text_b64' => Base64.strict_encode64(got),
      'text' => Phext.bytes_to_text(got) }
  when 'explode'
    # Hook for harness/adapter_base.py: coordinate string -> text_b64.
    map = Phext.explode(state_of(req))
    { 'map' => map.transform_keys(&:to_s)
                  .transform_values { |v| Base64.strict_encode64(v) } }
  when 'implode'
    map = {}
    req['map'].each do |k, v|
      map[Phext::Coordinate.parse(k)] = Base64.decode64(v)
    end
    out = Phext.implode(map)
    { 'state_b64' => Base64.strict_encode64(out),
      'state_sha256' => sha256hex(out) }
  when 'insert'
    # Game insert (adapter_base hook semantics): unused coord only.
    coord = Phext::Coordinate.parse(req['coordinate'])
    map = Phext.explode(state_of(req))
    if map.key?(coord)
      { 'error' => 'coordinate already occupied' }
    else
      map[coord] = Base64.decode64(req['text_b64'])
      out = Phext.implode(map)
      { 'state_b64' => Base64.strict_encode64(out),
        'state_sha256' => sha256hex(out) }
    end
  else
    raise "unknown cmd #{req['cmd']}"
  end
end

# Game-scale framing (2026-11-24): lines over 8 KB may arrive
# gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh channel
# is ~25-70 KB/s and raw base64 state lines took minutes at 1,000
# placements. Lossless; plain lines unchanged.
def gz_unframe(s)
  Zlib::GzipReader.new(StringIO.new(Base64.decode64(s[4..]))).read
end

def gz_frame(s)
  io = StringIO.new
  gz = Zlib::GzipWriter.new(io)
  gz.write(s)
  gz.close
  'GZ1:' + Base64.strict_encode64(io.string)
end

if ARGV[0] == 'serve'
  STDIN.each_line do |line|
    line = line.strip
    next if line.empty?

    begin
      line = gz_unframe(line) if line.start_with?('GZ1:')
      out = JSON.generate(dispatch(JSON.parse(line)))
      out = gz_frame(out) if out.length > 8192
      puts out
    rescue StandardError => e
      puts JSON.generate({ 'error' => e.message })
    end
    STDOUT.flush
  end
else
  puts JSON.generate(dispatch(JSON.parse(STDIN.read)))
end
