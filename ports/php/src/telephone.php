<?php
// Exocortical Telephone Game CLI (contract v2) for the PHP libphext
// port. Wire protocol: one JSON request in, one JSON response out.
// With no arguments it handles a single request on stdin; with the
// argument "serve" it loops over JSON lines on stdin/stdout.
//
// Commands (contract v2):
//   {"cmd":"id"}                          -> {"impl":"php"}
//   {"cmd":"echo","ping":{game,round,nonce}} -> {"impl":"php","echo":hex}
//   {"cmd":"elect","position":..,"candidates":[..],"turn":n} -> {"elect":id}
//   {"cmd":"choose","state":b64,"position":..,"turn":n} -> insert step
//   {"cmd":"apply","state":b64,"step":{...}} -> {"state_b64","state_sha256"}
//   {"cmd":"keygen"}                      -> {"impl":"php","pubkey":armored}
//   {"cmd":"attest","descriptor":{...}}   -> {"signature":armored}
//   {"cmd":"validate","state":b64,"step":{...},"prior_state":b64?}
//                                         -> {"impl","verdict","detail"}
//   {"cmd":"verify","state":b64,"pubkeys":armored}
//                                         -> {"impl","verdict","placements_checked","first_failure"}
// The state key is accepted as "state" (contract v2) or "state_b64".
//
// Echo rule (this port's idiom, deterministic given the ping):
// sha256 hex of "php|<game>|<round>|<nonce>".
//
// Elect rule (popcorn, this port's idiom): seed = sha256(position
// bytes || byte(turn) || candidates joined with ","); the winner is
// candidates[ord(seed[0]) % count(candidates)].
//
// Choose rule (insert-only per contract v2): seed = sha256(position ||
// byte(turn) || state). First candidate = tracked position with
// component ord(seed[1])%9 advanced by 1+ord(seed[2])%3 (wrapping
// within 1..999); while the candidate holds a scroll in the given
// state, advance it by one scroll (lexicographic +1 within 999^9).
// The stress.phext bookkeeping coordinates 1.1.1/1.1.1/1.1.1-3 count
// as always used. Text: "php turn <turn> at <coordinate>".
//
// Canonical JSON (attest/verify): compact, keys sorted, strings
// escaped the way Python's json.dumps(ensure_ascii=True) escapes them.
//
// stress.phext layout (contract v2, pinned formats — the driver's
// inscription is canonical): index scroll at 1.1.1/1.1.1/1.1.1 with a
// header line, then one "<turn> <coordinate> <sha256hex> <actor id>"
// line per placement; participant public keys at 1.1.1/1.1.1/1.1.2;
// sha256 of the keys scroll text EXACTLY as inscribed (no trimming)
// at 1.1.1/1.1.1/1.1.3; event scrolls at 1.1.1/1.1.1/2.1.<seq> (seq
// from 1), each canonical JSON {"prev": <sha256 of previous event's
// body, or null>, "body": {...}}. A placement body carries type,
// turn, actor, elect_by, coord, text_sha256, file_sha256 (file hash
// after the placement insert, before inscription), att (base64 of
// the armored detached signature), echoes, consensus_prev. The
// signed attestation descriptor is the canonical JSON {"turn",
// "coordinate","scroll_sha256","file_sha256"} built from the body.
// Verify walks every event: chain integrity via prev, placement
// present with matching hash, index line matching (turn, hash,
// actor), signature valid against the inscribed public keys.
//
// PGP: gpg (2.4.4 on the hub), key home $TELEPHONE_GNUPG_HOME or
// ~/telephone-php/gnupg. Private keys never leave that home.

declare(strict_types=1);
require __DIR__ . '/phext.php';

const IMPL_ID = 'php';
const KEY_UID = 'libphext telephone php';
const INDEX_COORD = '1.1.1/1.1.1/1.1.1';
const KEYS_COORD = '1.1.1/1.1.1/1.1.2';
const KEYS_HASH_COORD = '1.1.1/1.1.1/1.1.3';
const RESERVED = [INDEX_COORD, KEYS_COORD, KEYS_HASH_COORD];

