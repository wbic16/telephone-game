// partial
/* libphext-hack -- libphext 0.6.1 parity + contract-v2 adapter CLI
 * in Hack (HHVM 4.172.1). Strings are byte strings throughout.
 * REMOVE IS COORDINATE-PRESERVING (explicitly tested).
 * The CLI is stateless: one invocation handles one request file and
 * writes one response file; the hub runner owns GZ1 framing and the
 * port GNUPGHOME. */

function break_dim(int $b): int {
  switch ($b) {
    case 1: return 0;
    case 31: return 1;
    case 30: return 2;
    case 29: return 3;
    case 28: return 4;
    case 26: return 5;
    case 25: return 6;
    case 24: return 7;
    case 23: return 8;
    default: return -1;
  }
}

function break_byte(int $d): string {
  $t = vec[1, 31, 30, 29, 28, 26, 25, 24, 23];
  return chr($t[$d]);
}

function coord_str(vec<int> $c): string {
  return $c[0].'.'.$c[1].'.'.$c[2].'/'.$c[3].'.'.$c[4].'.'.$c[5].'/'.
    $c[6].'.'.$c[7].'.'.$c[8];
}

function parse_coord(string $s): vec<int> {
  $parts = explode('/', $s);
  if (count($parts) !== 3) return vec[];
  $nums = vec[];
  foreach ($parts as $g) {
    $gp = explode('.', $g);
    if (count($gp) !== 3) return vec[];
    foreach ($gp as $n) {
      if ($n === '' || !ctype_digit($n)) return vec[];
      $nums[] = (int)$n;
    }
  }
  if (count($nums) !== 9) return vec[];
  foreach ($nums as $n) {
    if ($n < 1) return vec[];
  }
  return $nums;
}

function coord_cmp(vec<int> $a, vec<int> $b): int {
  for ($i = 0; $i < 9; $i++) {
    if ($a[$i] !== $b[$i]) return $a[$i] < $b[$i] ? -1 : 1;
  }
  return 0;
}

/* explode: vec of dict{coord: vec<int>, text: string} in file order.
 * A run is maximal non-break text at the current coordinate; a break
 * byte increments its dimension and resets all lower dims to 1. */
function phext_explode(string $data): vec<dict<string, mixed>> {
  $out = vec[];
  $coord = vec[1, 1, 1, 1, 1, 1, 1, 1, 1];
  $run_start = -1;
  $len = strlen($data);
  for ($i = 0; $i < $len; $i++) {
    $d = break_dim(ord($data[$i]));
    if ($d >= 0) {
      if ($run_start >= 0) {
        $out[] = dict['coord' => $coord,
                      'text' => substr($data, $run_start, $i - $run_start)];
        $run_start = -1;
      }
      $coord[$d] = $coord[$d] + 1;
      for ($k = $d + 1; $k < 9; $k++) $coord[$k] = 1;
    } else {
      if ($run_start < 0) $run_start = $i;
    }
  }
  if ($run_start >= 0) {
    $out[] = dict['coord' => $coord,
                  'text' => substr($data, $run_start, $len - $run_start)];
  }
  return $out;
}

function sort_entries(vec<dict<string, mixed>> $sc): vec<dict<string, mixed>> {
  $n = count($sc);
  if ($n < 2) return $sc;
  $gap = (int)($n / 2);
  while ($gap > 0) {
    for ($i = $gap; $i < $n; $i++) {
      $tmp = $sc[$i];
      $j = $i;
      while ($j >= $gap &&
             coord_cmp($sc[$j - $gap]['coord'] as vec<int>,
                       $tmp['coord'] as vec<int>) > 0) {
        $sc[$j] = $sc[$j - $gap];
        $j -= $gap;
      }
      $sc[$j] = $tmp;
    }
    $gap = (int)($gap / 2);
  }
  return $sc;
}

/* implode: canonical serialization. Empty texts are skipped; gaps
 * between coordinates are emitted as break runs (the gap survives:
 * remove is coordinate-preserving). */
function phext_implode(vec<dict<string, mixed>> $sc_in): string {
  $sc = sort_entries($sc_in);
  $out = '';
  $loc = vec[1, 1, 1, 1, 1, 1, 1, 1, 1];
  foreach ($sc as $e) {
    $coord = $e['coord'] as vec<int>;
    $text = $e['text'] as string;
    if ($text === '') continue;
    if (coord_cmp($loc, $coord) < 0) {
      $dim = 0;
      while ($loc[$dim] === $coord[$dim]) $dim++;
      for ($r = 0; $r < $coord[$dim] - $loc[$dim]; $r++) {
        $out .= break_byte($dim);
      }
      for ($k = $dim + 1; $k < 9; $k++) {
        for ($r = 0; $r < $coord[$k] - 1; $r++) {
          $out .= break_byte($k);
        }
      }
      $loc = $coord;
    }
    $out .= $text;
  }
  return $out;
}

function phext_fetch(string $data, vec<int> $coord): string {
  foreach (phext_explode($data) as $e) {
    if (coord_cmp($e['coord'] as vec<int>, $coord) === 0) {
      return $e['text'] as string;
    }
  }
  return '';
}

function phext_update(string $data, vec<int> $coord, string $text,
                      bool $overwrite): string {
  $sc = phext_explode($data);
  $out = vec[];
  $done = false;
  foreach ($sc as $e) {
    if (coord_cmp($e['coord'] as vec<int>, $coord) === 0) {
      $done = true;
      if ($overwrite) {
        if ($text !== '') {
          $out[] = dict['coord' => $coord, 'text' => $text];
        }
      } else {
        $out[] = dict['coord' => $coord,
                      'text' => ($e['text'] as string).$text];
      }
    } else {
      $out[] = $e;
    }
  }
  if (!$done && $text !== '') {
    $out[] = dict['coord' => $coord, 'text' => $text];
  }
  return phext_implode($out);
}

function phext_insert(string $data, vec<int> $coord, string $text): string {
  return phext_update($data, $coord, $text, false);
}

function phext_replace(string $data, vec<int> $coord, string $text): string {
  return phext_update($data, $coord, $text, true);
}

