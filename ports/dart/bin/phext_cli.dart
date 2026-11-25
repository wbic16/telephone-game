/// Hub-side CLI for libphext-dart (Exocortical Telephone Game, contract v2).
///
/// Transport: with no argument, stdin carries ONE JSON object and stdout
/// carries ONE JSON response. With the argument `serve`, the CLI reads
/// one JSON request per line and answers one JSON object per line.
/// Requests carry phext state as base64 under "state" (v2) or
/// "state_b64" (v1 wire compat).
///
/// v2 subcommands: id, keygen, seek, echo, elect, choose (insert-only),
/// apply, attest, validate, verify (stress.phext walk). v1 `fetch` and
/// tar-based `verify` (game_tar_b64) remain for the v1 harness.
///
/// choose — this port's own deterministic adventure rule (insert-only):
///   start from the tracked position; while the candidate coordinate
///   already holds a scroll, advance it by one scroll break. Insert
///   "dart was here, turn N" at the first unused coordinate found.
/// elect — popcorn: sha256("dart-elect:<position>:<turn>:<candidates>")
///   picks from the candidates other than itself (when there are any).
/// echo — sha256 hex of "dart-echo:" + the ping nonce.
/// attest — PGP detached armored signature (gpg, key home
///   ~/telephone-dart/keys on the hub) over the canonical descriptor
///   JSON (sorted keys, "," / ":" separators, ASCII-escaped).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/phext.dart';

const String impl = 'dart';
const String zeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';
const String keyHome = '/home/wbic16/telephone-dart/keys';

Uint8List b64(String s) => base64.decode(s);
String unb64(List<int> b) => base64.encode(b);
Uint8List stateOf(Map<String, dynamic> req) =>
    b64((req['state'] ?? req['state_b64']) as String);

// ------------------------------------------------------------ game steps
Map<String, dynamic> applyStep(Uint8List data, Map<String, dynamic> step) {
  final op = step['op'] as String;
  final coord = Coordinate.parse(step['coordinate'] as String);
  String? fetchSha;
  if (op == 'fetch') {
    fetchSha = sha256Hex(fetch(data, coord));
  }
  if (op == 'fetch' || op == 'navigate') {
    return {'state': data, 'fetch_sha256': fetchSha};
  }
  final map = explode(data);
  if (op == 'insert') {
    final existing = map[coord] ?? Uint8List(0);
    map[coord] = (BytesBuilder()
          ..add(existing)
          ..add(textToBytes(step['text'] as String? ?? '')))
        .toBytes();
  } else if (op == 'replace') {
    map[coord] = textToBytes(step['text'] as String? ?? '');
  } else if (op == 'remove') {
    map.remove(coord);
  } else {
    throw ArgumentError('unknown op $op');
  }
  return {'state': implode(map), 'fetch_sha256': fetchSha};
}

// ------------------------------------------------------------ canonical JSON
// Matches python json.dumps(obj, sort_keys=True, separators=(",", ":"))
// with ensure_ascii=True, as used by the harness hash chain.
String canon(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return v.toString();
  if (v is double) {
    return v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
  }
  if (v is String) return canonString(v);
  if (v is List) return '[${v.map(canon).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${canonString(k)}:${canon(v[k])}').join(',')}}';
  }
  throw ArgumentError('cannot canonicalize $v');
}

String canonString(String s) {
  final out = StringBuffer('"');
  for (final rune in s.runes) {
    if (rune == 0x22) {
      out.write('\\"');
    } else if (rune == 0x5c) {
      out.write('\\\\');
    } else if (rune == 0x0a) {
      out.write('\\n');
    } else if (rune == 0x0d) {
      out.write('\\r');
    } else if (rune == 0x09) {
      out.write('\\t');
    } else if (rune == 0x08) {
      out.write('\\b');
    } else if (rune == 0x0c) {
      out.write('\\f');
    } else if (rune >= 0x20 && rune < 0x7f) {
      out.writeCharCode(rune);
    } else if (rune <= 0xffff) {
      out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
    } else {
      final x = rune - 0x10000;
      out.write('\\u${(0xd800 + (x >> 10)).toRadixString(16)}');
      out.write('\\u${(0xdc00 + (x & 0x3ff)).toRadixString(16)}');
    }
  }
  out.write('"');
  return out.toString();
}