function sha256hex(string $b): string
{
    return hash('sha256', $b);
}

function stateBytes(array $req): string
{
    $s = $req['state'] ?? $req['state_b64'] ?? '';
    return base64_decode((string)$s);
}

// ---- canonical JSON -----------------------------------------------------

function canonString(string $s): string
{
    $out = '"';
    $len = strlen($s);
    for ($i = 0; $i < $len;) {
        $b = ord($s[$i]);
        if ($b < 0x80) {
            $cp = $b;
            $n = 1;
        } elseif ($b >= 0xF0) {
            $cp = (($b & 0x07) << 18) | ((ord($s[$i + 1]) & 0x3F) << 12)
                | ((ord($s[$i + 2]) & 0x3F) << 6) | (ord($s[$i + 3]) & 0x3F);
            $n = 4;
        } elseif ($b >= 0xE0) {
            $cp = (($b & 0x0F) << 12) | ((ord($s[$i + 1]) & 0x3F) << 6) | (ord($s[$i + 2]) & 0x3F);
            $n = 3;
        } else {
            $cp = (($b & 0x1F) << 6) | (ord($s[$i + 1]) & 0x3F);
            $n = 2;
        }
        $i += $n;
        switch ($cp) {
            case 0x22: $out .= '\\"'; break;
            case 0x5C: $out .= '\\\\'; break;
            case 0x08: $out .= '\\b'; break;
            case 0x0C: $out .= '\\f'; break;
            case 0x0A: $out .= '\\n'; break;
            case 0x0D: $out .= '\\r'; break;
            case 0x09: $out .= '\\t'; break;
            default:
                if ($cp < 0x20 || $cp > 0x7E) {
                    if ($cp > 0xFFFF) {
                        $v = $cp - 0x10000;
                        $out .= sprintf('\\u%04x\\u%04x', 0xD800 + ($v >> 10), 0xDC00 + ($v & 0x3FF));
                    } else {
                        $out .= sprintf('\\u%04x', $cp);
                    }
                } else {
                    $out .= chr($cp);
                }
        }
    }
    return $out . '"';
}

function canonJSON($v): string
{
    if ($v === null) {
        return 'null';
    }
    if (is_bool($v)) {
        return $v ? 'true' : 'false';
    }
    if (is_int($v)) {
        return (string)$v;
    }
    if (is_float($v)) {
        return rtrim(rtrim(sprintf('%.10F', $v), '0'), '.');
    }
    if (is_string($v)) {
        return canonString($v);
    }
    if ($v instanceof stdClass) {
        // Object decode: an empty object stays "{}" (an empty PHP
        // array would canon as "[]" — wrong for e.g. consensus_prev).
        $vars = get_object_vars($v);
        $keys = array_keys($vars);
        sort($keys, SORT_STRING);
        $parts = [];
        foreach ($keys as $k) {
            $parts[] = canonString((string)$k) . ':' . canonJSON($vars[$k]);
        }
        return '{' . implode(',', $parts) . '}';
    }
    if (array_is_list($v)) {
        return '[' . implode(',', array_map('canonJSON', $v)) . ']';
    }
    $keys = array_keys($v);
    sort($keys, SORT_STRING);
    $parts = [];
    foreach ($keys as $k) {
        $parts[] = canonString((string)$k) . ':' . canonJSON($v[$k]);
    }
    return '{' . implode(',', $parts) . '}';
}

// ---- gpg ------------------------------------------------------------------

function gnupgHome(): string
{
    $h = getenv('TELEPHONE_GNUPG_HOME');
    if ($h) {
        return $h;
    }
    return getenv('HOME') . '/telephone-' . IMPL_ID . '/gnupg';
}