function phext_remove(string $data, vec<int> $coord): string {
  $out = vec[];
  foreach (phext_explode($data) as $e) {
    if (coord_cmp($e['coord'] as vec<int>, $coord) !== 0) $out[] = $e;
  }
  return phext_implode($out);
}

function phext_normalize(string $data): string {
  return phext_implode(phext_explode($data));
}

function sha256_hex(string $data): string {
  return hash('sha256', $data);
}

function scroll_map(vec<dict<string, mixed>> $sc, vec<int> $coord): string {
  foreach ($sc as $e) {
    if (coord_cmp($e['coord'] as vec<int>, $coord) === 0) {
      return $e['text'] as string;
    }
  }
  return '';
}

function scroll_present(vec<dict<string, mixed>> $sc, vec<int> $coord): bool {
  foreach ($sc as $e) {
    if (coord_cmp($e['coord'] as vec<int>, $coord) === 0) return true;
  }
  return false;
}

/* ------------------------------------------------------------------ JSON
 * Parser: objects -> dict<string, mixed> (insertion order kept),
 * arrays -> vec<mixed>, numbers -> int (float if non-integral),
 * strings -> string (UTF-8; \uXXXX decoded, surrogate pairs joined).
 * Canonical writer: dict keys sorted bytewise, separators , and :,
 * strings escaped Python ensure_ascii style. */
final class JsonParser {
  private string $s = '';
  private int $i = 0;
  private int $n = 0;

  public function parse(string $s): mixed {
    $this->s = $s;
    $this->i = 0;
    $this->n = strlen($s);
    $v = $this->value();
    $this->ws();
    return $v;
  }

  private function ws(): void {
    while ($this->i < $this->n) {
      $c = $this->s[$this->i];
      if ($c === ' ' || $c === "\t" || $c === "\n" || $c === "\r") {
        $this->i++;
      } else {
        break;
      }
    }
  }

  private function value(): mixed {
    $this->ws();
    if ($this->i >= $this->n) return null;
    $c = $this->s[$this->i];
    if ($c === '{') return $this->obj();
    if ($c === '[') return $this->arr();
    if ($c === '"') return $this->str();
    if ($c === 't') {
      $this->i += 4;
      return true;
    }
    if ($c === 'f') {
      $this->i += 5;
      return false;
    }
    if ($c === 'n') {
      $this->i += 4;
      return null;
    }
    return $this->num();
  }

  private function obj(): dict<string, mixed> {
    $out = dict[];
    $this->i++;
    $this->ws();
    if ($this->i < $this->n && $this->s[$this->i] === '}') {
      $this->i++;
      return $out;
    }
    while (true) {
      $this->ws();
      $k = $this->str();
      $this->ws();
      $this->i++; // ':'
      $out[$k] = $this->value();
      $this->ws();
      if ($this->i < $this->n && $this->s[$this->i] === ',') {
        $this->i++;
        continue;
      }
      $this->i++; // '}'
      break;
    }
    return $out;
  }

  private function arr(): vec<mixed> {
    $out = vec[];
    $this->i++;
    $this->ws();
    if ($this->i < $this->n && $this->s[$this->i] === ']') {
      $this->i++;
      return $out;
    }
    while (true) {
      $out[] = $this->value();
      $this->ws();
      if ($this->i < $this->n && $this->s[$this->i] === ',') {
        $this->i++;
        continue;
      }
      $this->i++; // ']'
      break;
    }
    return $out;
  }

  private function hex4(): int {
    $v = 0;
    for ($k = 0; $k < 4; $k++) {
      $c = ord($this->s[$this->i]);
      $this->i++;
      $v = $v * 16;
      if ($c >= 48 && $c <= 57) $v += $c - 48;
      else if ($c >= 97 && $c <= 102) $v += $c - 87;
      else if ($c >= 65 && $c <= 70) $v += $c - 55;
    }
    return $v;
  }

  private function utf8(int $cp): string {
    if ($cp < 0x80) return chr($cp);
    if ($cp < 0x800) {
      return chr(0xC0 | ($cp >> 6)).chr(0x80 | ($cp & 0x3F));
    }
    if ($cp < 0x10000) {
      return chr(0xE0 | ($cp >> 12)).chr(0x80 | (($cp >> 6) & 0x3F)).
        chr(0x80 | ($cp & 0x3F));
    }
    return chr(0xF0 | ($cp >> 18)).chr(0x80 | (($cp >> 12) & 0x3F)).
      chr(0x80 | (($cp >> 6) & 0x3F)).chr(0x80 | ($cp & 0x3F));
  }

  private function str(): string {
    $out = '';
    $this->i++; // opening quote
    while ($this->i < $this->n) {
      $c = $this->s[$this->i];
      if ($c === '"') {
        $this->i++;
        break;
      }
      if ($c === '\\') {
        $this->i++;
        $e = $this->s[$this->i];
        $this->i++;
        if ($e === 'n') $out .= "\n";
        else if ($e === 't') $out .= "\t";
        else if ($e === 'r') $out .= "\r";
        else if ($e === 'b') $out .= "\x08";
        else if ($e === 'f') $out .= "\x0C";
        else if ($e === '/') $out .= '/';
        else if ($e === '\\') $out .= '\\';
        else if ($e === '"') $out .= '"';
        else if ($e === 'u') {
          $cp = $this->hex4();
          if ($cp >= 0xD800 && $cp <= 0xDBFF &&
              $this->i + 1 < $this->n && $this->s[$this->i] === '\\' &&
              $this->s[$this->i + 1] === 'u') {
            $this->i += 2;
            $lo = $this->hex4();
            $cp = 0x10000 + (($cp - 0xD800) << 10) + ($lo - 0xDC00);
          }
          $out .= $this->utf8($cp);
        }
        continue;
      }
      $out .= $c;
      $this->i++;
    }
    return $out;
  }

  private function num(): mixed {
    $start = $this->i;
    $is_float = false;
    while ($this->i < $this->n) {
      $c = $this->s[$this->i];
      if (($c >= '0' && $c <= '9') || $c === '-' || $c === '+') {
        $this->i++;
      } else if ($c === '.' || $c === 'e' || $c === 'E') {
        $is_float = true;
        $this->i++;
      } else {
        break;
      }
    }
    $tok = substr($this->s, $start, $this->i - $start);
    if ($is_float) return (float)$tok;
    return (int)$tok;
  }
}

