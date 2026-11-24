## telephone.nim - Exocortical Telephone Game CLI (contract v2) for the
## Nim libphext port. Wire: one JSON request in, one response out;
## arg "serve" loops over JSON lines. PGP via this language's own
## subprocess gpg calls (osproc), key home $TELEPHONE_GNUPG_HOME or
## ~/telephone-nim/gnupg.
import std/[json, base64, strutils, os, osproc, tables, algorithm, tempfiles, streams]
import phext
import wire

const IMPL = "nim"
const KEY_UID = "libphext telephone " & IMPL
const INDEX_COORD = "1.1.1/1.1.1/1.1.1"
const KEYS_COORD = "1.1.1/1.1.1/1.1.2"
const KEYS_HASH_COORD = "1.1.1/1.1.1/1.1.3"
const RESERVED = [INDEX_COORD, KEYS_COORD, KEYS_HASH_COORD]

proc stateBytes(req: JsonNode): string =
  let s = if req.hasKey("state"): req["state"].getStr()
          elif req.hasKey("state_b64"): req["state_b64"].getStr()
          else: ""
  return decode(s)

proc trim(s: string): string = s.strip()

# ---- gpg via subprocess ----
proc gnupgHome(): string =
  let e = getEnv("TELEPHONE_GNUPG_HOME")
  if e.len > 0: return e
  return getHomeDir() / ("telephone-" & IMPL) / "gnupg"

proc runGpg(args: seq[string], input: string = ""): string =
  let home = gnupgHome()
  createDir(home)
  setFilePermissions(home, {fpUserRead, fpUserWrite, fpUserExec})
  var all = @["--batch", "--yes", "--pinentry-mode", "loopback",
              "--passphrase", "", "--homedir", home] & args
  let p = startProcess("gpg", args = all, options = {poUsePath})
  if input.len > 0:
    p.inputStream.write(input)
    p.inputStream.flush()
  p.inputStream.close()
  result = p.outputStream.readAll()
  let err = p.errorStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0:
    raise newException(IOError, "gpg " & args.join(" ") & " failed: " & err)

proc keygen(): string =
  let listing = runGpg(@["--list-keys", "--with-colons"])
  if not listing.contains("\npub:") and not listing.startsWith("pub:"):
    discard runGpg(@["--quick-gen-key", KEY_UID, "ed25519", "sign", "never"])
  return runGpg(@["--armor", "--export", KEY_UID])

proc detachSign(data: string): string =
  let dir = createTempDir("tel-nim-", "")
  try:
    writeFile(dir / "descriptor.json", data)
    discard runGpg(@["--detach-sign", "--armor", "--local-user", KEY_UID,
                     "--output", dir / "descriptor.asc", dir / "descriptor.json"])
    return readFile(dir / "descriptor.asc")
  finally:
    removeDir(dir)

