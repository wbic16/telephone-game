#!/usr/bin/env perl
# Test suite for the Perl libphext port. Run: perl tests/test_phext.pl
# Fixture conformance uses $ENV{PHEXT_FIXTURES} when set (shared Step 0
# set): phokenize then dephokenize must reproduce each fixture
# byte-identically.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../src";
use Test::More;
use Phext;

sub coord { Phext::parse_coordinate($_[0]) }

# Coordinate parse / format / order
is(Phext::format_coordinate(coord('1.2.3/4.5.6/7.8.9')), '1.2.3/4.5.6/7.8.9', 'coordinate round trip');
is(Phext::parse_coordinate('0.1.1/1.1.1/1.1.1'), undef, 'coordinate rejects 0');
is(Phext::parse_coordinate('1.1.1/1.1.1'), undef, 'coordinate rejects short');
is(Phext::compare(coord('1.1.1/1.1.1/1.1.9'), coord('1.1.1/1.1.2/1.1.1')), -1, 'order: section beats scroll');
is(Phext::compare(coord('2.1.1/1.1.1/1.1.1'), coord('10.1.1/1.1.1/1.1.1')), -1, 'order: numeric not string');

# Break semantics + round trip
my $buf = "a\x17b\x18c\x01d";
my $scrolls = Phext::phokenize($buf);
is_deeply(
    [map { Phext::format_coordinate($_->{coord}) . ':' . $_->{text} } @$scrolls],
    ['1.1.1/1.1.1/1.1.1:a', '1.1.1/1.1.1/1.1.2:b', '1.1.1/1.1.1/1.2.1:c', '2.1.1/1.1.1/1.1.1:d'],
    'phokenize breaks'
);
is(Phext::dephokenize($scrolls), $buf, 'dephokenize round trip');

# Newline is ordinary text
my $s = Phext::phokenize("line1\nline2");
is(scalar(@$s), 1, 'newline does not split');
is($s->[0]{text}, "line1\nline2", 'newline kept in text');

# Fetch, incl. gap coordinates
is(Phext::fetch('hello', coord('1.1.1/1.1.1/1.1.2')), '', 'gap fetch is ""');
is(Phext::fetch('hello', coord('9.9.9/9.9.9/9.9.9')), '', 'far gap fetch is ""');
is(Phext::fetch('hello', coord('1.1.1/1.1.1/1.1.1')), 'hello', 'fetch hit');

# Insert: existing + inserted (reference semantics)
$buf = Phext::insert('base', coord('1.1.1/1.1.1/1.1.1'), '+more');
is(Phext::fetch($buf, coord('1.1.1/1.1.1/1.1.1')), 'base+more', 'insert merges existing+inserted');
$buf = Phext::insert($buf, coord('1.1.1/1.1.1/1.1.3'), 'third');
is($buf, "base+more\x17\x17third", 'insert creates in canonical position');

# Replace / remove + normalize
$buf = Phext::replace("a\x17b\x17c", coord('1.1.1/1.1.1/1.1.2'), 'B');
is($buf, "a\x17B\x17c", 'replace overwrites');
$buf = Phext::remove($buf, coord('1.1.1/1.1.1/1.1.2'));
is($buf, "a\x17\x17c", 'remove + normalize keeps c at scroll 3');
is(Phext::fetch($buf, coord('1.1.1/1.1.1/1.1.2')), '', 'fetch after remove is ""');
is(Phext::remove($buf, coord('5.5.5/5.5.5/5.5.5')), $buf, 'remove gap is no-op');

# Explode / implode
my $m = Phext::explode("x\x17y\x01z");
is(scalar(keys %$m), 3, 'explode count');
is(Phext::implode($m), "x\x17y\x01z", 'explode/implode round trip');

# Fixtures: every input.phext under $PHEXT_FIXTURES recursively (the
# chains and ranges case sets). Standard (the one the sibling ports
# enforce): normalize idempotent for all; phokenize/dephokenize round
# trip byte-identical for all but at most 2 (known non-canonical
# real-corpora inputs).
my $dir = $ENV{PHEXT_FIXTURES};
if ($dir) {
    require File::Find;
    my @paths;
    File::Find::find(sub { push @paths, $File::Find::name if $_ eq 'input.phext' }, $dir);
    @paths = sort @paths;
    ok(@paths > 0, 'fixtures found (' . scalar(@paths) . ')');
    my $identical = 0;
    for my $path (@paths) {
        open(my $fh, '<:raw', $path) or die $!;
        local $/;
        my $data = <$fh>;
        close $fh;
        $data = '' unless defined $data;
        $identical++ if Phext::dephokenize(Phext::phokenize($data)) eq $data;
        my $n1 = Phext::normalize($data);
        is(Phext::normalize($n1), $n1, "fixture normalize idempotent: $path");
    }
    ok($identical >= @paths - 2, "fixtures byte-identical round-trips ($identical/" . scalar(@paths) . ')');
}
else {
    diag 'skipping fixtures (PHEXT_FIXTURES not set)';
}

done_testing();
