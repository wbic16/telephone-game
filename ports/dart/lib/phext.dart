/// libphext-dart — a Dart port of libphext (0.6.1 parity).
///
/// Semantics are normative from libphext-py: a phext is a byte buffer;
/// nine dimension-break bytes walk a 9-component coordinate; scroll text
/// is a maximal run of non-break bytes (newline 0x0A is ordinary text).
/// All byte work is done on [Uint8List]; text conveniences use latin-1
/// codepoints (byte == codepoint) so byte identity is never lost, with
/// UTF-8 helpers where a real string is wanted.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Dimension breaks in dimension order (library .. scroll).
const List<int> dimensionBreaks = <int>[
  0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17
];

final Map<int, int> _breakDimension = <int, int>{
  for (var d = 0; d < 9; d++) dimensionBreaks[d]: d
};

bool isBreak(int byte) => _breakDimension.containsKey(byte);

/// A phext coordinate: 9 components, each >= 1, ordered lexicographically.
/// String form: a.b.c/d.e.f/g.h.i
class Coordinate implements Comparable<Coordinate> {
  final List<int> v; // length 9

  Coordinate(int library, int shelf, int series, int collection, int volume,
      int book, int chapter, int section, int scroll)
      : v = <int>[
          library, shelf, series, collection, volume, book, chapter, section,
          scroll
        ] {
    if (v.length != 9 || v.any((x) => x < 1)) {
      throw ArgumentError('coordinate components must all be >= 1: $v');
    }
  }

  Coordinate.fromList(List<int> parts) : v = List<int>.from(parts) {
    if (v.length != 9 || v.any((x) => x < 1)) {
      throw ArgumentError('coordinate components must all be >= 1: $v');
    }
  }

  factory Coordinate.parse(String s) {
    final groups = s.trim().split('/');
    if (groups.length != 3) {
      throw FormatException('coordinate must be a.b.c/d.e.f/g.h.i', s);
    }
    final nums = <int>[];
    for (final g in groups) {
      for (final p in g.split('.')) {
        nums.add(int.parse(p));
      }
    }
    if (nums.length != 9) {
      throw FormatException('coordinate must have exactly 9 parts', s);
    }
    return Coordinate.fromList(nums);
  }

  static Coordinate get root => Coordinate.fromList(List<int>.filled(9, 1));

  int get library => v[0];
  int get shelf => v[1];
  int get series => v[2];
  int get collection => v[3];
  int get volume => v[4];
  int get book => v[5];
  int get chapter => v[6];
  int get section => v[7];
  int get scroll => v[8];

  /// Apply a break at dimension [d]: increment component d, reset all
  /// lower components to 1. Returns a new coordinate.
  Coordinate applyBreak(int d) {
    final out = List<int>.from(v);
    out[d] += 1;
    for (var lower = d + 1; lower < 9; lower++) {
      out[lower] = 1;
    }
    return Coordinate.fromList(out);
  }

  @override
  int compareTo(Coordinate other) {
    for (var i = 0; i < 9; i++) {
      if (v[i] != other.v[i]) return v[i] < other.v[i] ? -1 : 1;
    }
    return 0;
  }