function json_parse(string $s): mixed {
  $p = new JsonParser();
  return $p->parse($s);
}

function json_escape(string $s): string {
  $out = '"';
  $n = strlen($s);
  $i = 0;
  while ($i < $n) {
    $b = ord($s[$i]);
    if ($b < 0x80) {
      if ($b === 0x22) $out .= '\\"';
      else if ($b === 0x5C) $out .= '\\\\';
      else if ($b === 0x0A) $out .= '\\n';
      else if ($b === 0x0D) $out .= '\\r';
      else if ($b === 0x09) $out .= '\\t';
      else if ($b === 0x08) $out .= '\\b';
      else if ($b === 0x0C) $out .= '\\f';
      else if ($b < 0x20) $out .= sprintf('\\u%04x', $b);
      else $out .= $s[$i];
      $i++;
    } else {
      // decode one UTF-8 codepoint, emit \uXXXX (surrogate pair if needed)
      if ($b >= 0xF0) {
        $cp = (($b & 0x07) << 18) | ((ord($s[$i + 1]) & 0x3F) << 12) |
          ((ord($s[$i + 2]) & 0x3F) << 6) | (ord($s[$i + 3]) & 0x3F);
        $i += 4;
      } else if ($b >= 0xE0) {
        $cp = (($b & 0x0F) << 12) | ((ord($s[$i + 1]) & 0x3F) << 6) |
          (ord($s[$i + 2]) & 0x3F);
        $i += 3;
      } else {
        $cp = (($b & 0x1F) << 6) | (ord($s[$i + 1]) & 0x3F);
        $i += 2;
      }
      if ($cp > 0xFFFF) {
        $v = $cp - 0x10000;
        $out .= sprintf('\\u%04x\\u%04x', 0xD800 + ($v >> 10),
                        0xDC00 + ($v & 0x3FF));
      } else {
        $out .= sprintf('\\u%04x', $cp);
      }
    }
  }
  return $out.'"';
}

function json_canon(mixed $v): string {
  if ($v === null) return 'null';
  if ($v === true) return 'true';
  if ($v === false) return 'false';
  if ($v is int) return (string)$v;
  if ($v is float) return json_encode($v) as string;
  if ($v is string) return json_escape($v);
  if ($v is vec<_>) {
    $parts = vec[];
    foreach ($v as $e) $parts[] = json_canon($e);
    return '['.implode(',', $parts).']';
  }
  if ($v is dict<_, _>) {
    $keys = vec[];
    foreach ($v as $k => $_) $keys[] = $k;
    // bytewise sort (insertion sort; key counts are small)
    $nk = count($keys);
    for ($a = 1; $a < $nk; $a++) {
      $t = $keys[$a];
      $b = $a;
      while ($b > 0 && strcmp($keys[$b - 1], $t) > 0) {
        $keys[$b] = $keys[$b - 1];
        $b--;
      }
      $keys[$b] = $t;
    }
    $parts = vec[];
    foreach ($keys as $k) {
      $parts[] = json_escape($k).':'.json_canon($v[$k]);
    }
    return '{'.implode(',', $parts).'}';
  }
  return 'null';
}

/* ------------------------------------------------ DynamicPhext store
 * CLRS quarter-full dynamic array: capacity from 1, double when full,
 * halve at quarter load; entries kept sorted by coordinate so the
 * serialized form is the canonical implode. */
final class DynPhext {
  public vec<dict<string, mixed>> $store = vec[];
  public int $n = 0;
  public int $capacity = 1;
  public int $resizeCount = 0;

  public function resize(int $newCap): void {
    $this->capacity = $newCap;
    $this->resizeCount++;
  }

  public function growIfFull(): void {
    if ($this->n === $this->capacity) $this->resize($this->capacity * 2);
  }

  public function shrinkIfSparse(): void {
    if ($this->capacity > 1 && $this->n <= (int)($this->capacity / 4)) {
      $this->resize((int)($this->capacity / 2));
    }
  }

  public function findIdx(vec<int> $coord): int {
    for ($i = 0; $i < $this->n; $i++) {
      if (coord_cmp($this->store[$i]['coord'] as vec<int>, $coord) === 0) {
        return $i;
      }
    }
    return -1;
  }

  public static function fromBytes(string $data): DynPhext {
    $d = new DynPhext();
    foreach (phext_explode($data) as $e) {
      $d->growIfFull();
      $d->store[] = $e;
      $d->n++;
    }
    return $d;
  }

  public function serialize(): string {
    $entries = vec[];
    for ($i = 0; $i < $this->n; $i++) $entries[] = $this->store[$i];
    return phext_implode($entries);
  }

  public function fetch(vec<int> $coord): string {
    $i = $this->findIdx($coord);
    return $i < 0 ? '' : ($this->store[$i]['text'] as string);
  }

  public function update(vec<int> $coord, string $text,
                         bool $overwrite): void {
    $i = $this->findIdx($coord);
    if ($i < 0) {
      if ($text !== '') {
        $this->growIfFull();
        $this->store[] = dict['coord' => $coord, 'text' => $text];
        $this->n++;
      }
      return;
    }
    if ($overwrite) {
      if ($text === '') {
        $this->removeAt($i);
      } else {
        $this->store[$i] = dict['coord' => $coord, 'text' => $text];
      }
    } else {
      $this->store[$i] = dict[
        'coord' => $coord,
        'text' => ($this->store[$i]['text'] as string).$text,
      ];
    }
  }

  public function insert(vec<int> $coord, string $text): void {
    $this->update($coord, $text, false);
  }

  public function replace(vec<int> $coord, string $text): void {
    $this->update($coord, $text, true);
  }

  public function removeAt(int $idx): void {
    $out = vec[];
    for ($i = 0; $i < $this->n; $i++) {
      if ($i !== $idx) $out[] = $this->store[$i];
    }
    $this->store = $out;
    $this->n--;
    $this->shrinkIfSparse();
  }

  public function remove(vec<int> $coord): void {
    $i = $this->findIdx($coord);
    if ($i >= 0) $this->removeAt($i);
  }
}

/* ------------------------------------------------ TransitivePhext store
 * Nested hash maps, one layer per dimension (9 layers); leaves hold
 * scroll text. serialize == canonical implode of the string path. */
