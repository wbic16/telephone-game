<?php
// Test suite for the PHP libphext port. Run: php tests/test_phext.php
// Fixture conformance uses $PHEXT_FIXTURES when set (shared Step 0 set):
// phokenize then dephokenize must reproduce each fixture byte-identically.

declare(strict_types=1);
require __DIR__ . '/../src/phext.php';

$failures = 0;
function check(bool $cond, string $name): void
{
    global $failures;
    if ($cond) {
        echo "ok - $name\n";
    } else {
        $failures++;
        echo "FAIL - $name\n";
    }
}
function coord(string $s): array
{
    $c = Phext::parseCoordinate($s);
    if ($c === null) {
        throw new RuntimeException("bad coord $s");
    }
    return $c;
}

// Coordinate parse / format / order
check(Phext::formatCoordinate(coord('1.2.3/4.5.6/7.8.9')) === '1.2.3/4.5.6/7.8.9', 'coordinate round trip');
check(Phext::parseCoordinate('0.1.1/1.1.1/1.1.1') === null, 'coordinate rejects 0');
check(Phext::parseCoordinate('1.1.1/1.1.1') === null, 'coordinate rejects short');
check(Phext::compare(coord('1.1.1/1.1.1/1.1.9'), coord('1.1.1/1.1.2/1.1.1')) === -1, 'order: section beats scroll');
check(Phext::compare(coord('2.1.1/1.1.1/1.1.1'), coord('10.1.1/1.1.1/1.1.1')) === -1, 'order: numeric not string');

// Break semantics + round trip
$buf = "a\x17b\x18c\x01d";
$scrolls = Phext::phokenize($buf);
$got = array_map(fn($ps) => Phext::formatCoordinate($ps['coord']) . ':' . $ps['text'], $scrolls);
check($got === ['1.1.1/1.1.1/1.1.1:a', '1.1.1/1.1.1/1.1.2:b', '1.1.1/1.1.1/1.2.1:c', '2.1.1/1.1.1/1.1.1:d'], 'phokenize breaks');
check(Phext::dephokenize($scrolls) === $buf, 'dephokenize round trip');

// Newline is ordinary text
$s = Phext::phokenize("line1\nline2");
check(count($s) === 1 && $s[0]['text'] === "line1\nline2", 'newline is text');

// Fetch, incl. gap coordinates
check(Phext::fetch('hello', coord('1.1.1/1.1.1/1.1.2')) === '', 'gap fetch is ""');
check(Phext::fetch('hello', coord('9.9.9/9.9.9/9.9.9')) === '', 'far gap fetch is ""');
check(Phext::fetch('hello', coord('1.1.1/1.1.1/1.1.1')) === 'hello', 'fetch hit');

// Insert: existing + inserted (reference semantics)
$buf = Phext::insert('base', coord('1.1.1/1.1.1/1.1.1'), '+more');
check(Phext::fetch($buf, coord('1.1.1/1.1.1/1.1.1')) === 'base+more', 'insert merges existing+inserted');
$buf = Phext::insert($buf, coord('1.1.1/1.1.1/1.1.3'), 'third');
check($buf === "base+more\x17\x17third", 'insert creates in canonical position');

// Replace / remove + normalize
$buf = Phext::replace("a\x17b\x17c", coord('1.1.1/1.1.1/1.1.2'), 'B');
check($buf === "a\x17B\x17c", 'replace overwrites');
$buf = Phext::remove($buf, coord('1.1.1/1.1.1/1.1.2'));
check($buf === "a\x17\x17c", 'remove + normalize keeps c at scroll 3');
check(Phext::fetch($buf, coord('1.1.1/1.1.1/1.1.2')) === '', 'fetch after remove is ""');
check(Phext::remove($buf, coord('5.5.5/5.5.5/5.5.5')) === $buf, 'remove gap is no-op');

// Explode / implode
$m = Phext::explode("x\x17y\x01z");
check(count($m) === 3 && Phext::implode($m) === "x\x17y\x01z", 'explode/implode round trip');

// Fixtures: every input.phext under $PHEXT_FIXTURES recursively (the
// chains and ranges case sets). Standard (the one the sibling ports
// enforce): normalize idempotent for all; phokenize/dephokenize round
// trip byte-identical for all but at most 2 (known non-canonical
// real-corpora inputs).
$dir = getenv('PHEXT_FIXTURES');
if ($dir) {
    $count = 0;
    $identical = 0;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        if ($file->getFilename() !== 'input.phext') {
            continue;
        }
        $data = file_get_contents($file->getPathname());
        $count++;
        if (Phext::dephokenize(Phext::phokenize($data)) === $data) {
            $identical++;
        }
        $n1 = Phext::normalize($data);
        check(Phext::normalize($n1) === $n1, 'fixture normalize idempotent: ' . $file->getPathname());
    }
    check($count > 0, "fixtures found ($count)");
    check($identical >= $count - 2, "fixtures byte-identical round-trips ($identical/$count)");
} else {
    echo "skip - fixtures (PHEXT_FIXTURES not set)\n";
}

echo $failures === 0 ? "PASS\n" : "FAILURES: $failures\n";
exit($failures === 0 ? 0 : 1);