  bool operator <(Coordinate o) => compareTo(o) < 0;
  bool operator <=(Coordinate o) => compareTo(o) <= 0;
  bool operator >(Coordinate o) => compareTo(o) > 0;
  bool operator >=(Coordinate o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Coordinate && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(v);

  @override
  String toString() =>
      '${v[0]}.${v[1]}.${v[2]}/${v[3]}.${v[4]}.${v[5]}/${v[6]}.${v[7]}.${v[8]}';
}

/// A scroll of text at a coordinate. [text] is raw bytes.
class PositionedScroll {
  final Coordinate coord;
  final Uint8List text;
  PositionedScroll(this.coord, this.text);
  String get textLatin1 => latin1.decode(text);
  @override
  String toString() => '$coord: ${text.length} bytes';
}

/// Bytes for a step [text] given as a Dart string under the game's
/// latin-1 convention: codepoints < 256 map to that byte; anything
/// higher is UTF-8 encoded.
Uint8List textToBytes(String text) {
  final out = BytesBuilder();
  for (final rune in text.runes) {
    if (rune < 256) {
      out.addByte(rune);
    } else {
      out.add(utf8.encode(String.fromCharCode(rune)));
    }
  }
  return out.toBytes();
}

/// String form of raw [bytes] under the latin-1 convention.
String bytesToText(Uint8List bytes) => latin1.decode(bytes);

/// phokenize: ordered list of (coordinate, text) scrolls in [buffer].
List<PositionedScroll> phokenize(Uint8List buffer) {
  final out = <PositionedScroll>[];
  var coord = List<int>.filled(9, 1);
  var run = BytesBuilder();
  void flush() {
    if (run.length > 0) {
      out.add(PositionedScroll(
          Coordinate.fromList(coord), run.toBytes()));
      run = BytesBuilder();
    }
  }

  for (final byte in buffer) {
    final d = _breakDimension[byte];
    if (d == null) {
      run.addByte(byte);
    } else {
      flush();
      coord[d] += 1;
      for (var lower = d + 1; lower < 9; lower++) {
        coord[lower] = 1;
      }
    }
  }
  flush();
  return out;
}

Uint8List _advance(List<int> loc, Coordinate target) {
  // Mutates loc (a 9-list) up to target; returns the break bytes emitted.
  var cmp = 0;
  for (var i = 0; i < 9; i++) {
    if (loc[i] != target.v[i]) {
      cmp = loc[i] < target.v[i] ? -1 : 1;
      break;
    }
  }
  if (cmp >= 0) return Uint8List(0);
  var dim = 0;
  while (loc[dim] == target.v[dim]) {
    dim++;
  }
  final out = BytesBuilder();
  for (var i = 0; i < target.v[dim] - loc[dim]; i++) {
    out.addByte(dimensionBreaks[dim]);
  }
  loc[dim] = target.v[dim];
  for (var lower = dim + 1; lower < 9; lower++) {
    loc[lower] = 1;
  }
  for (var lower = dim + 1; lower < 9; lower++) {
    for (var i = 0; i < target.v[lower] - 1; i++) {
      out.addByte(dimensionBreaks[lower]);
    }
    loc[lower] = target.v[lower];
  }
  return out.toBytes();
}

/// dephokenize: canonical bytes for [stack] — scrolls are emitted in
/// sorted coordinate order, advancing from 1.1.1/1.1.1/1.1.1, and empty
/// scrolls contribute nothing.
Uint8List dephokenize(List<PositionedScroll> stack) {
  final sorted = List<PositionedScroll>.from(stack)
    ..sort((a, b) => a.coord.compareTo(b.coord));
  final out = BytesBuilder();
  final loc = List<int>.filled(9, 1);
  for (final ps in sorted) {
    if (ps.text.isEmpty) continue;
    out.add(_advance(loc, ps.coord));
    out.add(ps.text);
  }
  return out.toBytes();
}

/// normalize = phokenize then dephokenize (drops empties, canonical order).
Uint8List normalize(Uint8List buffer) => dephokenize(phokenize(buffer));

/// fetch: the text at [coord], or empty bytes for a gap coordinate
/// (never a control byte).
Uint8List fetch(Uint8List buffer, Coordinate coord) {
  for (final ps in phokenize(buffer)) {
    if (ps.coord == coord) return ps.text;
  }
  return Uint8List(0);
}

Uint8List _update(
    Uint8List buffer, Coordinate coord, Uint8List text, bool overwrite) {
  final items = phokenize(buffer);
  final result = <PositionedScroll>[];
  var appended = false;
  for (final ps in items) {
    if (ps.coord > coord && !appended) {
      result.add(PositionedScroll(coord, text));
      appended = true;
    }
    if (ps.coord == coord && !appended) {
      final merged = overwrite
          ? text
          : (BytesBuilder()
                ..add(ps.text)
                ..add(text))
              .toBytes();
      result.add(PositionedScroll(coord, merged));
      appended = true;
      continue;
    }
    result.add(ps);
  }
  if (!appended) result.add(PositionedScroll(coord, text));
  // Serialize without dropping a deliberately-written empty scroll's
  // advance bytes (libphext-py update semantics); normalize() cleans up.
  final out = BytesBuilder();
  final loc = List<int>.filled(9, 1);
  for (final ps in result) {
    out.add(_advance(loc, ps.coord));
    out.add(ps.text);
  }
  return out.toBytes();
}

/// insert: if a scroll exists at [coord], the new text is the existing
/// text followed by the inserted text (libphext-py prepends the existing
/// scroll to the inserted one); otherwise a scroll is created.
Uint8List insert(Uint8List buffer, Coordinate coord, Uint8List text) =>
    _update(buffer, coord, text, false);

/// replace: overwrite the scroll at [coord].
Uint8List replace(Uint8List buffer, Coordinate coord, Uint8List text) =>
    _update(buffer, coord, text, true);

/// remove: replace with "" then normalize.
Uint8List remove(Uint8List buffer, Coordinate coord) =>
    normalize(_update(buffer, coord, Uint8List(0), true));

/// explode: map form of [buffer] (coordinate -> text bytes).
Map<Coordinate, Uint8List> explode(Uint8List buffer) {
  final out = <Coordinate, Uint8List>{};
  for (final ps in phokenize(buffer)) {
    out[ps.coord] = ps.text;
  }
  return out;
}

/// implode: canonical bytes from a coordinate -> text map.
Uint8List implode(Map<Coordinate, Uint8List> map) => dephokenize(<
    PositionedScroll>[
  for (final e in map.entries) PositionedScroll(e.key, e.value)
]);

// ---------------------------------------------------------------- SHA-256
// Pure-Dart SHA-256 (FIPS 180-4); dart:core has no digest, and this port
// takes no package dependencies.
const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

String sha256Hex(List<int> data) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
    0x1f83d9ab, 0x5be0cd19
  ];
  final bitLen = data.length * 8;
  final msg = List<int>.from(data)..add(0x80);
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    msg.add((bitLen >> (8 * i)) & 0xff);
  }
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < msg.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = (msg[j] << 24) | (msg[j + 1] << 16) | (msg[j + 2] << 8) | msg[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6],
        hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g; g = f; f = e; e = (d + t1) & 0xffffffff;
      d = c; c = b; b = a; a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}