final class TrnPhext {
  public dict<int, mixed> $root = dict[];

  public static function fromBytes(string $data): TrnPhext {
    $t = new TrnPhext();
    foreach (phext_explode($data) as $e) {
      $t->putCoord($e['coord'] as vec<int>, $e['text'] as string);
    }
    return $t;
  }

  public function putCoord(vec<int> $coord, string $text): void {
    $node = $this->root;
    // walk by reference through nested dicts
    $this->root = $this->putRec($this->root, $coord, 0, $text);
  }

  private function putRec(dict<int, mixed> $node, vec<int> $coord,
                          int $depth, string $text): dict<int, mixed> {
    $k = $coord[$depth];
    if ($depth === 8) {
      $node[$k] = $text;
      return $node;
    }
    $child = $node[$k] ?? dict[];
    $node[$k] = $this->putRec($child as dict<int, mixed>, $coord,
                              $depth + 1, $text);
    return $node;
  }

  private function getRec(mixed $node, vec<int> $coord, int $depth): string {
    if ($depth === 9) return $node as string;
    if (!($node is dict<_, _>)) return '';
    $child = $node[$coord[$depth]] ?? null;
    if ($child === null) return '';
    return $this->getRec($child, $coord, $depth + 1);
  }

  public function fetch(vec<int> $coord): string {
    return $this->getRec($this->root, $coord, 0);
  }

  public function update(vec<int> $coord, string $text,
                         bool $overwrite): void {
    $cur = $this->fetch($coord);
    if ($cur === '') {
      if ($text !== '') $this->putCoord($coord, $text);
      return;
    }
    if ($overwrite) {
      if ($text === '') {
        $this->remove($coord);
      } else {
        $this->putCoord($coord, $text);
      }
    } else {
      $this->putCoord($coord, $cur.$text);
    }
  }

  public function insert(vec<int> $coord, string $text): void {
    $this->update($coord, $text, false);
  }

  public function replace(vec<int> $coord, string $text): void {
    $this->update($coord, $text, true);
  }

  public function remove(vec<int> $coord): void {
    $this->root = $this->removeRec($this->root, $coord, 0);
  }

  private function removeRec(dict<int, mixed> $node, vec<int> $coord,
                             int $depth): dict<int, mixed> {
    $k = $coord[$depth];
    if ($depth === 8) {
      unset($node[$k]);
      return $node;
    }
    $child = $node[$k] ?? null;
    if ($child is dict<_, _>) {
      $node[$k] = $this->removeRec($child, $coord, $depth + 1);
    }
    return $node;
  }

  public function entries(): vec<dict<string, mixed>> {
    return $this->collect($this->root, 0, vec[]);
  }

  public function length(): int {
    return count($this->entries());
  }

  private function collect(mixed $node, int $depth,
                           vec<int> $path): vec<dict<string, mixed>> {
    if ($depth === 9) {
      return vec[dict['coord' => $path, 'text' => $node as string]];
    }
    if (!($node is dict<_, _>)) return vec[];
    $keys = vec[];
    foreach ($node as $k => $_) $keys[] = $k;
    $nk = count($keys);
    for ($a = 1; $a < $nk; $a++) {
      $t = $keys[$a];
      $b = $a;
      while ($b > 0 && $keys[$b - 1] > $t) {
        $keys[$b] = $keys[$b - 1];
        $b--;
      }
      $keys[$b] = $t;
    }
    $out = vec[];
    foreach ($keys as $k) {
      $p = $path;
      $p[] = $k;
      foreach ($this->collect($node[$k], $depth + 1, $p) as $e) {
        $out[] = $e;
      }
    }
    return $out;
  }

  public function serialize(): string {
    return phext_implode($this->entries());
  }
}

/* ------------------------------------------------------------------ gpg
 * Children of HHVM inherit the wrapper's LD_LIBRARY_PATH (bullseye
 * closure), which breaks system binaries; strip it per command. */
function shq(string $s): string {
  return "'".str_replace("'", "'\\''", $s)."'";
}

function run_cmd(string $cmd): int {
  $out = vec[];
  $rc = 0;
  exec('env -u LD_LIBRARY_PATH sh -c '.shq($cmd.' 2>/dev/null'),
       inout $out, inout $rc);
  return $rc;
}

function run_cmd_out(string $cmd): string {
  $full = 'env -u LD_LIBRARY_PATH sh -c '.shq($cmd.' 2>/dev/null');
  $r = shell_exec($full);
  return $r === null ? '' : $r;
}

function gpg_base(): string {
  return "gpg --batch --yes --pinentry-mode loopback --passphrase '' ";
}

function tmpbase(): string {
  return '/tmp/telephone-hack-'.getmypid();
}

function do_keygen(): string {
  $listing = run_cmd_out(gpg_base().'--list-keys --with-colons');
  if (strpos($listing, 'pub:') === false) {
    run_cmd(gpg_base().'--quick-generate-key '.shq('telephone-hack').
            ' ed25519 sign never');
  }
  $pub = run_cmd_out(gpg_base().'--armor --export '.shq('telephone-hack'));
  if ($pub === '' || substr($pub, -1) !== "\n") $pub .= "\n";
  return json_canon(dict['impl' => 'hack', 'pubkey' => $pub]);
}

function do_attest(string $descriptor_canon): string {
  $dp = tmpbase().'.desc';
  $sp = tmpbase().'.sig';
  file_put_contents($dp, $descriptor_canon);
  run_cmd(gpg_base().'--detach-sign --armor -u '.shq('telephone-hack').
          ' -o '.shq($sp).' '.shq($dp));
  $sig = file_get_contents($sp);
  run_cmd('rm -f '.shq($dp).' '.shq($sp));
  return json_canon(dict['signature' => $sig === false ? '' : $sig]);
}