function runGPG(array $args, ?string &$stderr = null): string
{
    $home = gnupgHome();
    if (!is_dir($home)) {
        mkdir($home, 0700, true);
    }
    $cmd = array_merge(['gpg', '--batch', '--yes', '--pinentry-mode', 'loopback',
        '--passphrase', '', '--homedir', $home], $args);
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    $out = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    $code = proc_close($proc);
    if ($code !== 0) {
        throw new RuntimeException('gpg ' . implode(' ', $args) . " failed: $stderr");
    }
    return $out;
}

function keygen(): string
{
    $listing = runGPG(['--list-keys', '--with-colons']);
    if (!str_contains($listing, 'pub:')) {
        runGPG(['--quick-gen-key', KEY_UID, 'ed25519', 'sign', 'never']);
    }
    return runGPG(['--armor', '--export', KEY_UID]);
}

function detachSign(string $data): string
{
    $dir = sys_get_temp_dir() . '/telephone-' . IMPL_ID . '-sign-' . getmypid();
    mkdir($dir, 0700, true);
    file_put_contents("$dir/descriptor.json", $data);
    runGPG(['--detach-sign', '--armor', '--local-user', KEY_UID,
        '--output', "$dir/descriptor.asc", "$dir/descriptor.json"]);
    $sig = file_get_contents("$dir/descriptor.asc");
    unlink("$dir/descriptor.json");
    unlink("$dir/descriptor.asc");
    rmdir($dir);
    return $sig;
}

function verifySignature(string $pubkeys, string $data, string $signature): void
{
    $dir = sys_get_temp_dir() . '/telephone-' . IMPL_ID . '-verify-' . getmypid();
    mkdir("$dir/gnupg", 0700, true);
    file_put_contents("$dir/keys.asc", $pubkeys);
    file_put_contents("$dir/descriptor.json", $data);
    file_put_contents("$dir/descriptor.asc", $signature);
    $cmd = ['gpg', '--batch', '--yes', '--pinentry-mode', 'loopback',
        '--homedir', "$dir/gnupg", '--import', "$dir/keys.asc"];
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    if (proc_close($proc) !== 0) {
        throw new RuntimeException('gpg import failed');
    }
    $cmd = ['gpg', '--batch', '--yes', '--homedir', "$dir/gnupg",
        '--verify', "$dir/descriptor.asc", "$dir/descriptor.json"];
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    if (proc_close($proc) !== 0) {
        throw new RuntimeException("gpg verify failed: $err");
    }
}

// ---- game logic -----------------------------------------------------------

function echoValue(array $ping): string
{
    $game = $ping['game'] ?? '';
    $round = $ping['round'] ?? $ping['turn'] ?? '';
    $nonce = $ping['nonce'] ?? '';
    return sha256hex(IMPL_ID . '|' . $game . '|' . $round . '|' . $nonce);
}

function electWinner(string $position, array $candidates, int $turn): string
{
    $seed = hash('sha256', $position . chr($turn % 256) . implode(',', $candidates), true);
    return $candidates[ord($seed[0]) % count($candidates)];
}

function nextCoord(array $c): array
{
    for ($d = 8; $d >= 0; $d--) {
        if ($c[$d] < 999) {
            $c[$d]++;
            return $c;
        }
        $c[$d] = 1;
    }
    return $c;
}

function chooseAdventure(string $state, string $position, int $turn): array
{
    $pos = Phext::parseCoordinate($position);
    if ($pos === null) {
        throw new RuntimeException("invalid position $position");
    }
    $used = Phext::explode($state);
    foreach (RESERVED as $rc) {
        $used[$rc] = "\0";
    }
    $seed = hash('sha256', $position . chr($turn % 256) . $state, true);
    $cand = $pos;
    $dim = ord($seed[1]) % 9;
    $cand[$dim] = ($cand[$dim] - 1 + 1 + (ord($seed[2]) % 3)) % 999 + 1;
    while (isset($used[Phext::formatCoordinate($cand)])) {
        $cand = nextCoord($cand);
    }
    $coordStr = Phext::formatCoordinate($cand);
    return ['op' => 'insert', 'coordinate' => $coordStr,
        'text' => IMPL_ID . " turn $turn at $coordStr"];
}

