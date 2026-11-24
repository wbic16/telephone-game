# Phext.pm - libphext port for Perl (0.6.1 parity semantics; normative
# reference: libphext-py). Phext is a 9-dimensional plain-text format:
# scrolls of text addressed by a coordinate, separated in the byte stream
# by dimension-break bytes.
#
# Dimension breaks (dimension index -> byte):
#   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
#   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
#   8 scroll 0x17.
# A break at dimension d increments component d and resets all lower
# components to 1. Scroll text is a maximal run of non-break bytes; the
# newline byte 0x0A is ordinary text, NOT a break. All operations are on
# byte strings (never decoded text).
package Phext;
use strict;
use warnings;

our $VERSION = '0.6.1';

my @BREAKS = (0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17);
my %BREAK_DIM;
@BREAK_DIM{@BREAKS} = (0 .. 8);

# --- Coordinates: arrayrefs of 9 integers, each >= 1 ---------------------

sub parse_coordinate {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    my @groups = split /\//, $s, -1;
    return undef unless @groups == 3;
    my @parts;
    for my $g (@groups) {
        for my $p (split /\./, $g, -1) {
            return undef unless $p =~ /^\d+$/;
            my $n = $p + 0;
            return undef if $n < 1;
            push @parts, $n;
        }
    }
    return @parts == 9 ? \@parts : undef;
}

sub format_coordinate {
    my ($c) = @_;
    return join '/', join('.', @{$c}[0 .. 2]), join('.', @{$c}[3 .. 5]), join('.', @{$c}[6 .. 8]);
}

sub compare {
    my ($a, $b) = @_;
    for my $i (0 .. 8) {
        return $a->[$i] <=> $b->[$i] if $a->[$i] != $b->[$i];
    }
    return 0;
}

sub _apply_break {
    my ($coord, $d) = @_;
    $coord->[$d]++;
    $coord->[$_] = 1 for $d + 1 .. 8;
    return;
}

# --- Core operations -----------------------------------------------------

# phokenize($buffer) -> arrayref of { coord => \@parts, text => $bytes }
sub phokenize {
    my ($buffer) = @_;
    $buffer = '' unless defined $buffer;
    my @out;
    my @walker = (1) x 9;
    my $len = length $buffer;
    my $i = 0;
    while ($i < $len) {
        my $b = ord substr($buffer, $i, 1);
        if (exists $BREAK_DIM{$b}) {
            _apply_break(\@walker, $BREAK_DIM{$b});
            $i++;
            next;
        }
        my $start = $i;
        $i++ while $i < $len && !exists $BREAK_DIM{ ord substr($buffer, $i, 1) };
        push @out, { coord => [@walker], text => substr($buffer, $start, $i - $start) };
    }
    return \@out;
}

sub _advance {
    my ($loc, $target) = @_;    # $loc modified in place; returns break bytes
    return '' if compare($loc, $target) >= 0;
    my $d = 0;
    $d++ while $loc->[$d] == $target->[$d];
    my $out = chr($BREAKS[$d]) x ($target->[$d] - $loc->[$d]);
    my @reached = @$loc;
    $reached[$d] = $target->[$d];
    $reached[$_] = 1 for $d + 1 .. 8;
    for my $lower ($d + 1 .. 8) {
        $out .= chr($BREAKS[$lower]) x ($target->[$lower] - 1);
        $reached[$lower] = $target->[$lower];
    }
    @$loc = @reached;
    return $out;
}

# dephokenize(\@scrolls) -> canonical bytes (scrolls in ascending order)
sub dephokenize {
    my ($scrolls) = @_;
    my $out = '';
    my @loc = (1) x 9;
    for my $ps (@$scrolls) {
        $out .= _advance(\@loc, $ps->{coord});
        $out .= $ps->{text};
    }
    return $out;
}

sub normalize {
    my ($buffer) = @_;
    return dephokenize(phokenize($buffer));
}

# fetch: text at coord, or "" for a gap coordinate (never a control byte)
sub fetch {
    my ($buffer, $coord) = @_;
    for my $ps (@{ phokenize($buffer) }) {
        return $ps->{text} if compare($ps->{coord}, $coord) == 0;
    }
    return '';
}

sub _update {
    my ($buffer, $coord, $text, $overwrite) = @_;
    my $items = phokenize($buffer);
    my $next = { coord => $coord, text => $text };
    my @result;
    my $appended = 0;
    for my $ps (@$items) {
        if (!$appended && compare($ps->{coord}, $coord) > 0) {
            push @result, $next;
            $appended = 1;
        }
        if (!$appended && compare($ps->{coord}, $coord) == 0) {
            $next->{text} = $ps->{text} . $next->{text} unless $overwrite;
            push @result, $next;
            $appended = 1;
            next;
        }
        push @result, $ps;
    }
    push @result, $next unless $appended;
    return dephokenize(\@result);
}

# insert: existing scroll at coord becomes existing + inserted
sub insert {
    my ($buffer, $coord, $text) = @_;
    return _update($buffer, $coord, $text, 0);
}

# replace: overwrite the scroll at coord (creating it if absent)
sub replace {
    my ($buffer, $coord, $text) = @_;
    return _update($buffer, $coord, $text, 1);
}

# remove: replace with "" then normalize
sub remove {
    my ($buffer, $coord) = @_;
    return normalize(_update($buffer, $coord, '', 1));
}

# explode: map form of phokenize (coordinate string -> text)
sub explode {
    my ($buffer) = @_;
    my %map;
    $map{ format_coordinate($_->{coord}) } = $_->{text} for @{ phokenize($buffer) };
    return \%map;
}

# implode: map form of dephokenize (ascending coordinate order)
sub implode {
    my ($map) = @_;
    my @scrolls = map { { coord => parse_coordinate($_), text => $map->{$_} } } keys %$map;
    @scrolls = sort { compare($a->{coord}, $b->{coord}) } @scrolls;
    return dephokenize(\@scrolls);
}

1;