function verify_signature(string $pubkeys, string $data,
                          string $sig_armored): bool {
  $td = tmpbase().'.vfy';
  run_cmd('mkdir -p '.shq($td.'/gnupg'));
  run_cmd('chmod 700 '.shq($td.'/gnupg'));
  file_put_contents($td.'/keys.asc', $pubkeys);
  file_put_contents($td.'/data', $data);
  file_put_contents($td.'/sig.asc', $sig_armored);
  $base = 'GNUPGHOME='.shq($td.'/gnupg').' gpg --batch --yes ';
  $ok = false;
  if (run_cmd($base.'--import '.shq($td.'/keys.asc')) === 0) {
    $ok = run_cmd($base.'--verify '.shq($td.'/sig.asc').' '.
                  shq($td.'/data')) === 0;
  }
  run_cmd('rm -rf '.shq($td));
  return $ok;
}

/* ------------------------------------------------------------ game logic */
function req_state(dict<string, mixed> $req): string {
  if (isset($req['state'])) {
    $d = base64_decode($req['state'] as string);
    return $d === false ? '' : $d;
  }
  if (isset($req['state_b64'])) {
    $d = base64_decode($req['state_b64'] as string);
    return $d === false ? '' : $d;
  }
  return '';
}

function jstrval(mixed $v): string {
  if ($v is string) return $v;
  if ($v is int) return (string)$v;
  return '';
}

function echo_value(mixed $ping): string {
  $p = $ping as dict<string, mixed>;
  $game = jstrval($p['game'] ?? '');
  $round = jstrval($p['round'] ?? ($p['turn'] ?? ''));
  $nonce = jstrval($p['nonce'] ?? '');
  return sha256_hex('hack|'.$game.'|'.$round.'|'.$nonce);
}

function elect_winner(dict<string, mixed> $req): string {
  $pos = $req['position'] ?? '';
  $turn = $req['turn'] ?? 0;
  $cands = vec[];
  if (isset($req['candidates'])) {
    $clist = $req['candidates'] as vec<mixed>;
    foreach ($clist as $c) $cands[] = $c as string;
  }
  if (count($cands) === 0) return 'hack';
  $seed = ($pos as string).'|'.($turn as int).'|'.implode(',', $cands);
  $hb = hash('sha256', $seed, true);
  return $cands[ord($hb[0]) % count($cands)];
}

function wrap999(int $x): int {
  return 1 + ((($x - 1) % 999) + 999) % 999;
}

function next_coord(vec<int> $c): vec<int> {
  $out = $c;
  $d = 8;
  while ($d >= 0) {
    if ($out[$d] < 999) {
      $out[$d] = $out[$d] + 1;
      return $out;
    }
    $out[$d] = 1;
    $d--;
  }
  return $out;
}

function do_choose(dict<string, mixed> $req): string {
  $state = req_state($req);
  $pos_s = $req['position'] as string;
  $turn = $req['turn'] as int;
  $pv = parse_coord($pos_s);
  $sc = phext_explode($state);
  $hb = hash('sha256', $pos_s.'|'.$turn.'|'.$state, true);
  $dim = ord($hb[1]) % 9;
  $bump = 1 + ord($hb[2]) % 3;
  $cand = $pv;
  $cand[$dim] = wrap999($cand[$dim] + $bump);
  $reserved = vec[
    vec[1, 1, 1, 1, 1, 1, 1, 1, 1],
    vec[1, 1, 1, 1, 1, 1, 1, 1, 2],
    vec[1, 1, 1, 1, 1, 1, 1, 1, 3],
  ];
  while (true) {
    $used = scroll_present($sc, $cand);
    if (!$used) {
      foreach ($reserved as $r) {
        if (coord_cmp($r, $cand) === 0) {
          $used = true;
          break;
        }
      }
    }
    if (!$used) break;
    $cand = next_coord($cand);
  }
  $cs = coord_str($cand);
  $text = 'hack turn '.$turn.' at '.$cs;
  return json_canon(dict['coordinate' => $cs, 'op' => 'insert',
                         'text' => $text]);
}

function do_apply(dict<string, mixed> $req): string {
  $state = req_state($req);
  $step = $req['step'] as dict<string, mixed>;
  $op = $step['op'] as string;
  $cs = $step['coordinate'] as string;
  $text = $step['text'] ?? '';
  $coord = parse_coord($cs);
  if ($op === 'fetch') {
    return json_canon(dict[
      'fetch_sha256' => sha256_hex(phext_fetch($state, $coord)),
      'state_b64' => base64_encode($state),
      'state_sha256' => sha256_hex($state),
    ]);
  }
  if (count($coord) !== 9) {
    return json_canon(dict['error' => 'bad coordinate']);
  }
  if ($op === 'insert') {
    $new = phext_insert($state, $coord, $text as string);
  } else if ($op === 'replace') {
    $new = phext_replace($state, $coord, $text as string);
  } else if ($op === 'remove') {
    $new = phext_remove($state, $coord);
  } else {
    return json_canon(dict['error' => 'unknown step op']);
  }
  return json_canon(dict[
    'fetch_sha256' => null,
    'state_b64' => base64_encode($new),
    'state_sha256' => sha256_hex($new),
  ]);
}

function index_c(): vec<int> {
  return vec[1, 1, 1, 1, 1, 1, 1, 1, 1];
}

function keys_c(): vec<int> {
  return vec[1, 1, 1, 1, 1, 1, 1, 1, 2];
}

function kh_c(): vec<int> {
  return vec[1, 1, 1, 1, 1, 1, 1, 1, 3];
}

function vfail(string $detail): string {
  return json_canon(dict['detail' => $detail, 'impl' => 'hack',
                         'verdict' => 'fail']);
}

function trim_both(string $b): string {
  return trim($b, " \t\n\r");
}

function trim_trail_lf(string $b): string {
  $n = strlen($b);
  while ($n > 0 && $b[$n - 1] === "\n") $n--;
  return substr($b, 0, $n);
}

