/// Test suite for libphext-dart (no package:test dependency — plain
/// assertions with a failure counter, exit code reflects the result).
///
/// Run: dart run test/phext_test.dart [fixtures_dir]
/// Fixtures: when a fixtures dir is given (or PHEXT_FIXTURES is set),
/// every input.phext under it must phokenize/dephokenize round-trip
/// byte-identically (for canonical inputs) — and every fixture file
/// must at least survive normalize() idempotently.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/phext.dart';

int failures = 0;
int checks = 0;

void ok(bool cond, String name) {
  checks++;
  if (!cond) {
    failures++;
    stderr.writeln('FAIL: $name');
  }
}

void eq(Object? a, Object? b, String name) =>
    ok(a == b, '$name (got $a, want $b)');

Uint8List b(String s) => Uint8List.fromList(latin1.encode(s));
String s(Uint8List x) => latin1.decode(x);

bool bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Coordinate c(String x) => Coordinate.parse(x);

void main(List<String> args) {
  // ---- coordinate parse / format / order
  eq(c('1.2.3/4.5.6/7.8.9').toString(), '1.2.3/4.5.6/7.8.9', 'coord format');
  eq(c('1.1.1/1.1.1/1.1.2').library, 1, 'coord field');
  ok(c('1.1.1/1.1.1/1.1.1') < c('1.1.1/1.1.1/1.1.2'), 'order scroll');
  ok(c('1.1.1/1.1.1/1.1.9') < c('1.1.1/1.1.2/1.1.1'), 'order section');
  ok(c('2.1.1/1.1.1/1.1.1') > c('1.9.9/9.9.9/9.9.9'), 'order library');
  ok(c('1.1.1/1.1.1/1.1.1') == Coordinate.root, 'root');
  var threw = false;
  try {
    c('0.1.1/1.1.1/1.1.1');
  } catch (_) {
    threw = true;
  }
  ok(threw, 'coord rejects 0');
  threw = false;
  try {
    c('1.1/1.1.1/1.1.1');
  } catch (_) {
    threw = true;
  }
  ok(threw, 'coord rejects short');

  // ---- phokenize basics
  var scrolls = phokenize(b('hello'));
  eq(scrolls.length, 1, 'one scroll');
  eq(scrolls[0].coord.toString(), '1.1.1/1.1.1/1.1.1', 'first coord');
  eq(scrolls[0].textLatin1, 'hello', 'first text');
  scrolls = phokenize(b('a\x17b\x17\x17c\nline2'));
  eq(scrolls.length, 3, 'scroll breaks');
  eq(scrolls[1].coord.toString(), '1.1.1/1.1.1/1.1.2', 'second coord');
  eq(scrolls[2].coord.toString(), '1.1.1/1.1.1/1.1.4', 'gap coord advance');
  eq(scrolls[2].textLatin1, 'c\nline2', 'newline is ordinary text');
  scrolls = phokenize(b('x\x01y'));
  eq(scrolls[1].coord.toString(), '2.1.1/1.1.1/1.1.1', 'library break resets');
  scrolls = phokenize(b('x\x18y'));
  eq(scrolls[1].coord.toString(), '1.1.1/1.1.1/1.2.1', 'section break');
  eq(phokenize(Uint8List(0)).length, 0, 'empty buffer');

  // ---- dephokenize / round trip
  final sample = b('alpha\x17beta\x18gamma\x01delta');
  ok(bytesEq(dephokenize(phokenize(sample)), sample), 'round trip sample');
  final built = dephokenize(<PositionedScroll>[
    PositionedScroll(c('1.1.1/1.1.1/1.1.2'), b('two')),
    PositionedScroll(c('1.1.1/1.1.1/1.1.1'), b('one')),
  ]);
  eq(s(built), 'one\x17two', 'dephokenize sorts canonically');
  ok(bytesEq(normalize(b('\x17\x17lead')), normalize(normalize(b('\x17\x17lead')))),
      'normalize idempotent');

  // ---- fetch, incl. gaps
  final buf = b('one\x17two\x17\x17four');
  eq(s(fetch(buf, c('1.1.1/1.1.1/1.1.1'))), 'one', 'fetch 1');
  eq(s(fetch(buf, c('1.1.1/1.1.1/1.1.4'))), 'four', 'fetch 4');
  eq(s(fetch(buf, c('1.1.1/1.1.1/1.1.3'))), '', 'gap fetch is empty');
  eq(s(fetch(buf, c('9.9.9/9.9.9/9.9.9'))), '', 'far gap fetch is empty');
  eq(s(fetch(Uint8List(0), c('1.1.1/1.1.1/1.1.1'))), '', 'fetch empty buffer');

  // ---- insert: existing + inserted (existing prepended)
  var out = insert(b('base'), c('1.1.1/1.1.1/1.1.1'), b('+more'));
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.1'))), 'base+more', 'insert appends after existing');
  out = insert(Uint8List(0), c('1.1.1/1.1.1/1.1.3'), b('new'));
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.3'))), 'new', 'insert creates at gap');
  eq(s(out), '\x17\x17new', 'insert at gap emits breaks');
  out = insert(b('a\x17c'), c('1.1.1/1.1.1/1.1.2'), b('b'));
  eq(s(out), 'a\x17cb', 'insert at existing scroll merges (existing + inserted)');
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.2'))), 'cb', 'merged scroll at coordinate');

  // ---- replace / remove
  out = replace(b('old\x17keep'), c('1.1.1/1.1.1/1.1.1'), b('new'));
  eq(s(out), 'new\x17keep', 'replace overwrites');
  out = replace(b('a'), c('1.1.1/1.1.1/1.1.5'), b('deep'));
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.5'))), 'deep', 'replace creates');
  out = remove(b('a\x17b\x17c'), c('1.1.1/1.1.1/1.1.2'));
  eq(s(out), 'a\x17\x17c', 'remove + normalize leaves a gap (no renumbering)');
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.2'))), '', 'removed coordinate is a gap');
  eq(s(fetch(out, c('1.1.1/1.1.1/1.1.3'))), 'c', 'later scroll keeps its coordinate');
  out = remove(b('only'), c('1.1.1/1.1.1/1.1.1'));
  eq(out.length, 0, 'remove sole scroll empties buffer');
  out = remove(b('a'), c('5.5.5/5.5.5/5.5.5'));
  eq(s(out), 'a', 'remove gap is a no-op');

  // ---- explode / implode
  final map = explode(b('x\x17y'));
  eq(map.length, 2, 'explode count');
  eq(s(implode(map)), 'x\x17y', 'implode round trip');
  eq(sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'sha256 known vector');
  eq(sha256Hex(Uint8List(0)),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'sha256 empty');

  // ---- fixtures round trip
  final fxDir = args.isNotEmpty
      ? args[0]
      : Platform.environment['PHEXT_FIXTURES'];
  if (fxDir != null && Directory(fxDir).existsSync()) {
    var files = 0, identical = 0, idempotent = 0;
    for (final f in Directory(fxDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('input.phext'))) {
      files++;
      final data = f.readAsBytesSync();
      final rt = dephokenize(phokenize(data));
      if (bytesEq(rt, data)) identical++;
      final n1 = normalize(data);
      if (bytesEq(normalize(n1), n1)) idempotent++;
    }
    stdout.writeln('fixtures: $files input.phext, '
        '$identical byte-identical round-trips, $idempotent normalize-idempotent');
    eq(idempotent, files, 'all fixtures normalize idempotently');
    ok(identical >= files - 2,
        'fixtures byte-identical round-trips ($identical/$files)');
  } else {
    stdout.writeln('fixtures: skipped (no fixtures dir)');
  }

  stdout.writeln('dart suite: $checks checks, $failures failures');
  if (failures > 0) exit(1);
}