/** @return array{0: string, 1: ?string} */
function applyStep(string $state, array $step): array
{
    $coord = Phext::parseCoordinate((string)($step['coordinate'] ?? ''));
    if ($coord === null) {
        return [$state, null];
    }
    $text = (string)($step['text'] ?? '');
    switch ($step['op'] ?? '') {
        case 'insert':
            return [Phext::insert($state, $coord, $text), null];
        case 'replace':
            return [Phext::replace($state, $coord, $text), null];
        case 'remove':
            return [Phext::remove($state, $coord), null];
        case 'fetch':
            return [$state, sha256hex(Phext::fetch($state, $coord))];
        default:
            return [$state, null];
    }
}

// Driver-form validate (telephone.py cmd_play): the file already
// carries the placement scroll, the appended index line and the
// event scroll; the prior state is the serve cache set by init
// (advanced by each passing validate). Semantics mirror
// harness/adapter_base.py validate.
function validateDriver(string $newState, array $step, string $eventCoord, string $indexLine, ?string $priorState): array
{
    if (($step['op'] ?? '') !== 'insert') {
        return ['fail', 'step op is not insert'];
    }
    $coord = Phext::parseCoordinate((string)($step['coordinate'] ?? ''));
    if ($coord === null) {
        return ['fail', 'unparseable coordinate'];
    }
    $prior = $priorState ?? ($GLOBALS['cache_state'] ?? null);
    if ($prior === null) {
        return ['fail', 'no prior state (init not called)'];
    }
    if (Phext::fetch($newState, $coord) !== (string)($step['text'] ?? '')) {
        return ['fail', 'placed scroll absent or content differs at ' . $step['coordinate']];
    }
    $before = Phext::explode($prior);
    $after = Phext::explode($newState);
    $coordStr = (string)$step['coordinate'];
    if (isset($before[$coordStr])) {
        return ['fail', 'coordinate was not unused in the prior state'];
    }
    foreach ($before as $c => $text) {
        if ($c === INDEX_COORD) {
            continue;
        }
        if (($after[$c] ?? null) !== $text) {
            return ['fail', "a prior scroll was overwritten: $c"];
        }
    }
    foreach ($after as $c => $text) {
        if (!isset($before[$c]) && $c !== $coordStr && $c !== $eventCoord) {
            return ['fail', "unexpected new scroll at $c"];
        }
    }
    $idx = $after[INDEX_COORD] ?? '';
    if (!str_ends_with(rtrim($idx, "\n"), rtrim($indexLine, "\n"))) {
        return ['fail', 'index does not record the placement'];
    }
    $GLOBALS['cache_state'] = $newState;
    return ['pass', 'placed at unused coordinate; all prior scrolls intact'];
}

function validateStep(string $newState, array $step, ?string $priorState): array
{
    if (($step['op'] ?? '') !== 'insert') {
        return ['fail', 'step op is not insert'];
    }
    $coord = Phext::parseCoordinate((string)($step['coordinate'] ?? ''));
    if ($coord === null) {
        return ['fail', 'unparseable coordinate'];
    }
    if (Phext::fetch($newState, $coord) !== (string)($step['text'] ?? '')) {
        return ['fail', 'placed scroll absent or content differs at ' . $step['coordinate']];
    }
    if ($priorState !== null) {
        if (Phext::fetch($priorState, $coord) !== '') {
            return ['fail', 'coordinate was not unused in the prior state'];
        }
        $before = Phext::explode($priorState);
        $after = Phext::explode($newState);
        if (count($after) !== count($before) + 1) {
            return ['fail', 'scroll count did not grow by exactly one'];
        }
        foreach ($before as $c => $text) {
            if (($after[$c] ?? null) !== $text) {
                return ['fail', "a prior scroll was overwritten: $c"];
            }
        }
        return ['pass', 'placed at unused coordinate; all prior scrolls intact'];
    }
    return ['pass', 'placed scroll present with attested content (no prior state supplied)'];
}