function do_validate(dict<string, mixed> $req): string {
  $step = $req['step'] as dict<string, mixed>;
  $op = $step['op'] as string;
  $state = req_state($req);
  if (isset($req['prior_state'])) {
    $pd = base64_decode($req['prior_state'] as string);
    $prior = $pd === false ? '' : $pd;
    if (isset($req['event_coord'])) {
      // driver form: prior = cached pre-turn state
      $cs = $step['coordinate'] as string;
      $coord = parse_coord($cs);
      $ev = parse_coord($req['event_coord'] as string);
      $index_line = $req['index_line'] as string;
      $text = $step['text'] as string;
      $new_sc = phext_explode($state);
      $old_sc = phext_explode($prior);
      if (scroll_map($new_sc, $coord) !== $text) {
        return vfail('placed scroll missing or altered');
      }
      foreach ($old_sc as $e) {
        $c = $e['coord'] as vec<int>;
        if (coord_cmp($c, index_c()) === 0) continue;
        if (!scroll_present($new_sc, $c) ||
            scroll_map($new_sc, $c) !== ($e['text'] as string)) {
          return vfail('prior scroll overwritten at '.coord_str($c));
        }
      }
      foreach ($new_sc as $e) {
        $c = $e['coord'] as vec<int>;
        if (!scroll_present($old_sc, $c) &&
            coord_cmp($c, $coord) !== 0 && coord_cmp($c, $ev) !== 0) {
          return vfail('unexpected new scroll at '.coord_str($c));
        }
      }
      $idx = scroll_map($new_sc, index_c());
      $a = trim_trail_lf($idx);
      $b = trim_trail_lf($index_line);
      if (strlen($b) > strlen($a) ||
          substr($a, strlen($a) - strlen($b)) !== $b) {
        return vfail('index does not record the placement');
      }
      return json_canon(dict['impl' => 'hack', 'verdict' => 'pass']);
    }
    // selftest prior form
    if ($op !== 'insert') return vfail('step op is not insert');
    $cs2 = $step['coordinate'] as string;
    $coord2 = parse_coord($cs2);
    $text2 = $step['text'] as string;
    $smp = phext_explode($state);
    $pmp = phext_explode($prior);
    if (scroll_map($smp, $coord2) !== $text2) {
      return vfail('placed scroll absent or content differs at '.$cs2);
    }
    if (scroll_present($pmp, $coord2)) {
      return vfail('coordinate was not unused in the prior state');
    }
    if (count($smp) !== count($pmp) + 1) {
      return vfail('scroll count did not grow by exactly one');
    }
    foreach ($pmp as $e) {
      if (scroll_map($smp, $e['coord'] as vec<int>) !==
          ($e['text'] as string)) {
        return vfail('a prior scroll was overwritten: '.
                     coord_str($e['coord'] as vec<int>));
      }
    }
    return json_canon(dict[
      'detail' => 'placed at unused coordinate; all prior scrolls intact',
      'impl' => 'hack',
      'verdict' => 'pass',
    ]);
  }
  return vfail('validate called before init');
}

function vfail2(int $n, string $msg): string {
  return json_canon(dict[
    'first_failure' => dict['detail' => $msg],
    'impl' => 'hack',
    'placements_checked' => $n,
    'verdict' => 'fail',
  ]);
}

function split_lines(string $b): vec<string> {
  if ($b === '') return vec[];
  $parts = explode("\n", $b);
  $out = vec[];
  $last = count($parts) - 1;
  foreach ($parts as $i => $p) {
    if ($i === $last && $p === '') break;
    $out[] = $p;
  }
  return $out;
}

function do_verify(dict<string, mixed> $req): string {
  $state = req_state($req);
  $pubkeys = $req['pubkeys'] as string;
  $sc = phext_explode($state);
  $keys_text = scroll_map($sc, keys_c());
  if ($keys_text === '') {
    return vfail2(0, 'no public-keys scroll at 1.1.1/1.1.1/1.1.2');
  }
  if (trim_both($pubkeys) !== trim_both($keys_text)) {
    return vfail2(0, 'supplied pubkeys do not match the inscribed keys scroll');
  }
  $kh = scroll_map($sc, kh_c());
  if ($kh === '') {
    return vfail2(0, 'no keys-hash scroll at 1.1.1/1.1.1/1.1.3');
  }
  if (trim_both($kh) !== sha256_hex($keys_text)) {
    return vfail2(0, 'keys-hash scroll does not match the keys scroll');
  }
  $idx_lines = vec[];
  foreach (split_lines(scroll_map($sc, index_c())) as $ln) {
    if ($ln !== '' && $ln[0] !== '#') $idx_lines[] = $ln;
  }
  // event scrolls live under 1.1.1/1.1.1/2.1.<seq>
  $events = dict[];
  foreach ($sc as $e) {
    $c = $e['coord'] as vec<int>;
    if ($c[0] === 1 && $c[1] === 1 && $c[2] === 1 && $c[3] === 1 &&
        $c[4] === 1 && $c[5] === 1 && $c[6] === 2 && $c[7] === 1) {
      $events[$c[8]] = $e['text'] as string;
    }
  }
  $seqs = vec[];
  foreach ($events as $s => $_) $seqs[] = $s;
  $ns = count($seqs);
  for ($a = 1; $a < $ns; $a++) {
    $t = $seqs[$a];
    $b = $a;
    while ($b > 0 && $seqs[$b - 1] > $t) {
      $seqs[$b] = $seqs[$b - 1];
      $b--;
    }
    $seqs[$b] = $t;
  }
  $prev_hash = '';
  $have_prev = false;
  $seen = keyset[];
  $checked = 0;
  foreach ($seqs as $i => $seq) {
    if ($seq !== $i + 1) {
      return vfail2($checked, 'event seq gap at '.$seq);
    }
    $ev = json_parse($events[$seq]) as dict<string, mixed>;
    if (!isset($ev['body'])) {
      return vfail2($checked, 'event '.$seq.' lacks a body object');
    }
    $body = $ev['body'] as dict<string, mixed>;
    if (!array_key_exists('prev', $ev)) {
      return vfail2($checked, 'event '.$seq.' lacks prev');
    }
    $pv = $ev['prev'];
    if ($seq === 1) {
      if ($pv !== null) {
        return vfail2($checked, 'event 1 prev is not null');
      }
    } else {
      if (($pv as string) !== $prev_hash) {
        return vfail2($checked, 'event chain broken at seq '.$seq);
      }
    }
    $prev_hash = sha256_hex(json_canon($body));
    $have_prev = true;
    if (($body['type'] ?? '') !== 'placement') continue;
    $cs = $body['coord'] as string;
    $text_hash = $body['text_sha256'] as string;
    $file_hash = $body['file_sha256'] as string;
    $att_b64 = $body['att'] as string;
    $turn_n = $body['turn'] as int;
    $actor = $body['actor'] as string;
    if (isset($seen[$cs])) {
      return vfail2($checked, 'coordinate reused at '.$cs);
    }
    $pcoord = parse_coord($cs);
    if (!scroll_present($sc, $pcoord)) {
      return vfail2($checked, 'placement missing at '.$cs);
    }
    if (sha256_hex(scroll_map($sc, $pcoord)) !== $text_hash) {
      return vfail2($checked, 'placement hash mismatch at '.$cs);
    }
    $found_idx = false;
    foreach ($idx_lines as $ln) {
      $f = explode(' ', $ln);
      if (count($f) === 4 && $f[1] === $cs) {
        $found_idx = true;
        if ($f[2] !== $text_hash || $f[0] !== (string)$turn_n ||
            $f[3] !== $actor) {
          return vfail2($checked, 'index mismatch at '.$cs);
        }
      }
    }
    if (!$found_idx) {
      return vfail2($checked, 'index mismatch at '.$cs);
    }
    $desc = json_canon(dict[
      'coordinate' => $cs,
      'file_sha256' => $file_hash,
      'scroll_sha256' => $text_hash,
      'turn' => $turn_n,
    ]);
    $sig = base64_decode($att_b64);
    if (!verify_signature($pubkeys, $desc, $sig === false ? '' : $sig)) {
      return vfail2($checked, 'event '.$seq.' signature: gpg verify failed');
    }
    $seen[] = $cs;
    $checked++;
  }
  if ($checked === 0) {
    return vfail2(0, 'no placement events found');
  }
  if (count($idx_lines) !== $checked) {
    return vfail2($checked, 'index lines != placements');
  }
  return json_canon(dict['first_failure' => null, 'impl' => 'hack',
                         'placements_checked' => $checked,
                         'verdict' => 'pass']);
}