Uint8List hexDecode(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ------------------------------------------------------------ minimal tar
/// Extract a USTAR tar (as produced by python tarfile USTAR_FORMAT)
/// into a path -> bytes map, in memory.
Map<String, Uint8List> untar(Uint8List data) {
  final out = <String, Uint8List>{};
  var off = 0;
  String cstr(Uint8List b, int start, int len) {
    var end = start;
    while (end < start + len && b[end] != 0) {
      end++;
    }
    return utf8.decode(b.sublist(start, end));
  }

  while (off + 512 <= data.length) {
    final header = data.sublist(off, off + 512);
    if (header.every((x) => x == 0)) break;
    var name = cstr(header, 0, 100);
    final prefix = cstr(header, 345, 155);
    if (prefix.isNotEmpty) name = '$prefix/$name';
    final sizeStr = cstr(header, 124, 12).trim();
    final size = sizeStr.isEmpty ? 0 : int.parse(sizeStr, radix: 8);
    final type = header[156];
    off += 512;
    if (type == 0x30 || type == 0) {
      out[name] = data.sublist(off, off + size);
    }
    off += (size + 511) ~/ 512 * 512;
  }
  return out;
}

// ------------------------------------------------------------ gpg
Future<ProcessResult> gpg(List<String> args, {String home = keyHome}) {
  return Process.run('gpg', args,
      environment: {'GNUPGHOME': home},
      stdoutEncoding: utf8,
      stderrEncoding: utf8);
}

Future<String> ensureKey() async {
  await Directory(keyHome).create(recursive: true);
  await Process.run('chmod', ['700', keyHome]);
  final list = await gpg(['--batch', '--list-keys', '--with-colons']);
  if (!(list.stdout as String).contains('pub:')) {
    final gen = await gpg([
      '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
      '--quick-generate-key', 'libphext-dart <dart@telephone.exocortex>',
      'ed25519', 'sign', 'never'
    ]);
    if (gen.exitCode != 0) {
      throw StateError('keygen failed: ${gen.stderr}');
    }
  }
  final exp = await gpg(['--batch', '--armor', '--export', 'libphext-dart']);
  if (exp.exitCode != 0) {
    throw StateError('pubkey export failed: ${exp.stderr}');
  }
  return (exp.stdout as String).trim();
}

Future<String> signDescriptor(Map<String, dynamic> descriptor) async {
  await ensureKey();
  final tmp = await Directory.systemTemp.createTemp('dart-attest');
  try {
    final dataFile = File('${tmp.path}/descriptor.json');
    await dataFile.writeAsString(canon(descriptor));
    final sigFile = '${tmp.path}/descriptor.sig';
    final res = await gpg([
      '--batch', '--yes', '--pinentry-mode', 'loopback', '--passphrase', '',
      '--detach-sign', '--armor', '--output', sigFile, dataFile.path
    ]);
    if (res.exitCode != 0) {
      throw StateError('attest signing failed: ${res.stderr}');
    }
    return (await File(sigFile).readAsString()).trim();
  } finally {
    await tmp.delete(recursive: true);
  }
}

Future<bool> verifySignature(String pubkeys, String signature,
    List<int> data) async {
  final tmp = await Directory.systemTemp.createTemp('dart-verify');
  final home = '${tmp.path}/gnupg';
  await Directory(home).create(recursive: true);
  await Process.run('chmod', ['700', home]);
  try {
    final keyFile = File('${tmp.path}/keys.asc')..writeAsStringSync(pubkeys);
    final imp = await gpg(['--batch', '--import', keyFile.path], home: home);
    if (imp.exitCode != 0) return false;
    final dataFile = File('${tmp.path}/data')..writeAsBytesSync(data);
    final sigFile = File('${tmp.path}/data.sig')
      ..writeAsStringSync(signature);
    final res = await gpg(
        ['--batch', '--verify', sigFile.path, dataFile.path],
        home: home);
    return res.exitCode == 0;
  } finally {
    await tmp.delete(recursive: true);
  }
}

// ------------------------------------------------------------ seek
/// Raw file I/O only: in-process directory walk + byte reads; the break
/// walker runs in-process. No subprocesses, no search tools, no indexes.
Map<String, dynamic>? seek(String root) {
  final target = List<int>.filled(9, 13);
  final files = <File>[];
  final rootDir = Directory(root);
  if (!rootDir.existsSync()) return null;
  final top = rootDir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  files.addAll(top.where((f) => f.path.endsWith('.phext')));
  final subs = rootDir.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  files.addAll(subs.where((f) =>
      f.path.endsWith('.phext') &&
      !files.any((t) => t.path == f.path)));
  for (final f in files) {
    final data = f.readAsBytesSync();
    final coord = List<int>.filled(9, 1);
    var runStart = 0;
    for (var i = 0; i <= data.length; i++) {
      final atEnd = i == data.length;
      final d = atEnd ? null : _dimOf(data[i]);
      if (atEnd || d != null) {
        if (i > runStart && _coordEq(coord, target)) {
          final text = data.sublist(runStart, i);
          final title =
              utf8.decode(text, allowMalformed: true).split('\n').first.trim();
          return {
            'impl': impl,
            'path': f.path,
            'offset': runStart,
            'coordinate': '13.13.13/13.13.13/13.13.13',
            'title': title
          };
        }
        if (atEnd) break;
        coord[d!] += 1;
        for (var l = d + 1; l < 9; l++) {
          coord[l] = 1;
        }
        runStart = i + 1;
      }
    }
  }
  return null;
}

int? _dimOf(int byte) {
  final idx = dimensionBreaks.indexOf(byte);
  return idx < 0 ? null : idx;
}

bool _coordEq(List<int> a, List<int> b) {
  for (var i = 0; i < 9; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ------------------------------------------------------------ v1 verify
Map<String, dynamic> fail(int n, String msg) => <String, dynamic>{
      'impl': impl,
      'verdict': 'fail',
      'steps_checked': n,
      'first_failure': <String, dynamic>{'detail': msg}
    };

Map<String, dynamic> verifyTar(Uint8List tarBytes) {
  final files = untar(tarBytes);
  String? findSuffix(String suffix) {
    for (final k in files.keys) {
      if (k == suffix || k.endsWith('/$suffix')) return k;
    }
    return null;
  }

  final tKey = findSuffix('transcript.jsonl');
  final gKey = findSuffix('genesis.phext');
  if (tKey == null || gKey == null) return fail(0, 'missing transcript/genesis');
  final records = <Map<String, dynamic>>[];
  for (final line in utf8.decode(files[tKey]!).split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) records.add(jsonDecode(t) as Map<String, dynamic>);
  }
  if (records.isEmpty) return fail(0, 'empty transcript');
  var head = zeroHash;
  for (final rec in records) {
    if (rec['prev'] != head) return fail(0, 'chain prev mismatch');
    final body = Map<String, dynamic>.from(rec)
      ..remove('prev')
      ..remove('hash');
    final digest =
        sha256Hex(<int>[...hexDecode(head), ...utf8.encode(canon(body))]);
    if (digest != rec['hash']) return fail(0, 'chain hash mismatch');
    head = rec['hash'] as String;
  }
  var state = files[gKey]!;
  if (sha256Hex(state) != records[0]['genesis_sha256']) {
    return fail(0, 'genesis hash mismatch');
  }
  final pings = <int, String>{};
  for (final r in records) {
    if (r['type'] == 'ping') pings[r['turn'] as int] = r['nonce'] as String;
  }
  final echoes = <int, List<Map<String, dynamic>>>{};
  var checked = 0;
  for (final rec in records) {
    final type = rec['type'];
    if (type == 'echo') {
      if (rec['impl'] == impl) {
        final want = sha256Hex(utf8.encode('dart-echo:${pings[rec['turn']]}'));
        if (want != rec['echo']) {
          return fail(checked, 'own echo mismatch turn ${rec['turn']}');
        }
      }
      echoes.putIfAbsent(rec['turn'] as int, () => []).add(rec);
    } else if (type == 'handoff') {
      final es = echoes[rec['turn']] ?? [];
      if (es.isEmpty) return fail(checked, 'handoff with no echoes');
      var best = es.first;
      for (final e in es) {
        if ((e['echo'] as String).compareTo(best['echo'] as String) < 0 ||
            (e['echo'] == best['echo'] &&
                (e['impl'] as String).compareTo(best['impl'] as String) < 0)) {
          best = e;
        }
      }
      if (best['impl'] != rec['to']) {
        return fail(
            checked, 'echolocation outcome mismatch turn ${rec['turn']}');
      }
    } else if (type == 'turn') {
      final step = (rec['step'] as Map).cast<String, dynamic>();
      if (step['op'] == 'fetch') {
        final got = sha256Hex(
            fetch(state, Coordinate.parse(step['coordinate'] as String)));
        if (got != rec['fetch_sha256']) {
          return fail(checked, 'fetch mismatch turn ${rec['turn']}');
        }
      }
      final res = applyStep(state, step);
      state = res['state'] as Uint8List;
      if (sha256Hex(state) != rec['state_sha256']) {
        return fail(checked, 'state mismatch turn ${rec['turn']}');
      }
      checked++;
    }
  }
  return <String, dynamic>{
    'impl': impl,
    'verdict': 'pass',
    'steps_checked': checked,
    'first_failure': null
  };
}

// ------------------------------------------------------------ v2 verify
Map<String, dynamic> vfail(int n, String msg) => <String, dynamic>{
      'impl': impl,
      'verdict': 'fail',
      'placements_checked': n,
      'first_failure': <String, dynamic>{'detail': msg}
    };

bool isReserved(Coordinate c) =>
    c.v[0] == 1 && c.v[1] == 1 && c.v[2] == 1 && c.v[3] == 1 && c.v[4] == 1 &&
    c.v[5] == 1 && c.v[6] == 1 && c.v[7] == 1 && c.v[8] <= 3;
bool isEvent(Coordinate c) =>
    c.v[0] == 1 && c.v[1] == 1 && c.v[2] == 1 && c.v[3] == 1 && c.v[4] == 1 &&
    c.v[5] == 1 && c.v[6] == 2 && c.v[7] == 1;

Future<Map<String, dynamic>> verifyStress(
    Uint8List data, String? pubkeysArg) async {
  final map = explode(data);
  Coordinate at(String s) => Coordinate.parse(s);
  final keysCoord = at('1.1.1/1.1.1/1.1.2');
  final keysHashCoord = at('1.1.1/1.1.1/1.1.3');
  final indexCoord = at('1.1.1/1.1.1/1.1.1');
  var pubkeys = pubkeysArg ?? '';
  if (map.containsKey(keysCoord)) {
    final inscribed = bytesToText(map[keysCoord]!);
    if (pubkeys.isEmpty) pubkeys = inscribed;
    if (map.containsKey(keysHashCoord)) {
      final want = bytesToText(map[keysHashCoord]!).trim();
      if (sha256Hex(map[keysCoord]!) != want) {
        return vfail(0, 'keys-hash scroll does not match keys scroll');
      }
    }
  }
  // index: JSON object {coord: sha256} or lines "<coord> <sha256>"
  final index = <String, String>{};
  if (map.containsKey(indexCoord)) {
    final text = bytesToText(map[indexCoord]!).trim();
    if (text.isNotEmpty) {
      if (text.startsWith('{')) {
        final obj = jsonDecode(text) as Map<String, dynamic>;
        obj.forEach((k, v) => index[k] = v as String);
      } else {
        for (final line in text.split('\n')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length == 2) index[parts[0]] = parts[1];
        }
      }
    }
  }
  // events, hash-chained, in seq order
  final eventCoords = map.keys.where(isEvent).toList()
    ..sort((a, b) => a.compareTo(b));
  var head = zeroHash;
  final attested = <String>{};
  var placementsChecked = 0;
  for (final ec in eventCoords) {
    Map<String, dynamic> ev;
    try {
      ev = jsonDecode(bytesToText(map[ec]!)) as Map<String, dynamic>;
    } catch (_) {
      return vfail(placementsChecked, 'event at $ec is not JSON');
    }
    if (ev['prev'] != head) {
      return vfail(placementsChecked, 'event chain prev mismatch at $ec');
    }
    final body = Map<String, dynamic>.from(ev)
      ..remove('prev')
      ..remove('hash');
    final digest =
        sha256Hex(<int>[...hexDecode(head), ...utf8.encode(canon(body))]);
    if (digest != ev['hash']) {
      return vfail(placementsChecked, 'event chain hash mismatch at $ec');
    }
    head = ev['hash'] as String;
    if (ev['type'] == 'placement') {
      final desc = (ev['descriptor'] as Map).cast<String, dynamic>();
      final coordStr = desc['coordinate'] as String;
      final coord = Coordinate.parse(coordStr);
      if (!map.containsKey(coord)) {
        return vfail(placementsChecked, 'placement scroll missing at $coordStr');
      }
      if (sha256Hex(map[coord]!) != desc['scroll_sha256']) {
        return vfail(
            placementsChecked, 'placement scroll hash mismatch at $coordStr');
      }
      if (index[coordStr] != desc['scroll_sha256']) {
        return vfail(placementsChecked, 'index hash mismatch at $coordStr');
      }
      final sig = ev['signature'] as String? ?? '';
      if (pubkeys.isEmpty ||
          !await verifySignature(
              pubkeys, sig, utf8.encode(canon(desc)))) {
        return vfail(
            placementsChecked, 'attestation signature fails at $coordStr');
      }
      attested.add(coordStr);
      placementsChecked++;
    }
  }
  // every non-reserved, non-event scroll is a placement and must be
  // indexed and attested exactly once (no overwritten / stray scrolls)
  for (final entry in map.entries) {
    if (isReserved(entry.key) || isEvent(entry.key)) continue;
    final coordStr = entry.key.toString();
    if (index[coordStr] != sha256Hex(entry.value)) {
      return vfail(placementsChecked, 'unindexed placement at $coordStr');
    }
    if (!attested.contains(coordStr)) {
      return vfail(placementsChecked, 'unattested placement at $coordStr');
    }
  }
  if (index.length != attested.length) {
    return vfail(placementsChecked, 'index/attestation count mismatch');
  }
  return <String, dynamic>{
    'impl': impl,
    'verdict': 'pass',
    'placements_checked': placementsChecked,
    'first_failure': null
  };
}

// ------------------------------------------------------------ dispatch
Future<Map<String, dynamic>> dispatch(Map<String, dynamic> req) async {
  final cmd = req['cmd'] as String;
  if (cmd == 'id') {
    return {'impl': impl};
  } else if (cmd == 'keygen') {
    return {'impl': impl, 'pubkey': await ensureKey()};
  } else if (cmd == 'seek') {
    final found = seek(req['root'] as String? ?? '');
    if (found == null) {
      return {'impl': impl, 'error': 'not found'};
    }
    return found;
  } else if (cmd == 'echo') {
    final ping = (req['ping'] as Map?)?.cast<String, dynamic>() ?? req;
    return {
      'impl': impl,
      'echo': sha256Hex(utf8.encode('dart-echo:${ping['nonce']}'))
    };
  } else if (cmd == 'elect') {
    final candidates =
        (req['candidates'] as List).map((e) => e.toString()).toList();
    var pool = candidates.where((c) => c != impl).toList();
    if (pool.isEmpty) pool = candidates;
    final seed = sha256Hex(utf8.encode(
        'dart-elect:${req['position']}:${req['turn']}:${candidates.join(',')}'));
    final idx = int.parse(seed.substring(0, 8), radix: 16) % pool.length;
    return {'elect': pool[idx]};
  } else if (cmd == 'choose') {
    final data = stateOf(req);
    final position = req['position'] as String;
    final turn = req['turn'] as int;
    final map = explode(data);
    var candidate = Coordinate.parse(position);
    while (map.containsKey(candidate)) {
      candidate = candidate.applyBreak(8); // scroll break
    }
    return {
      'op': 'insert',
      'coordinate': candidate.toString(),
      'text': 'dart was here, turn $turn'
    };
  } else if (cmd == 'apply') {
    final data = stateOf(req);
    final step = (req['step'] as Map).cast<String, dynamic>();
    final res = applyStep(data, step);
    final out = res['state'] as Uint8List;
    return {'state_b64': unb64(out), 'state_sha256': sha256Hex(out)};
  } else if (cmd == 'attest') {
    final desc = (req['descriptor'] as Map).cast<String, dynamic>();
    return {'signature': await signDescriptor(desc)};
  } else if (cmd == 'validate') {
    final data = stateOf(req);
    final step = (req['step'] as Map).cast<String, dynamic>();
    final coord = Coordinate.parse(step['coordinate'] as String);
    final map = explode(data);
    if (!map.containsKey(coord)) {
      return {'impl': impl, 'verdict': 'fail', 'detail': 'placed scroll missing at $coord'};
    }
    final placed = map[coord]!;
    final desc = (req['descriptor'] as Map?)?.cast<String, dynamic>();
    if (desc != null && sha256Hex(placed) != desc['scroll_sha256']) {
      return {'impl': impl, 'verdict': 'fail', 'detail': 'placed scroll hash != attested scroll_sha256'};
    }
    if (step['text'] != null &&
        bytesToText(placed) != (step['text'] as String)) {
      return {'impl': impl, 'verdict': 'fail', 'detail': 'placed scroll text != step text'};
    }
    if (req['prior_state'] != null) {
      final prior = explode(b64(req['prior_state'] as String));
      if (desc != null &&
          sha256Hex(b64(req['prior_state'] as String)) !=
              desc['prior_file_sha256']) {
        return {'impl': impl, 'verdict': 'fail', 'detail': 'prior file hash != attested prior_file_sha256'};
      }
      for (final e in prior.entries) {
        if (!map.containsKey(e.key) ||
            sha256Hex(map[e.key]!) != sha256Hex(e.value)) {
          return {
            'impl': impl,
            'verdict': 'fail',
            'detail': 'prior scroll overwritten or lost at ${e.key}'
          };
        }
      }
      final added = map.keys.where((k) => !prior.containsKey(k)).toList();
      if (added.length != 1 || added.first != coord) {
        return {'impl': impl, 'verdict': 'fail', 'detail': 'expected exactly one added scroll at $coord, got $added'};
      }
    }
    return {'impl': impl, 'verdict': 'pass', 'detail': 'placed scroll present at unused coordinate; no prior scroll overwritten'};
  } else if (cmd == 'verify') {
    if (req['game_tar_b64'] != null) {
      return verifyTar(b64(req['game_tar_b64'] as String));
    }
    return verifyStress(stateOf(req), req['pubkeys'] as String?);
  } else if (cmd == 'fetch') {
    final data = stateOf(req);
    final got = fetch(data, Coordinate.parse(req['coordinate'] as String));
    return {'text_b64': unb64(got), 'text': bytesToText(got)};
  } else if (cmd == 'explode') {
    // Hook for harness/adapter_base.py: coordinate string -> text_b64.
    final map = explode(stateOf(req));
    return {
      'map': {for (final e in map.entries) e.key.toString(): unb64(e.value)}
    };
  } else if (cmd == 'implode') {
    final input = (req['map'] as Map).cast<String, dynamic>();
    final map = <Coordinate, Uint8List>{
      for (final e in input.entries)
        Coordinate.parse(e.key): b64(e.value as String)
    };
    final out = implode(map);
    return {'state_b64': unb64(out), 'state_sha256': sha256Hex(out)};
  } else if (cmd == 'insert') {
    // Game insert (adapter_base hook semantics): place text at an
    // unused coordinate only; occupied is an error, never a merge.
    final data = stateOf(req);
    final coord = Coordinate.parse(req['coordinate'] as String);
    final map = explode(data);
    if (map.containsKey(coord)) {
      return {'error': 'coordinate already occupied'};
    }
    map[coord] = b64(req['text_b64'] as String);
    final out = implode(map);
    return {'state_b64': unb64(out), 'state_sha256': sha256Hex(out)};
  }
  throw ArgumentError('unknown cmd $cmd');
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'serve') {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      var t = line.trim();
      if (t.isEmpty) continue;
      try {
        // Game-scale framing (2026-11-24): lines over 8 KB may arrive
        // gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh
        // channel is ~25-70 KB/s and raw base64 state lines took
        // minutes at 1,000 placements. Lossless; plain lines unchanged.
        if (t.startsWith('GZ1:')) {
          t = utf8.decode(gzip.decode(base64.decode(t.substring(4))));
        }
        final req = jsonDecode(t) as Map<String, dynamic>;
        var out = jsonEncode(await dispatch(req));
        if (out.length > 8192) {
          out = 'GZ1:${base64.encode(gzip.encode(utf8.encode(out)))}';
        }
        stdout.writeln(out);
      } catch (e) {
        stdout.writeln(jsonEncode({'error': e.toString()}));
      }
      await stdout.flush();
    }
    return;
  }
  final input = await stdin.transform(utf8.decoder).join();
  final req = jsonDecode(input) as Map<String, dynamic>;
  stdout.writeln(jsonEncode(await dispatch(req)));
}