proc verifySignature(pubkeys, data, signature: string): bool =
  let dir = createTempDir("tel-nim-v-", "")
  try:
    let home = dir / "gnupg"
    createDir(home)
    setFilePermissions(home, {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(dir / "keys.asc", pubkeys)
    writeFile(dir / "descriptor.json", data)
    writeFile(dir / "descriptor.asc", signature)
    var rc = execCmd("gpg --batch --yes --homedir " & quoteShell(home) &
                     " --import " & quoteShell(dir / "keys.asc") & " >/dev/null 2>&1")
    if rc != 0: return false
    rc = execCmd("gpg --batch --yes --homedir " & quoteShell(home) &
                 " --verify " & quoteShell(dir / "descriptor.asc") & " " &
                 quoteShell(dir / "descriptor.json") & " >/dev/null 2>&1")
    return rc == 0
  finally:
    removeDir(dir)

# ---- game logic ----
proc echoValue(ping: JsonNode): string =
  let game = if ping.hasKey("game"): ping["game"].getStr() else: ""
  var round = ""
  if ping.hasKey("round"): round = $ping["round"]
  elif ping.hasKey("turn"): round = $ping["turn"]
  let nonce = if ping.hasKey("nonce"): ping["nonce"].getStr() else: ""
  return sha256Hex(IMPL & "|" & game & "|" & round.strip(chars = {'"'}) & "|" & nonce)

proc seedByte(hex: string, i: int): int =
  return parseHexInt(hex[i*2..i*2+1])

proc electWinner(position: string, candidates: seq[string], turn: int): string =
  var seedStr = position & chr(turn mod 256) & candidates.join(",")
  let hex = sha256Hex(seedStr)
  return candidates[seedByte(hex, 0) mod candidates.len]

proc nextCoord(c: Coord): Coord =
  result = c
  for d in countdown(8, 0):
    if result[d] < 999:
      result[d] += 1
      return
    result[d] = 1

proc chooseAdventure(state, position: string, turn: int): JsonNode =
  let (ok, pos) = parseCoordinate(position)
  if not ok: raise newException(ValueError, "invalid position " & position)
  var used = explode(state)
  for r in RESERVED: used[r] = "\x00"
  let hex = sha256Hex(position & chr(turn mod 256) & state)
  # seed bytes from hex digest: byte1/byte2 like the perl port's raw seed
  let b1 = seedByte(hex, 1)
  let b2 = seedByte(hex, 2)
  var cand = pos
  let dim = b1 mod 9
  cand[dim] = (cand[dim] - 1 + 1 + (b2 mod 3)) mod 999 + 1
  while used.hasKey(formatCoordinate(cand)):
    cand = nextCoord(cand)
  let cs = formatCoordinate(cand)
  return %*{"op": "insert", "coordinate": cs,
            "text": IMPL & " turn " & $turn & " at " & cs}

proc applyStep(state: string, step: JsonNode): tuple[state: string, fetchHash: JsonNode] =
  let (ok, coord) = parseCoordinate(step{"coordinate"}.getStr())
  if not ok: return (state, newJNull())
  let text = step{"text"}.getStr()
  let op = step{"op"}.getStr()
  case op
  of "insert": return (insert(state, coord, text), newJNull())
  of "replace": return (replace(state, coord, text), newJNull())
  of "remove": return (remove(state, coord), newJNull())
  of "fetch": return (state, newJString(sha256Hex(fetch(state, coord))))
  else: return (state, newJNull())

proc validateStep(newState: string, step: JsonNode, prior: string, hasPrior: bool): JsonNode =
  proc fail(detail: string): JsonNode =
    %*{"impl": IMPL, "verdict": "fail", "detail": detail}
  if step{"op"}.getStr() != "insert": return fail("step op is not insert")
  let (ok, coord) = parseCoordinate(step{"coordinate"}.getStr())
  if not ok: return fail("unparseable coordinate")
  if fetch(newState, coord) != step{"text"}.getStr():
    return fail("placed scroll absent or content differs at " & step{"coordinate"}.getStr())
  if hasPrior:
    if fetch(prior, coord) != "":
      return fail("coordinate was not unused in the prior state")
    let before = explode(prior)
    let afterM = explode(newState)
    if afterM.len != before.len + 1:
      return fail("scroll count did not grow by exactly one")
    for c, t in before:
      if not afterM.hasKey(c) or afterM[c] != t:
        return fail("a prior scroll was overwritten: " & c)
    return %*{"impl": IMPL, "verdict": "pass",
              "detail": "placed at unused coordinate; all prior scrolls intact"}
  return %*{"impl": IMPL, "verdict": "pass",
            "detail": "placed scroll present with attested content (no prior state supplied)"}

# ---- serve-mode validator cache (init / driver-form validate) ----
var cacheMap: Table[string, string]
var cacheSet = false

proc initCache(state: string): JsonNode =
  cacheMap = explode(state)
  cacheSet = true
  return %*{"impl": IMPL, "verdict": "pass"}

proc validateDriver(newState: string, step: JsonNode, eventCoordS, indexLine: string): JsonNode =
  proc fail(detail: string): JsonNode =
    %*{"impl": IMPL, "verdict": "fail", "detail": detail}
  if not cacheSet: return fail("no prior state (init not called)")
  let newMap = explode(newState)
  let (ok, coord) = parseCoordinate(step{"coordinate"}.getStr())
  if not ok: return fail("unparseable coordinate")
  let coordS = formatCoordinate(coord)
  if newMap.getOrDefault(coordS, "\x00missing") != step{"text"}.getStr():
    return fail("placed scroll missing or altered")
  for c, text in cacheMap:
    if c == INDEX_COORD: continue
    if newMap.getOrDefault(c, "\x00missing") != text:
      return fail("prior scroll overwritten at " & c)
  for c in newMap.keys:
    if not cacheMap.hasKey(c) and c != coordS and c != eventCoordS:
      return fail("unexpected new scroll at " & c)
  let idx = newMap.getOrDefault(INDEX_COORD, "")
  if not idx.strip(leading = false, trailing = true, chars = {'\n'}).endsWith(
      indexLine.strip(leading = false, trailing = true, chars = {'\n'})):
    return fail("index does not record the placement")
  cacheMap = newMap
  return %*{"impl": IMPL, "verdict": "pass"}

proc verifyGame(state, pubkeys: string): JsonNode =
  proc fail(msg: string, checked: int): JsonNode =
    %*{"impl": IMPL, "verdict": "fail", "placements_checked": checked,
       "first_failure": {"detail": msg}}
  let scrolls = explode(state)
  let keysText = scrolls.getOrDefault(KEYS_COORD, "")
  if keysText.len == 0: return fail("no public-keys scroll at " & KEYS_COORD, 0)
  if trim(pubkeys) != trim(keysText):
    return fail("supplied pubkeys do not match the inscribed keys scroll", 0)
  if not scrolls.hasKey(KEYS_HASH_COORD):
    return fail("no keys-hash scroll at " & KEYS_HASH_COORD, 0)
  let kh = trim(scrolls[KEYS_HASH_COORD])
  if kh != sha256Hex(keysText):
    return fail("keys-hash scroll does not match the keys scroll", 0)
  var index = initTable[string, tuple[turn, hash, actor: string]]()
  for rawLine in (scrolls.getOrDefault(INDEX_COORD, "")).splitLines():
    let line = trim(rawLine)
    if line.len == 0 or line.startsWith("#"): continue
    let flds = line.splitWhitespace()
    if flds.len != 4: return fail("malformed index line: " & line, 0)
    index[flds[1]] = (flds[0], flds[2], flds[3])
  var checked = 0
  var seen = initTable[string, bool]()
  var prevHash = ""
  var seq = 1
  while true:
    var ec: Coord = [1,1,1,1,1,1,2,1,seq]
    let ecoord = formatCoordinate(ec)
    if not scrolls.hasKey(ecoord): break
    var ev: JsonNode
    try:
      ev = parseJson(scrolls[ecoord])
    except CatchableError:
      return fail("event " & $seq & " is not a JSON object", checked)
    if ev.kind != JObject or not ev.hasKey("body") or ev["body"].kind != JObject:
      return fail("event " & $seq & " is not a JSON object", checked)
    let body = ev["body"]
    if seq == 1:
      if ev.hasKey("prev") and ev["prev"].kind != JNull:
        return fail("event 1 prev is not null", checked)
    else:
      if not ev.hasKey("prev") or ev["prev"].getStr() != prevHash:
        return fail("event chain broken at seq " & $seq, checked)
    prevHash = sha256Hex(canon(body))
    if body{"type"}.getStr() == "placement":
      let coordStr = body{"coord"}.getStr()
      let textHash = body{"text_sha256"}.getStr()
      let fileHash = body{"file_sha256"}.getStr()
      let attB64 = body{"att"}.getStr()
      if coordStr.len == 0 or textHash.len == 0 or fileHash.len == 0 or attB64.len == 0:
        return fail("event " & $seq & " lacks coord/text_sha256/file_sha256/att", checked)
      if seen.hasKey(coordStr): return fail("coordinate reused at " & coordStr, checked)
      if not scrolls.hasKey(coordStr): return fail("placement missing at " & coordStr, checked)
      if sha256Hex(scrolls[coordStr]) != textHash:
        return fail("placement hash mismatch at " & coordStr, checked)
      if not index.hasKey(coordStr):
        return fail("index mismatch at " & coordStr, checked)
      let ie = index[coordStr]
      if ie.hash != textHash or ie.turn != $body{"turn"}.getInt() or
         ie.actor != body{"actor"}.getStr():
        return fail("index mismatch at " & coordStr, checked)
      let desc = %*{"turn": body{"turn"}.getInt(), "coordinate": coordStr,
                    "scroll_sha256": textHash, "file_sha256": fileHash}
      let signature = decode(attB64)
      if not verifySignature(pubkeys, canon(desc), signature):
        return fail("event " & $seq & " signature invalid", checked)
      seen[coordStr] = true
      checked += 1
    seq += 1
  if checked == 0: return fail("no placement events found", 0)
  for cs in index.keys:
    if not seen.hasKey(cs):
      return fail("index lists a placement with no event: " & cs, checked)
  return %*{"impl": IMPL, "verdict": "pass", "placements_checked": checked,
            "first_failure": newJNull()}

proc handle(req: JsonNode): JsonNode =
  let cmd = req{"cmd"}.getStr()
  case cmd
  of "id": return %*{"impl": IMPL}
  of "echo": return %*{"impl": IMPL, "echo": echoValue(req{"ping"})}
  of "elect":
    var cands: seq[string]
    for c in req{"candidates"}.getElems(): cands.add(c.getStr())
    if cands.len == 0: raise newException(ValueError, "elect: no candidates")
    return %*{"elect": electWinner(req{"position"}.getStr(), cands, req{"turn"}.getInt())}
  of "choose":
    return chooseAdventure(stateBytes(req), req{"position"}.getStr(), req{"turn"}.getInt())
  of "apply":
    let (ns, fh) = applyStep(stateBytes(req), req{"step"})
    return %*{"state_b64": encode(ns), "state_sha256": sha256Hex(ns), "fetch_sha256": fh}
  of "keygen": return %*{"impl": IMPL, "pubkey": keygen()}
  of "attest": return %*{"signature": detachSign(canon(req{"descriptor"}))}
  of "init": return initCache(stateBytes(req))
  of "validate":
    if req.hasKey("event_coord") and req["event_coord"].kind != JNull:
      return validateDriver(stateBytes(req), req{"step"},
                              req{"event_coord"}.getStr(), req{"index_line"}.getStr())
    let hasPrior = req.hasKey("prior_state") and req["prior_state"].kind != JNull
    let prior = if hasPrior: decode(req["prior_state"].getStr()) else: ""
    return validateStep(stateBytes(req), req{"step"}, prior, hasPrior)
  of "verify": return verifyGame(stateBytes(req), req{"pubkeys"}.getStr())
  else: raise newException(ValueError, "unknown cmd " & cmd)

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "serve":
    for line in stdin.lines:
      if line.strip().len == 0: continue
      var resp: JsonNode
      try:
        resp = handle(parseJson(line))
      except CatchableError as e:
        resp = %*{"error": e.msg}
      stdout.write(canon(resp) & "\n")
      stdout.flushFile()
  else:
    let raw = stdin.readAll()
    let req = parseJson(raw)
    stdout.write(canon(handle(req)) & "\n")