function handle(string $req_bytes): string {
  $req = json_parse($req_bytes) as dict<string, mixed>;
  $cmd = $req['cmd'] ?? '';
  if ($cmd === 'id') {
    return json_canon(dict['impl' => 'hack']);
  }
  if ($cmd === 'echo') {
    return json_canon(dict['echo' => echo_value($req['ping'] ?? dict[]),
                           'impl' => 'hack']);
  }
  if ($cmd === 'elect') {
    return json_canon(dict['elect' => elect_winner($req)]);
  }
  if ($cmd === 'choose') return do_choose($req);
  if ($cmd === 'apply') return do_apply($req);
  if ($cmd === 'keygen') return do_keygen();
  if ($cmd === 'attest') {
    return do_attest(json_canon($req['descriptor'] ?? dict[]));
  }
  if ($cmd === 'init') {
    $st = req_state($req);
    phext_explode($st);
    return json_canon(dict['impl' => 'hack', 'verdict' => 'pass']);
  }
  if ($cmd === 'validate') return do_validate($req);
  if ($cmd === 'verify') return do_verify($req);
  return json_canon(dict['error' => 'unknown cmd '.($cmd as string)]);
}

function process_file(string $req_path, string $resp_path): void {
  $raw = file_get_contents($req_path);
  $line = trim_trail_lf($raw === false ? '' : $raw);
  $resp = '';
  try {
    $resp = handle($line);
  } catch (Exception $e) {
    $resp = json_canon(dict['error' => 'hack: handler exception']);
  }
  file_put_contents($resp_path, $resp."\n");
}

/* ------------------------------------------------------------------ tests */
final class Suite {
  public int $checks = 0;
  public int $failures = 0;

  public function ok(bool $cond, string $name): void {
    $this->checks++;
    if (!$cond) {
      $this->failures++;
      echo 'FAIL: '.$name."\n";
    }
  }
}

