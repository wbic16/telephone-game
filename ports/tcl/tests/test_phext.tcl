#!/usr/bin/env tclsh
# Unit + conformance tests for the Tcl libphext port.
# Run on the hub:  tclsh tests/test_phext.tcl
# Fixtures: set PHEXT_FIXTURES to harness/fixtures (16 input.phext files
# under chains/ and ranges/); every input must round-trip byte-
# identically through explode/implode and normalize must be idempotent.
set dir [file dirname [file normalize [info script]]]
source [file join $dir .. src phext.tcl]

set failures 0
proc check {cond name} {
    if {[uplevel 1 [list expr $cond]]} { puts "ok - $name" } else {
        puts "FAIL - $name"; incr ::failures
    }
}
proc C {s} { return [phext::coord_parse $s] }
proc readbin {path} {
    set f [open $path r]
    fconfigure $f -encoding binary -translation binary
    set d [read $f]; close $f; return $d
}

# coordinates
check {[phext::coord_str [C "2.3.4/5.6.7/8.9.10"]] eq "2.3.4/5.6.7/8.9.10"} "coord round-trip"
check {[phext::coord_cmp [C "1.1.1/1.1.1/1.1.2"] [C "1.1.1/1.1.1/1.1.10"]] < 0} "coord order"
check {[catch {C "1.1.1/1.1.1/1.1.0"}]} "coord rejects 0"
check {[catch {C "1.1.1/1.1.1"}]} "coord rejects short"

# basic scroll ops; scroll break = \x17, section = \x18, chapter = \x19
set sb [format %c 23]; set sc [format %c 24]
set buf "alpha${sb}beta${sc}gamma"
check {[phext::fetch $buf [C "1.1.1/1.1.1/1.1.1"]] eq "alpha"} "fetch first"
check {[phext::fetch $buf [C "1.1.1/1.1.1/1.1.2"]] eq "beta"} "fetch scroll 2"
check {[phext::fetch $buf [C "1.1.1/1.1.1/1.2.1"]] eq "gamma"} "fetch section 2 scroll 1"
check {[phext::fetch $buf [C "1.1.1/1.1.1/1.1.9"]] eq ""} "fetch gap is empty"
check {[phext::normalize $buf] eq $buf} "normalize idempotent on canonical"

set b2 [phext::insert "" [C "1.1.1/1.1.1/1.1.2"] "second"]
check {[phext::fetch $b2 [C "1.1.1/1.1.1/1.1.2"]] eq "second"} "insert creates"
set b2 [phext::insert $b2 [C "1.1.1/1.1.1/1.1.2"] "+more"]
check {[phext::fetch $b2 [C "1.1.1/1.1.1/1.1.2"]] eq "second+more"} "insert concatenates"
set b2 [phext::replace $b2 [C "1.1.1/1.1.1/1.1.2"] "replaced"]
check {[phext::fetch $b2 [C "1.1.1/1.1.1/1.1.2"]] eq "replaced"} "replace overwrites"

# remove is coordinate-preserving: later scrolls do NOT shift
set b3 "one${sb}two${sb}three"
set b3r [phext::remove $b3 [C "1.1.1/1.1.1/1.1.2"]]
check {[phext::fetch $b3r [C "1.1.1/1.1.1/1.1.1"]] eq "one"} "remove keeps first"
check {[phext::fetch $b3r [C "1.1.1/1.1.1/1.1.2"]] eq ""} "remove empties target"
check {[phext::fetch $b3r [C "1.1.1/1.1.1/1.1.3"]] eq "three"} "remove does not shift later scrolls"

# explode/implode round-trip on a gap buffer
set gap [phext::insert "" [C "3.1.4/1.5.9/2.6.5"] "far"]
check {[phext::implode [phext::explode $gap]] eq $gap} "explode/implode gap round-trip"

# DynamicPhext and TransitivePhext equivalence over an edit sequence
set coords {}
foreach s {"1.1.1/1.1.1/1.1.1" "1.1.1/1.1.1/1.1.2" "1.1.1/1.1.1/1.2.1" "2.1.1/1.1.1/1.1.1" "1.1.1/1.1.1/1.1.3"} {
    lappend coords [C $s]
}
set dyn [phext::DynamicPhext new]
set trn [phext::TransitivePhext new]
set buf ""
set i 0
foreach c $coords {
    incr i
    set buf [phext::insert $buf $c "text$i"]
    $dyn insert $c "text$i"
    $trn insert $c "text$i"
    check {[$dyn serialize] eq $buf} "dynamic == buffer after insert $i"
    check {[$trn serialize] eq $buf} "transitive == buffer after insert $i"
}
set mid [lindex $coords 1]
set buf [phext::remove $buf $mid]
$dyn remove $mid
$trn remove $mid
check {[$dyn serialize] eq $buf} "dynamic == buffer after remove"
check {[$trn serialize] eq $buf} "transitive == buffer after remove"
check {[$dyn fetch $mid] eq "" && [$trn fetch $mid] eq ""} "stores fetch removed as empty"
check {[$dyn len] == 4 && [$trn len] == 4} "store lengths"
$dyn replace [lindex $coords 0] ""
set buf [phext::remove $buf [lindex $coords 0]]
check {[$dyn serialize] eq $buf} "dynamic replace-empty removes"
check {[$trn depth] == 9} "transitive depth 9"

# shared fixtures: 16/16 byte-identical round-trips
if {[info exists ::env(PHEXT_FIXTURES)]} {
    set files [lsort [glob -nocomplain -directory $::env(PHEXT_FIXTURES) */*/input.phext]]
    check {[llength $files] == 16} "found 16 fixture inputs (got [llength $files])"
    set okc 0
    foreach f $files {
        set data [readbin $f]
        if {[phext::implode [phext::explode $data]] eq $data &&
            [phext::normalize [phext::normalize $data]] eq [phext::normalize $data]} {
            incr okc
        } else {
            puts "FAIL - fixture round-trip: $f"
            incr ::failures
        }
    }
    check {$okc == 16} "fixtures round-trip $okc/16"
} else {
    puts "skip - PHEXT_FIXTURES not set (fixtures check skipped)"
}

puts [expr {$failures ? "FAILURES: $failures" : "PASS"}]
exit [expr {$failures ? 1 : 0}]
