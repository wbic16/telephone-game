#!/usr/bin/env perl
# telephone.pl - Exocortical Telephone Game CLI (contract v2) for the
# Perl libphext port. Wire protocol: one JSON request in, one JSON
# response out. With no arguments it handles a single request on stdin;
# with the argument "serve" it loops over JSON lines on stdin/stdout.
#
#   {"cmd":"id"}                          -> {"impl":"perl"}
#   {"cmd":"echo","ping":{game,round,nonce}} -> {"impl":"perl","echo":hex}
#   {"cmd":"elect","position":..,"candidates":[..],"turn":n} -> {"elect":id}
#   {"cmd":"choose","state":b64,"position":..,"turn":n} -> insert step
#   {"cmd":"apply","state":b64,"step":{...}} -> {"state_b64","state_sha256"}
#   {"cmd":"keygen"}                      -> {"impl":"perl","pubkey":armored}
#   {"cmd":"attest","descriptor":{...}}   -> {"signature":armored}
#   {"cmd":"validate","state":b64,"step":{...},"prior_state":b64?}
#                                         -> {"impl","verdict","detail"}
#   {"cmd":"verify","state":b64,"pubkeys":armored}
#                                         -> {"impl","verdict","placements_checked","first_failure"}
# The state key is accepted as "state" (contract v2) or "state_b64".
#
# Echo rule (this port's idiom, deterministic given the ping):
# sha256 hex of "perl|<game>|<round>|<nonce>".
#
# Elect rule (popcorn, this port's idiom): seed = sha256(position
# bytes || byte(turn) || candidates joined with ","); the winner is
# candidates[seed_byte0 % count(candidates)].
#
# Choose rule (insert-only per contract v2): seed = sha256(position ||
# byte(turn) || state). First candidate = tracked position with
# component seed_byte1 % 9 advanced by 1 + seed_byte2 % 3 (wrapping
# within 1..999); while the candidate holds a scroll in the given
# state, advance it by one scroll (lexicographic +1 within 999^9).
# The stress.phext bookkeeping coordinates 1.1.1/1.1.1/1.1.1-3 count
# as always used. Text: "perl turn <turn> at <coordinate>".
#
# Canonical JSON (attest/verify): compact, keys sorted, strings
# escaped the way Python's json.dumps(ensure_ascii=True) escapes them.
#
# stress.phext layout (contract v2, pinned formats — the driver's
# inscription is canonical): index scroll at 1.1.1/1.1.1/1.1.1 with a
# header line, then one "<turn> <coordinate> <sha256hex> <actor id>"
# line per placement; participant public keys at 1.1.1/1.1.1/1.1.2;
# sha256 of the keys scroll text EXACTLY as inscribed (no trimming)
# at 1.1.1/1.1.1/1.1.3; event scrolls at 1.1.1/1.1.1/2.1.<seq> (seq
# from 1), each canonical JSON {"prev": <sha256 of previous event's
# body, or null>, "body": {...}}. A placement body carries type,
# turn, actor, elect_by, coord, text_sha256, file_sha256 (file hash
# after the placement insert, before inscription), att (base64 of
# the armored detached signature), echoes, consensus_prev. The
# signed attestation descriptor is the canonical JSON {"turn",
# "coordinate","scroll_sha256","file_sha256"} built from the body.
# Verify walks every event: chain integrity via prev, placement
# present with matching hash, index line matching (turn, hash,
# actor), signature valid against the inscribed public keys.
#
# PGP: gpg (2.4.4 on the hub), key home $TELEPHONE_GNUPG_HOME or
# ~/telephone-perl/gnupg. Private keys never leave that home.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use Phext;
use JSON::PP ();
use Digest::SHA qw(sha256 sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use IO::Uncompress::Gunzip qw(gunzip);
use IO::Compress::Gzip qw(gzip);
use Encode qw(decode);
use B ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Handle ();

my $IMPL = 'perl';
my $KEY_UID = "libphext telephone $IMPL";
my $INDEX_COORD = '1.1.1/1.1.1/1.1.1';
my $KEYS_COORD = '1.1.1/1.1.1/1.1.2';
my $KEYS_HASH_COORD = '1.1.1/1.1.1/1.1.3';
my @RESERVED = ($INDEX_COORD, $KEYS_COORD, $KEYS_HASH_COORD);
my $json = JSON::PP->new->utf8(1);

sub state_bytes {
    my ($req) = @_;
    return decode_base64($req->{state} // $req->{state_b64} // '');
}

# ---- canonical JSON -------------------------------------------------------

sub canon_string {
    my ($s) = @_;
    my $chars = decode('UTF-8', $s, Encode::FB_CROAK | Encode::LEAVE_SRC);
    my $out = '"';
    for my $ch (split //, $chars) {
        my $cp = ord $ch;
        if ($cp == 0x22) { $out .= '\\"' }
        elsif ($cp == 0x5C) { $out .= '\\\\' }
        elsif ($cp == 0x08) { $out .= '\\b' }
        elsif ($cp == 0x0C) { $out .= '\\f' }
        elsif ($cp == 0x0A) { $out .= '\\n' }
        elsif ($cp == 0x0D) { $out .= '\\r' }
        elsif ($cp == 0x09) { $out .= '\\t' }
        elsif ($cp < 0x20 || $cp > 0x7E) {
            if ($cp > 0xFFFF) {
                my $v = $cp - 0x10000;
                $out .= sprintf '\\u%04x\\u%04x', 0xD800 + ($v >> 10), 0xDC00 + ($v & 0x3FF);
            }
            else {
                $out .= sprintf '\\u%04x', $cp;
            }
        }
        else { $out .= $ch }
    }
    return $out . '"';
}

sub canon_json {
    my ($v) = @_;
    return 'null' unless defined $v;
    my $r = ref $v;
    if ($r eq '') {
        # Plain scalar: JSON::PP returns numbers as IV/NV without POK,
        # strings as PV. Emit numbers bare, quote strings.
        my $flags = B::svref_2object(\$v)->FLAGS;
        return "$v" if ($flags & (B::SVp_IOK | B::SVp_NOK)) && !($flags & B::SVp_POK);
        return canon_string($v);
    }
    if ($r eq 'HASH') {
        my @parts = map { canon_string($_) . ':' . canon_json($v->{$_}) } sort keys %$v;
        return '{' . join(',', @parts) . '}';
    }
    if ($r eq 'ARRAY') {
        return '[' . join(',', map { canon_json($_) } @$v) . ']';
    }
    if ($r eq 'JSON::PP::Boolean') {
        return $v ? 'true' : 'false';
    }
    return canon_string("$v");
}

# ---- gpg --------------------------------------------------------------------

sub gnupg_home {
    return $ENV{TELEPHONE_GNUPG_HOME} // "$ENV{HOME}/telephone-$IMPL/gnupg";
}

sub run_gpg {
    my (@args) = @_;
    my $home = gnupg_home();
    make_path($home, { mode => 0700 }) unless -d $home;
    my $dir = tempdir(CLEANUP => 1);
    my $errfile = "$dir/err";
    my $cmd = join ' ', map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" }
        ('gpg', '--batch', '--yes', '--pinentry-mode', 'loopback',
         '--passphrase', '', '--homedir', $home, @args);
    my $out = `$cmd 2>$errfile`;
    if ($? != 0) {
        open my $fh, '<', $errfile;
        local $/;
        my $err = <$fh> // '';
        die "gpg @args failed: $err\n";
    }
    return $out;
}

sub keygen {
    my $listing = run_gpg('--list-keys', '--with-colons');
    if ($listing !~ /^pub:/m) {
        run_gpg('--quick-gen-key', $KEY_UID, 'ed25519', 'sign', 'never');
    }
    return run_gpg('--armor', '--export', $KEY_UID);
}

sub detach_sign {
    my ($data) = @_;
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>:raw', "$dir/descriptor.json" or die $!;
    print $fh $data;
    close $fh;
    run_gpg('--detach-sign', '--armor', '--local-user', $KEY_UID,
            '--output', "$dir/descriptor.asc", "$dir/descriptor.json");
    open my $sf, '<:raw', "$dir/descriptor.asc" or die $!;
    local $/;
    my $sig = <$sf>;
    close $sf;
    return $sig;
}

sub verify_signature {
    my ($pubkeys, $data, $signature) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/gnupg", { mode => 0700 });
    for my $pair (["keys.asc", $pubkeys], ["descriptor.json", $data], ["descriptor.asc", $signature]) {
        open my $fh, '>:raw', "$dir/$pair->[0]" or die $!;
        print $fh $pair->[1];
        close $fh;
    }
    my $rc = system('gpg', '--batch', '--yes', '--pinentry-mode', 'loopback',
                    '--homedir', "$dir/gnupg", '--import', "$dir/keys.asc");
    die "gpg import failed\n" if $rc != 0;
    $rc = system('gpg', '--batch', '--yes', '--homedir', "$dir/gnupg",
                 '--verify', "$dir/descriptor.asc", "$dir/descriptor.json");
    die "gpg verify failed\n" if $rc != 0;
    return 1;
}

# ---- game logic ---------------------------------------------------------------

sub echo_value {
    my ($ping) = @_;
    my $game = $ping->{game} // '';
    my $round = $ping->{round} // $ping->{turn} // '';
    my $nonce = $ping->{nonce} // '';
    return sha256_hex("$IMPL|$game|$round|$nonce");
}

sub elect_winner {
    my ($position, $candidates, $turn) = @_;
    my $seed = sha256($position . chr($turn % 256) . join(',', @$candidates));
    my @seed = unpack 'C*', $seed;
    return $candidates->[ $seed[0] % scalar(@$candidates) ];
}

sub next_coord {
    my ($c) = @_;
    my @c = @$c;
    for (my $d = 8; $d >= 0; $d--) {
        if ($c[$d] < 999) {
            $c[$d]++;
            return \@c;
        }
        $c[$d] = 1;
    }
    return \@c;
}

sub choose_adventure {
    my ($state, $position, $turn) = @_;
    my $pos = Phext::parse_coordinate($position) or die "invalid position $position\n";
    my $used = Phext::explode($state);
    $used->{$_} = "\0" for @RESERVED;
    my $seed = sha256($position . chr($turn % 256) . $state);
    my @seed = unpack 'C*', $seed;
    my @cand = @$pos;
    my $dim = $seed[1] % 9;
    $cand[$dim] = ($cand[$dim] - 1 + 1 + ($seed[2] % 3)) % 999 + 1;
    while (exists $used->{ Phext::format_coordinate(\@cand) }) {
        @cand = @{ next_coord(\@cand) };
    }
    my $coord_str = Phext::format_coordinate(\@cand);
    return { op => 'insert', coordinate => $coord_str,
             text => "$IMPL turn $turn at $coord_str" };
}

sub apply_step {
    my ($state, $step) = @_;
    my $coord = Phext::parse_coordinate($step->{coordinate} // '');
    return ($state, undef) unless $coord;
    my $text = $step->{text} // '';
    my $op = $step->{op} // '';
    return (Phext::insert($state, $coord, $text), undef)  if $op eq 'insert';
    return (Phext::replace($state, $coord, $text), undef) if $op eq 'replace';
    return (Phext::remove($state, $coord), undef)         if $op eq 'remove';
    return ($state, sha256_hex(Phext::fetch($state, $coord))) if $op eq 'fetch';
    return ($state, undef);
}

sub validate_step {
    my ($new_state, $step, $prior_state) = @_;
    return ('fail', 'step op is not insert') if ($step->{op} // '') ne 'insert';
    my $coord = Phext::parse_coordinate($step->{coordinate} // '');
    return ('fail', 'unparseable coordinate') unless $coord;
    if (Phext::fetch($new_state, $coord) ne ($step->{text} // '')) {
        return ('fail', "placed scroll absent or content differs at $step->{coordinate}");
    }
    if (defined $prior_state) {
        if (Phext::fetch($prior_state, $coord) ne '') {
            return ('fail', 'coordinate was not unused in the prior state');
        }
        my $before = Phext::explode($prior_state);
        my $after = Phext::explode($new_state);
        if (keys(%$after) != keys(%$before) + 1) {
            return ('fail', 'scroll count did not grow by exactly one');
        }
        for my $c (keys %$before) {
            if (!exists $after->{$c} || $after->{$c} ne $before->{$c}) {
                return ('fail', "a prior scroll was overwritten: $c");
            }
        }
        return ('pass', 'placed at unused coordinate; all prior scrolls intact');
    }
    return ('pass', 'placed scroll present with attested content (no prior state supplied)');
}

# Driver-form validate (telephone.py cmd_play): the file already
# carries the placement scroll, the appended index line and the
# event scroll; the prior state is the serve cache set by init
# (advanced by each passing validate). Semantics mirror
# harness/adapter_base.py validate.
my $CACHE_STATE;
sub validate_driver {
    my ($new_state, $step, $event_coord, $index_line, $prior) = @_;
    $prior = $CACHE_STATE unless defined $prior;
    return ('fail', 'no prior state (init not called)') unless defined $prior;
    return ('fail', 'step op is not insert') if ($step->{op} // '') ne 'insert';
    my $coord = Phext::parse_coordinate($step->{coordinate} // '');
    return ('fail', 'unparseable coordinate') unless $coord;
    if (Phext::fetch($new_state, $coord) ne ($step->{text} // '')) {
        return ('fail', "placed scroll absent or content differs at $step->{coordinate}");
    }
    my $before = Phext::explode($prior);
    my $after = Phext::explode($new_state);
    my $coord_str = $step->{coordinate};
    return ('fail', 'coordinate was not unused in the prior state')
        if exists $before->{$coord_str};
    for my $c (keys %$before) {
        next if $c eq $INDEX_COORD;
        if (!exists $after->{$c} || $after->{$c} ne $before->{$c}) {
            return ('fail', "a prior scroll was overwritten: $c");
        }
    }
    for my $c (keys %$after) {
        if (!exists $before->{$c} && $c ne $coord_str && $c ne $event_coord) {
            return ('fail', "unexpected new scroll at $c");
        }
    }
    my $idx = $after->{$INDEX_COORD} // '';
    $idx =~ s/\n+$//;
    my $line = $index_line // '';
    $line =~ s/\n+$//;
    if (length($line) == 0 || substr($idx, -length($line)) ne $line) {
        return ('fail', 'index does not record the placement');
    }
    $CACHE_STATE = $new_state;
    return ('pass', 'placed at unused coordinate; all prior scrolls intact');
}

sub verify_game {
    my ($state, $pubkeys) = @_;
    my %result = (impl => $IMPL, verdict => 'fail', placements_checked => 0, first_failure => undef);
    my $fail = sub {
        my ($msg, $checked) = @_;
        $result{first_failure} = { detail => $msg };
        $result{placements_checked} = $checked;
        return \%result;
    };
    my $scrolls = Phext::explode($state);
    my $keys_text = $scrolls->{$KEYS_COORD} // '';
    return $fail->('no public-keys scroll at ' . $KEYS_COORD, 0) if $keys_text eq '';
    (my $trimmed_keys = $keys_text) =~ s/\s+$//;
    (my $trimmed_pub = $pubkeys) =~ s/\s+$//;
    return $fail->('supplied pubkeys do not match the inscribed keys scroll', 0)
        if $trimmed_pub ne $trimmed_keys;
    return $fail->('no keys-hash scroll at ' . $KEYS_HASH_COORD, 0)
        unless exists $scrolls->{$KEYS_HASH_COORD};
    (my $kh = $scrolls->{$KEYS_HASH_COORD}) =~ s/^\s+|\s+$//g;
    # Pinned: keys-hash is sha256 of the keys scroll text exactly as
    # inscribed — no trimming.
    return $fail->('keys-hash scroll does not match the keys scroll', 0)
        if $kh ne sha256_hex($keys_text);
    # Pinned index line: "<turn> <coordinate> <sha256> <actor id>",
    # after a "# ..." header line.
    my %index;
    for my $line (split /\n/, $scrolls->{$INDEX_COORD} // '') {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        my @fields = split /\s+/, $line;
        return $fail->("malformed index line: $line", 0) if @fields != 4;
        $index{ $fields[1] } = { turn => $fields[0], hash => $fields[2],
                                 actor => $fields[3] };
    }
    my $checked = 0;
    my %seen;
    my $prev_hash;
    for (my $seq = 1; ; $seq++) {
        my $ecoord = Phext::format_coordinate([1, 1, 1, 1, 1, 1, 2, 1, $seq]);
        last unless exists $scrolls->{$ecoord};
        my $ev = eval { $json->decode($scrolls->{$ecoord}) };
        return $fail->("event $seq is not a JSON object", $checked)
            unless ref $ev eq 'HASH' && ref $ev->{body} eq 'HASH';
        my $body = $ev->{body};
        # Pinned event chain: prev = sha256 of the previous event's
        # canonical body, null for the first event.
        if ($seq == 1) {
            return $fail->('event 1 prev is not null', $checked)
                if defined $ev->{prev};
        } elsif (!defined $ev->{prev} || $ev->{prev} ne $prev_hash) {
            return $fail->("event chain broken at seq $seq", $checked);
        }
        $prev_hash = sha256_hex(canon_json($body));
        next if ($body->{type} // '') ne 'placement';
        my $coord_str = $body->{coord} // '';
        my $text_hash = $body->{text_sha256} // '';
        my $file_hash = $body->{file_sha256} // '';
        my $att_b64 = $body->{att} // '';
        return $fail->("event $seq lacks coord/text_sha256/file_sha256/att", $checked)
            if $coord_str eq '' || $text_hash eq '' || $file_hash eq '' || $att_b64 eq '';
        return $fail->("coordinate reused at $coord_str", $checked)
            if $seen{$coord_str};
        return $fail->("placement missing at $coord_str", $checked)
            unless exists $scrolls->{$coord_str};
        return $fail->("placement hash mismatch at $coord_str", $checked)
            if sha256_hex($scrolls->{$coord_str}) ne $text_hash;
        my $ie = $index{$coord_str};
        return $fail->("index mismatch at $coord_str", $checked)
            if !$ie || $ie->{hash} ne $text_hash
            || $ie->{turn} ne ($body->{turn} // '')
            || $ie->{actor} ne ($body->{actor} // '');
        # Pinned attestation descriptor, signed by the actor; att is
        # base64 of the armored detached signature. NB: the turn is
        # re-numerified into a fresh scalar — the index comparison
        # above stringified $body->{turn}, and canon_json keys number
        # vs string off the scalar's flags.
        my $desc = { turn => 0 + $body->{turn}, coordinate => $coord_str,
                     scroll_sha256 => $text_hash, file_sha256 => $file_hash };
        my $canon = canon_json($desc);
        my $signature = decode_base64($att_b64);
        my $ok = eval { verify_signature($pubkeys, $canon, $signature); 1 };
        return $fail->("event $seq signature: $@", $checked) unless $ok;
        $seen{$coord_str} = 1;
        $checked++;
    }
    return $fail->('no placement events found', 0) if $checked == 0;
    for my $coord_str (keys %index) {
        return $fail->("index lists a placement with no event: $coord_str", $checked)
            unless $seen{$coord_str};
    }
    $result{verdict} = 'pass';
    $result{placements_checked} = $checked;
    return \%result;
}

# ---- dispatch -------------------------------------------------------------------

sub handle {
    my ($req) = @_;
    my $cmd = $req->{cmd} // '';
    return { impl => $IMPL } if $cmd eq 'id';
    if ($cmd eq 'echo') {
        return { impl => $IMPL, echo => echo_value($req->{ping} // {}) };
    }
    if ($cmd eq 'elect') {
        my $cands = $req->{candidates} // [];
        die "elect: no candidates\n" unless @$cands;
        return { elect => elect_winner($req->{position} // '', $cands, $req->{turn} // 0) };
    }
    if ($cmd eq 'choose') {
        return choose_adventure(state_bytes($req), $req->{position}, $req->{turn});
    }
    if ($cmd eq 'apply') {
        my ($new_state, $fetch_hash) = apply_step(state_bytes($req), $req->{step});
        return { state_b64 => encode_base64($new_state, ''),
                 state_sha256 => sha256_hex($new_state),
                 fetch_sha256 => $fetch_hash };
    }
    if ($cmd eq 'keygen') {
        return { impl => $IMPL, pubkey => keygen() };
    }
    if ($cmd eq 'attest') {
        return { signature => detach_sign(canon_json($req->{descriptor})) };
    }
    if ($cmd eq 'init') {
        $CACHE_STATE = state_bytes($req);
        return { impl => $IMPL, verdict => 'pass' };
    }
    if ($cmd eq 'validate') {
        my $prior = defined $req->{prior_state} ? decode_base64($req->{prior_state}) : undef;
        if (exists $req->{event_coord} || exists $req->{index_line}) {
            my ($verdict, $detail) = validate_driver(state_bytes($req), $req->{step},
                $req->{event_coord} // '', $req->{index_line} // '', $prior);
            return { impl => $IMPL, verdict => $verdict, detail => $detail };
        }
        my ($verdict, $detail) = validate_step(state_bytes($req), $req->{step}, $prior);
        return { impl => $IMPL, verdict => $verdict, detail => $detail };
    }
    if ($cmd eq 'verify') {
        return verify_game(state_bytes($req), $req->{pubkeys} // '');
    }
    die "unknown cmd $cmd\n";
}

binmode STDIN;
binmode STDOUT;
STDOUT->autoflush(1);
my $serve = (@ARGV && $ARGV[0] eq 'serve');
if ($serve) {
    while (my $line = <STDIN>) {
        $line =~ s/\r?\n$//;
        next if $line =~ /^\s*$/;
        # Game-scale framing (2026-11-24): lines over 8 KB may arrive gzip-framed
        # as "GZ1:" + base64(gzip(line)) — the fleet-ssh channel is
        # ~25-70 KB/s and raw base64 state lines took minutes at
        # 1,000 placements. Lossless; plain lines unchanged.
        if (substr($line, 0, 4) eq 'GZ1:') {
            my $raw = decode_base64(substr($line, 4));
            my $plain;
            gunzip(\$raw => \$plain) or die "gunzip failed";
            $line = $plain;
        }
        my $out = eval {
            my $req = $json->decode($line);
            handle($req);
        };
        $out = { error => $@ } if $@;
        my $outj = $json->encode($out);
        if (length($outj) > 8192) {
            my $gz;
            gzip(\$outj => \$gz) or die "gzip failed";
            $outj = 'GZ1:' . encode_base64($gz, '');
        }
        print $outj, "\n";
    }
    exit 0;
}
local $/;
my $raw = <STDIN>;
my $req = $json->decode($raw);
my $out = handle($req);
print $json->encode($out), "\n";