function eventCoord(int $seq): array
{
    return [1, 1, 1, 1, 1, 1, 2, 1, $seq];
}

function verifyGame(string $state, string $pubkeys): array
{
    $result = ['impl' => IMPL_ID, 'verdict' => 'fail', 'placements_checked' => 0, 'first_failure' => null];
    $fail = function (string $msg, int $checked) use ($result) {
        $result['first_failure'] = ['detail' => $msg];
        $result['placements_checked'] = $checked;
        return $result;
    };
    $scrolls = Phext::explode($state);
    $keysText = $scrolls[KEYS_COORD] ?? '';
    if ($keysText === '') {
        return $fail('no public-keys scroll at ' . KEYS_COORD, 0);
    }
    if (rtrim($pubkeys) !== rtrim($keysText)) {
        return $fail('supplied pubkeys do not match the inscribed keys scroll', 0);
    }
    $keysHash = $scrolls[KEYS_HASH_COORD] ?? null;
    if ($keysHash === null) {
        return $fail('no keys-hash scroll at ' . KEYS_HASH_COORD, 0);
    }
    // Pinned: keys-hash is sha256 of the keys scroll text exactly as
    // inscribed — no trimming.
    if (trim($keysHash) !== sha256hex($keysText)) {
        return $fail('keys-hash scroll does not match the keys scroll', 0);
    }
    // Pinned index line: "<turn> <coordinate> <sha256> <actor id>",
    // after a "# ..." header line.
    $index = [];
    foreach (explode("\n", $scrolls[INDEX_COORD] ?? '') as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }
        $fields = preg_split('/\s+/', $line);
        if (count($fields) !== 4) {
            return $fail("malformed index line: $line", 0);
        }
        $index[$fields[1]] = ['turn' => $fields[0], 'hash' => $fields[2],
                              'actor' => $fields[3]];
    }
    $checked = 0;
    $seen = [];
    $prevHash = null;
    for ($seq = 1; ; $seq++) {
        $eventText = $scrolls[Phext::formatCoordinate(eventCoord($seq))] ?? null;
        if ($eventText === null) {
            break;
        }
        $ev = json_decode($eventText, true);
        if (!is_array($ev) || !isset($ev['body']) || !is_array($ev['body'])) {
            return $fail("event $seq is not a {prev, body} object", $checked);
        }
        $body = $ev['body'];
        // Pinned event chain: prev = sha256 of the previous event's
        // canonical body, null for the first event.
        if ($seq === 1) {
            if (($ev['prev'] ?? null) !== null) {
                return $fail('event 1 prev is not null', $checked);
            }
        } elseif (($ev['prev'] ?? null) !== $prevHash) {
            return $fail("event chain broken at seq $seq", $checked);
        }
        // Chain hash from the object decode, so empty JSON objects
        // in the body canon as "{}" (see canonJSON stdClass branch).
        $evObj = json_decode($eventText);
        $prevHash = sha256hex(canonJSON($evObj->body));
        if (($body['type'] ?? '') !== 'placement') {
            continue;
        }
        $coordStr = $body['coord'] ?? '';
        $textHash = $body['text_sha256'] ?? '';
        $fileHash = $body['file_sha256'] ?? '';
        $attB64 = $body['att'] ?? '';
        if ($coordStr === '' || $textHash === '' || $fileHash === '' || $attB64 === '') {
            return $fail("event $seq lacks coord/text_sha256/file_sha256/att", $checked);
        }
        if (isset($seen[$coordStr])) {
            return $fail("coordinate reused at $coordStr", $checked);
        }
        $placement = $scrolls[$coordStr] ?? null;
        if ($placement === null) {
            return $fail("placement missing at $coordStr", $checked);
        }
        if (sha256hex($placement) !== $textHash) {
            return $fail("placement hash mismatch at $coordStr", $checked);
        }
        $ie = $index[$coordStr] ?? null;
        if ($ie === null || $ie['hash'] !== $textHash
            || $ie['turn'] !== (string)($body['turn'] ?? '')
            || $ie['actor'] !== ($body['actor'] ?? '')) {
            return $fail("index mismatch at $coordStr", $checked);
        }
        // Pinned attestation descriptor, signed by the actor; att is
        // base64 of the armored detached signature.
        $desc = ['turn' => $body['turn'] ?? null, 'coordinate' => $coordStr,
                 'scroll_sha256' => $textHash, 'file_sha256' => $fileHash];
        $signature = base64_decode($attB64);
        try {
            verifySignature($pubkeys, canonJSON($desc), $signature);
        } catch (RuntimeException $e) {
            return $fail("event $seq signature: " . $e->getMessage(), $checked);
        }
        $seen[$coordStr] = true;
        $checked++;
    }
    if ($checked === 0) {
        return $fail('no placement events found', 0);
    }
    foreach (array_keys($index) as $coordStr) {
        if (!isset($seen[$coordStr])) {
            return $fail("index lists a placement with no event: $coordStr", $checked);
        }
    }
    $result['verdict'] = 'pass';
    $result['placements_checked'] = $checked;
    return $result;
}