function run_suite(string $fixtures_dir): int {
  $s = new Suite();
  $c1 = vec[1, 1, 1, 1, 1, 1, 1, 1, 1];
  $c2 = vec[1, 1, 1, 1, 1, 1, 1, 1, 2];
  $c3 = vec[1, 1, 1, 1, 1, 1, 1, 2, 1];
  $far = vec[3, 1, 4, 1, 5, 9, 2, 6, 5];

  // coord parse/format
  $s->ok(coord_str($far) === '3.1.4/1.5.9/2.6.5', 'coord format');
  $pc = parse_coord('3.1.4/1.5.9/2.6.5');
  $s->ok(count($pc) === 9 && $pc[0] === 3 && $pc[8] === 5, 'coord parse');
  $s->ok(count(parse_coord('1.2/3.4/5.6')) === 0, 'coord parse rejects');
  $s->ok(coord_cmp($c1, $c2) < 0 && coord_cmp($c2, $c1) > 0 &&
         coord_cmp($c1, $c1) === 0, 'coord compare');

  // empty + basic round trip
  $s->ok(phext_explode('') === vec[], 'explode empty');
  $s->ok(phext_implode(vec[]) === '', 'implode empty');
  $d = phext_insert('', $c1, 'alpha');
  $s->ok($d === 'alpha', 'insert into empty');
  $s->ok(phext_fetch($d, $c1) === 'alpha', 'fetch');
  $s->ok(phext_fetch($d, $c2) === '', 'fetch missing');

  // insert appends after existing text
  $d = phext_insert($d, $c1, 'beta');
  $s->ok(phext_fetch($d, $c1) === 'alphabeta', 'insert appends');
  // replace overwrites; replace with empty deletes
  $d = phext_replace($d, $c1, 'gamma');
  $s->ok(phext_fetch($d, $c1) === 'gamma', 'replace overwrites');
  $d2 = phext_replace($d, $c1, '');
  $s->ok(phext_fetch($d2, $c1) === '' && $d2 === '', 'replace empty deletes');

  // second scroll + canonical order independent of insertion order
  $d = phext_insert('', $c2, 'second');
  $d = phext_insert($d, $c1, 'first');
  $s->ok(phext_fetch($d, $c1) === 'first' &&
         phext_fetch($d, $c2) === 'second', 'two scrolls');
  $s->ok(phext_normalize($d) === $d, 'normalize idempotent (small)');

  // REMOVE IS COORDINATE-PRESERVING: removing c2 leaves c3's text at c3
  $d = phext_insert('', $c1, 'one');
  $d = phext_insert($d, $c2, 'two');
  $d = phext_insert($d, $c3, 'three');
  $d = phext_remove($d, $c2);
  $s->ok(phext_fetch($d, $c2) === '', 'remove drops the scroll');
  $s->ok(phext_fetch($d, $c3) === 'three',
         'remove is coordinate-preserving (gap kept)');
  $s->ok(phext_fetch($d, $c1) === 'one', 'remove keeps neighbours');
  $expl = phext_explode($d);
  $s->ok(count($expl) === 2 &&
         coord_cmp($expl[1]['coord'] as vec<int>, $c3) === 0,
         'gap survives explode after remove');

  // far coordinate + break-run structure
  $d = phext_insert('', $far, 'far away');
  $s->ok(phext_fetch($d, $far) === 'far away', 'far coordinate');
  $s->ok(phext_normalize($d) === $d, 'far normalize idempotent');

  // sha256 + base64 vectors
  $s->ok(sha256_hex('abc') ===
         'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
         'sha256 vector');
  $s->ok(base64_encode('hello world') === 'aGVsbG8gd29ybGQ=', 'b64 encode');
  $s->ok(base64_decode('aGVsbG8gd29ybGQ=') === 'hello world', 'b64 decode');

  // canonical JSON: sorted keys, tight separators, escapes
  $s->ok(json_canon(dict['b' => 1, 'a' => 'x']) === '{"a":"x","b":1}',
         'canon sorts keys');
  $s->ok(json_canon(dict['n' => null, 't' => true, 'f' => false]) ===
         '{"f":false,"n":null,"t":true}', 'canon literals');
  $s->ok(json_canon(vec[1, 'a', vec[]]) === '[1,"a",[]]', 'canon arrays');
  $s->ok(json_canon("a\"b\\c\nd") === '"a\\"b\\\\c\\nd"', 'canon escapes');
  $parsed = json_parse('{"z":[1,2,{"k":"v"}],"a":null}') as dict<string, mixed>;
  $s->ok(json_canon($parsed) === '{"a":null,"z":[1,2,{"k":"v"}]}',
         'parse+canon round trip');

  // store equivalence over a scripted op sequence
  $ops = vec[
    vec['i', '1.1.1/1.1.1/1.1.1', 'A'],
    vec['i', '1.1.1/1.1.1/1.1.2', 'B'],
    vec['i', '2.1.1/1.1.1/1.1.1', 'C'],
    vec['i', '1.1.1/1.1.1/1.1.1', 'A2'],
    vec['r', '1.1.1/1.1.1/1.1.2', 'B2'],
    vec['i', '1.1.1/1.1.1/2.1.1', 'D'],
    vec['x', '2.1.1/1.1.1/1.1.1', ''],
    vec['i', '9.9.9/9.9.9/9.9.9', 'Z'],
    vec['r', '9.9.9/9.9.9/9.9.9', ''],
    vec['i', '1.1.1/1.1.1/1.1.2', 'B3'],
  ];
  $buf = '';
  $dyn = DynPhext::fromBytes('');
  $trn = TrnPhext::fromBytes('');
  foreach ($ops as $op) {
    $coord = parse_coord($op[1]);
    if ($op[0] === 'i') {
      $buf = phext_insert($buf, $coord, $op[2]);
      $dyn->insert($coord, $op[2]);
      $trn->insert($coord, $op[2]);
    } else if ($op[0] === 'r') {
      $buf = phext_replace($buf, $coord, $op[2]);
      $dyn->replace($coord, $op[2]);
      $trn->replace($coord, $op[2]);
    } else {
      $buf = phext_remove($buf, $coord);
      $dyn->remove($coord);
      $trn->remove($coord);
    }
  }
  $s->ok($dyn->serialize() === $buf, 'dynamic store == buffer');
  $s->ok($trn->serialize() === $buf, 'transitive store == buffer');
  $s->ok($dyn->fetch(parse_coord('1.1.1/1.1.1/1.1.1')) === 'AA2',
         'dynamic fetch');
  $s->ok($trn->fetch(parse_coord('1.1.1/1.1.1/1.1.2')) === 'B2B3',
         'transitive fetch');
  $s->ok($trn->length() === 3, 'transitive length');

  // dynamic capacity: CLRS quarter-full counters
  $cap = new DynPhext();
  for ($i = 1; $i <= 64; $i++) {
    $cap->insert(vec[1, 1, 1, 1, 1, 1, 1, 1, $i], 's');
  }
  $s->ok($cap->capacity === 64, 'capacity doubles to fit 64');
  $s->ok($cap->resizeCount <= 7, 'resize count is logarithmic');

  // fixtures: byte-identical round trips
  if ($fixtures_dir !== '') {
    $listing = run_cmd_out('find '.shq($fixtures_dir).
                           ' -name input.phext | sort');
    $paths = vec[];
    foreach (split_lines(trim_trail_lf($listing)) as $p) {
      if ($p !== '') $paths[] = $p;
    }
    $identical = 0;
    $idem = 0;
    foreach ($paths as $p) {
      $data = file_get_contents($p);
      if ($data === false) continue;
      if (phext_implode(phext_explode($data)) === $data) $identical++;
      $once = phext_normalize($data);
      if (phext_normalize($once) === $once) $idem++;
    }
    echo 'fixtures: '.count($paths).' input.phext, '.$identical.
      ' byte-identical round-trips, '.$idem." normalize-idempotent\n";
    $s->ok(count($paths) === 16, 'fixtures count is 16');
    $s->ok($identical === 16, 'fixtures 16/16 byte-identical');
    $s->ok($idem === 16, 'fixtures 16/16 normalize-idempotent');
  }

  echo 'hack suite: '.$s->checks.' checks, '.$s->failures." failures\n";
  return $s->failures === 0 ? 0 : 1;
}

<<__EntryPoint>>
function telephone_main(): void {
  $server = HH\global_get('_SERVER') as dict<string, mixed>;
  $argv = $server['argv'] as vec<string>;
  if (count($argv) >= 2 && $argv[1] === 'test') {
    $dir = count($argv) >= 3 ? $argv[2] : '';
    exit(run_suite($dir));
  }
  if (count($argv) >= 3) {
    process_file($argv[1], $argv[2]);
  }
}