// ---- dispatch ---------------------------------------------------------------

function handle(array $req): array
{
    switch ($req['cmd'] ?? '') {
        case 'id':
            return ['impl' => IMPL_ID];
        case 'echo':
            return ['impl' => IMPL_ID, 'echo' => echoValue($req['ping'] ?? [])];
        case 'elect':
            $cands = $req['candidates'] ?? [];
            if (!$cands) {
                throw new RuntimeException('elect: no candidates');
            }
            return ['elect' => electWinner((string)$req['position'], $cands, (int)$req['turn'])];
        case 'choose':
            return chooseAdventure(stateBytes($req), (string)$req['position'], (int)$req['turn']);
        case 'apply':
            [$newState, $fetchHash] = applyStep(stateBytes($req), $req['step']);
            return ['state_b64' => base64_encode($newState),
                'state_sha256' => sha256hex($newState), 'fetch_sha256' => $fetchHash];
        case 'keygen':
            return ['impl' => IMPL_ID, 'pubkey' => keygen()];
        case 'attest':
            return ['signature' => detachSign(canonJSON($req['descriptor']))];
        case 'init':
            $GLOBALS['cache_state'] = stateBytes($req);
            return ['impl' => IMPL_ID, 'verdict' => 'pass'];
        case 'validate':
            $prior = isset($req['prior_state']) ? base64_decode((string)$req['prior_state']) : null;
            if (isset($req['event_coord']) || isset($req['index_line'])) {
                [$verdict, $detail] = validateDriver(stateBytes($req), $req['step'],
                    (string)($req['event_coord'] ?? ''), (string)($req['index_line'] ?? ''), $prior);
                return ['impl' => IMPL_ID, 'verdict' => $verdict, 'detail' => $detail];
            }
            [$verdict, $detail] = validateStep(stateBytes($req), $req['step'], $prior);
            return ['impl' => IMPL_ID, 'verdict' => $verdict, 'detail' => $detail];
        case 'verify':
            return verifyGame(stateBytes($req), (string)($req['pubkeys'] ?? ''));
        default:
            throw new RuntimeException('unknown cmd ' . ($req['cmd'] ?? ''));
    }
}

$serve = ($argv[1] ?? '') === 'serve';
if ($serve) {
    while (($line = fgets(STDIN)) !== false) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }
        $req = json_decode($line, true);
        try {
            $out = is_array($req) ? handle($req) : ['error' => 'request is not a JSON object'];
        } catch (Throwable $e) {
            $out = ['error' => $e->getMessage()];
        }
        echo json_encode($out), "\n";
        fflush(STDOUT);
    }
    exit(0);
}
$raw = stream_get_contents(STDIN);
$req = json_decode($raw, true);
if (!is_array($req)) {
    fwrite(STDERR, "request is not a JSON object\n");
    exit(1);
}
try {
    $out = handle($req);
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
echo json_encode($out), "\n";
