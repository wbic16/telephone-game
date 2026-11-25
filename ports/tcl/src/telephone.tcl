#!/usr/bin/env tclsh
# telephone.tcl -- Exocortical Telephone Game CLI (contract v2) for the
# Tcl libphext port. Wire protocol: one JSON request in, one JSON
# response out; with the argument "serve" it loops over JSON lines.
# Commands: id, echo, elect, choose, apply, keygen, attest, validate
# (both the prior_state form and the driver's init/event_coord/
# index_line form), init, verify. All phext operations use this port's
# own phext.tcl; JSON uses this port's own json.tcl. PGP via subprocess
# gpg (key home $TELEPHONE_GNUPGHOME or ~/telephone-tcl/gnupg; private
# keys never leave it). sha256 via subprocess sha256sum (Tcl's tcllib
# sha2 is not installed on the hub; hashing is a crypto utility, not
# phext logic).

set dir [file dirname [file normalize [info script]]]
source [file join $dir phext.tcl]
source [file join $dir json.tcl]

fconfigure stdin -encoding binary -translation binary
fconfigure stdout -encoding binary -translation binary

set IMPL tcl
set INDEX_COORD "1.1.1/1.1.1/1.1.1"
set KEYS_COORD "1.1.1/1.1.1/1.1.2"
set KH_COORD "1.1.1/1.1.1/1.1.3"
set KEY_UID "libphext telephone tcl"

proc tmpfile_with {data} {
    set path [file tempfile]
    set f [open $path w]
    fconfigure $f -encoding binary -translation binary
    puts -nonewline $f $data
    close $f
    return $path
}

proc sha256hex {data} {
    set p [tmpfile_with $data]
    set out [exec -ignorestderr sha256sum $p]
    file delete $p
    return [lindex [split $out] 0]
}

proc sha256file {path} {
    return [lindex [split [exec -ignorestderr sha256sum $path]] 0]
}

proc b64enc {data} { return [binary encode base64 $data] }
proc b64dec {s} { return [binary decode base64 $s] }

proc gnupg_home {} {
    if {[info exists ::env(TELEPHONE_GNUPGHOME)]} {
        return $::env(TELEPHONE_GNUPGHOME)
    }
    return [file join $::env(HOME) telephone-tcl gnupg]
}

proc run_gpg {args} {
    set home [gnupg_home]
    file mkdir $home
    catch {file attributes $home -permissions 0700}
    set saved ""
    if {[info exists ::env(GNUPGHOME)]} { set saved $::env(GNUPGHOME) }
    set ::env(GNUPGHOME) $home
    set rc [catch {exec -ignorestderr gpg --batch --yes --pinentry-mode loopback --passphrase "" {*}$args} out]
    if {$saved eq ""} { unset ::env(GNUPGHOME) } else { set ::env(GNUPGHOME) $saved }
    if {$rc} { error "gpg $args failed: $out" }
    return $out
}

proc do_keygen {} {
    set listing [run_gpg --list-keys --with-colons]
    if {![string match "*\npub:*" "\n$listing"]} {
        run_gpg --quick-generate-key $::KEY_UID ed25519 sign never
    }
    set pub [run_gpg --armor --export $::KEY_UID]
    if {![string match "*\n" $pub]} { append pub "\n" }
    return [json::jobj [list impl [json::jstr $::IMPL] pubkey [json::jstr $pub]]]
}

proc detach_sign {data} {
    set plain [tmpfile_with $data]
    set sig "$plain.asc"
    run_gpg --detach-sign --armor --local-user $::KEY_UID --output $sig $plain
    set f [open $sig r]; fconfigure $f -encoding binary -translation binary
    set out [read $f]; close $f
    file delete $plain $sig
    return $out
}

proc verify_signature {pubkeys data signature} {
    set td [file join [tmpdir] "tcl-verify-[pid]-[clock microseconds]"]
    file mkdir [file join $td gnupg]
    file attributes [file join $td gnupg] -permissions 0700
    set kf [file join $td keys.asc]; set pf [file join $td data]; set sf [file join $td sig.asc]
    foreach {p content} [list $kf $pubkeys $pf $data $sf $signature] {
        set f [open $p w]; fconfigure $f -encoding binary -translation binary
        puts -nonewline $f $content; close $f
    }
    set home [file join $td gnupg]
    set rc1 [catch {exec -ignorestderr gpg --batch --yes --homedir $home --import $kf} o1]
    set rc2 1; set o2 ""
    if {!$rc1} {
        set rc2 [catch {exec -ignorestderr gpg --batch --yes --homedir $home --verify $sf $pf} o2]
    }
    file delete -force $td
    if {$rc1} { error "gpg import: $o1" }
    if {$rc2} { error "gpg verify: $o2" }
    return 1
}

proc tmpdir {} {
    if {[info exists ::env(TMPDIR)]} { return $::env(TMPDIR) }
    return /tmp
}

proc wrap999 {v} { return [expr {($v - 1) % 999 + 1}] }

proc next_coord {c} {
    for {set d 8} {$d >= 0} {incr d -1} {
        if {[lindex $c $d] < 999} {
            lset c $d [expr {[lindex $c $d] + 1}]
            return $c
        }
        lset c $d 1
    }
    return $c
}

proc echo_value {ping} {
    set game ""; set round ""; set nonce ""
    if {[json::has $ping game]} { set game [json::str [json::get $ping game]] }
    if {[json::has $ping round]} {
        set r [json::get $ping round]
        set round [expr {[json::type $r] eq "num" ? [json::num $r] : [json::str $r]}]
    } elseif {[json::has $ping turn]} {
        set round [json::num [json::get $ping turn]]
    }
    if {[json::has $ping nonce]} { set nonce [json::str [json::get $ping nonce]] }
    return [sha256hex "$::IMPL|$game|$round|$nonce"]
}

proc elect_winner {position candidates turn} {
    set seed_input "$position[format %c [expr {$turn % 256}]][join $candidates ,]"
    set hex [sha256hex $seed_input]
    set b0 [scan [string range $hex 0 1] %x]
    return [lindex $candidates [expr {$b0 % [llength $candidates]}]]
}

proc choose_adventure {state position turn} {
    set pos [phext::coord_parse $position]
    set used [phext::explode $state]
    foreach rc {1.1.1/1.1.1/1.1.1 1.1.1/1.1.1/1.1.2 1.1.1/1.1.1/1.1.3} {
        dict set used $rc "x"
    }
    set seed_input "$position[format %c [expr {$turn % 256}]]$state"
    set hex [sha256hex $seed_input]
    set b1 [scan [string range $hex 2 3] %x]
    set b2 [scan [string range $hex 4 5] %x]
    set cand $pos
    set dim [expr {$b1 % 9}]
    lset cand $dim [wrap999 [expr {[lindex $cand $dim] + 1 + $b2 % 3}]]
    while {[dict exists $used [phext::coord_str $cand]]} {
        set cand [next_coord $cand]
    }
    set cs [phext::coord_str $cand]
    return [json::jobj [list op [json::jstr insert] coordinate [json::jstr $cs] \
        text [json::jstr "$::IMPL turn $turn at $cs"]]]
}

proc apply_step {state step} {
    set op [json::str [json::get $step op]]
    set coord [phext::coord_parse [json::str [json::get $step coordinate]]]
    set fetch_hash ""
    switch -- $op {
        insert {
            set state [phext::insert $state $coord [json::str [json::get $step text]]]
        }
        replace {
            set state [phext::replace $state $coord [json::str [json::get $step text]]]
        }
        remove { set state [phext::remove $state $coord] }
        fetch { set fetch_hash [sha256hex [phext::fetch $state $coord]] }
    }
    set resp [list state_b64 [json::jstr [b64enc $state]] \
        state_sha256 [json::jstr [sha256hex $state]]]
    if {$fetch_hash ne ""} {
        lappend resp fetch_sha256 [json::jstr $fetch_hash]
    } else {
        lappend resp fetch_sha256 [json::jnull]
    }
    return [list $state [json::jobj $resp]]
}

# ---- validate: cache for the driver's form ----
set cache_map ""
set cache_set 0

proc do_init {state} {
    set ::cache_map [phext::explode $state]
    set ::cache_set 1
    return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr pass]]]
}

proc vfail {detail} {
    return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr fail] \
        detail [json::jstr $detail]]]
}

proc do_validate {req state} {
    set step [json::get $req step]
    set op [json::str [json::get $step op]]
    if {[json::has $req prior_state]} {
        if {$op ne "insert"} { return [vfail "step op is not insert"] }
        set coord_s [json::str [json::get $step coordinate]]
        set coord [phext::coord_parse $coord_s]
        set text [json::str [json::get $step text]]
        if {[phext::fetch $state $coord] ne $text} {
            return [vfail "placed scroll absent or content differs at $coord_s"]
        }
        set prior [b64dec [json::str [json::get $req prior_state]]]
        if {[phext::fetch $prior $coord] ne ""} {
            return [vfail "coordinate was not unused in the prior state"]
        }
        set before [phext::explode $prior]
        set after [phext::explode $state]
        if {[dict size $after] != [dict size $before] + 1} {
            return [vfail "scroll count did not grow by exactly one"]
        }
        dict for {cs t} $before {
            if {![dict exists $after $cs] || [dict get $after $cs] ne $t} {
                return [vfail "a prior scroll was overwritten: $cs"]
            }
        }
        return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr pass] \
            detail [json::jstr "placed at unused coordinate; all prior scrolls intact"]]]
    }
    # driver form: cached prior map + event_coord + index_line
    if {!$::cache_set} { return [vfail "validate called before init"] }
    set new [phext::explode $state]
    set coord_s [json::str [json::get $step coordinate]]
    set ev_s [json::str [json::get $req event_coord]]
    set index_line [json::str [json::get $req index_line]]
    set text [json::str [json::get $step text]]
    if {![dict exists $new $coord_s] || [dict get $new $coord_s] ne $text} {
        return [vfail "placed scroll missing or altered"]
    }
    dict for {cs t} $::cache_map {
        if {$cs eq $::INDEX_COORD} { continue }
        if {![dict exists $new $cs] || [dict get $new $cs] ne $t} {
            return [vfail "prior scroll overwritten at $cs"]
        }
    }
    dict for {cs t} $new {
        if {![dict exists $::cache_map $cs] && $cs ne $coord_s && $cs ne $ev_s} {
            return [vfail "unexpected new scroll at $cs"]
        }
    }
    set idx [expr {[dict exists $new $::INDEX_COORD] ? [dict get $new $::INDEX_COORD] : ""}]
    set idx_t [string trimright $idx "\n"]
    set line_t [string trimright $index_line "\n"]
    if {[string range $idx_t [expr {[string length $idx_t] - [string length $line_t]}] end] ne $line_t} {
        return [vfail "index does not record the placement"]
    }
    set ::cache_map $new
    return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr pass]]]
}

proc do_verify {state pubkeys} {
    set fail_count 0
    set scrolls [phext::explode $state]
    if {![dict exists $scrolls $::KEYS_COORD] || [dict get $scrolls $::KEYS_COORD] eq ""} {
        return [verify_fail 0 "no public-keys scroll at 1.1.1/1.1.1/1.1.2"]
    }
    set keys_text [dict get $scrolls $::KEYS_COORD]
    if {[string trimright $pubkeys " \t\r\n"] ne [string trimright $keys_text " \t\r\n"]} {
        return [verify_fail 0 "supplied pubkeys do not match the inscribed keys scroll"]
    }
    if {![dict exists $scrolls $::KH_COORD]} {
        return [verify_fail 0 "no keys-hash scroll at 1.1.1/1.1.1/1.1.3"]
    }
    if {[string trim [dict get $scrolls $::KH_COORD]] ne [sha256hex $keys_text]} {
        return [verify_fail 0 "keys-hash scroll does not match the keys scroll"]
    }
    set index [dict create]
    if {[dict exists $scrolls $::INDEX_COORD]} {
        foreach line [split [dict get $scrolls $::INDEX_COORD] "\n"] {
            set line [string trim $line]
            if {$line eq "" || [string match "#*" $line]} { continue }
            set fields [regexp -inline -all {\S+} $line]
            if {[llength $fields] != 4} {
                return [verify_fail 0 "malformed index line: $line"]
            }
            dict set index [lindex $fields 1] $fields
        }
    }
    set checked 0
    set seen [dict create]
    set prev_hash ""
    for {set seq 1} {1} {incr seq} {
        set ev_coord [phext::coord_str [list 1 1 1 1 1 1 2 1 $seq]]
        if {![dict exists $scrolls $ev_coord]} break
        set ev_text [dict get $scrolls $ev_coord]
        if {[catch {json::parse $ev_text} ev]} {
            return [verify_fail $checked "event $seq is not JSON"]
        }
        if {![json::has $ev body]} {
            return [verify_fail $checked "event $seq lacks a body object"]
        }
        set body [json::get $ev body]
        if {$seq == 1} {
            if {[json::type [json::get $ev prev]] ne "null"} {
                return [verify_fail $checked "event 1 prev is not null"]
            }
        } else {
            set p [json::get $ev prev]
            if {[json::type $p] ne "str" || [json::str $p] ne $prev_hash} {
                return [verify_fail $checked "event chain broken at seq $seq"]
            }
        }
        set prev_hash [sha256hex [json::canon $body]]
        if {![json::has $body type] || [json::str [json::get $body type]] ne "placement"} {
            continue
        }
        foreach field {coord text_sha256 file_sha256 att} {
            if {![json::has $body $field]} {
                return [verify_fail $checked "event $seq lacks $field"]
            }
        }
        set coord_s [json::str [json::get $body coord]]
        set text_hash [json::str [json::get $body text_sha256]]
        set file_hash [json::str [json::get $body file_sha256]]
        set att_b64 [json::str [json::get $body att]]
        set turn_raw [json::num [json::get $body turn]]
        set actor [json::str [json::get $body actor]]
        if {[dict exists $seen $coord_s]} {
            return [verify_fail $checked "coordinate reused at $coord_s"]
        }
        if {![dict exists $scrolls $coord_s]} {
            return [verify_fail $checked "placement missing at $coord_s"]
        }
        if {[sha256hex [dict get $scrolls $coord_s]] ne $text_hash} {
            return [verify_fail $checked "placement hash mismatch at $coord_s"]
        }
        if {![dict exists $index $coord_s]} {
            return [verify_fail $checked "index mismatch at $coord_s"]
        }
        set ie [dict get $index $coord_s]
        if {[lindex $ie 2] ne $text_hash || [lindex $ie 0] ne $turn_raw || [lindex $ie 3] ne $actor} {
            return [verify_fail $checked "index mismatch at $coord_s"]
        }
        set desc [json::jobj [list turn [json::get $body turn] \
            coordinate [json::jstr $coord_s] scroll_sha256 [json::jstr $text_hash] \
            file_sha256 [json::jstr $file_hash]]]
        if {[catch {verify_signature $pubkeys [json::canon $desc] [b64dec $att_b64]} err]} {
            return [verify_fail $checked "event $seq signature: $err"]
        }
        dict set seen $coord_s 1
        incr checked
    }
    if {$checked == 0} { return [verify_fail 0 "no placement events found"] }
    dict for {cs _} $index {
        if {![dict exists $seen $cs]} {
            return [verify_fail $checked "index lists a placement with no event: $cs"]
        }
    }
    return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr pass] \
        placements_checked [json::jnum $checked] first_failure [json::jnull]]]
}

proc verify_fail {n msg} {
    return [json::jobj [list impl [json::jstr $::IMPL] verdict [json::jstr fail] \
        placements_checked [json::jnum $n] \
        first_failure [json::jobj [list detail [json::jstr $msg]]]]]
}

proc req_state {req} {
    if {[json::has $req state]} { return [b64dec [json::str [json::get $req state]]] }
    if {[json::has $req state_b64]} { return [b64dec [json::str [json::get $req state_b64]]] }
    return ""
}

proc handle {line} {
    set req [json::parse $line]
    set cmd [json::str [json::get $req cmd]]
    switch -- $cmd {
        id { return [json::jobj [list impl [json::jstr $::IMPL]]] }
        echo {
            return [json::jobj [list impl [json::jstr $::IMPL] \
                echo [json::jstr [echo_value [json::get $req ping]]]]]
        }
        elect {
            set cands {}
            foreach item [lindex [json::get $req candidates] 1] {
                lappend cands [json::str $item]
            }
            if {![llength $cands]} { error "elect: no candidates" }
            set winner [elect_winner [json::str [json::get $req position]] $cands \
                [json::num [json::get $req turn]]]
            return [json::jobj [list elect [json::jstr $winner]]]
        }
        choose {
            return [choose_adventure [req_state $req] \
                [json::str [json::get $req position]] [json::num [json::get $req turn]]]
        }
        apply {
            lassign [apply_step [req_state $req] [json::get $req step]] _ resp
            return $resp
        }
        keygen { return [do_keygen] }
        attest {
            set desc [json::get $req descriptor]
            set sig [detach_sign [json::canon $desc]]
            return [json::jobj [list signature [json::jstr $sig]]]
        }
        init { return [do_init [req_state $req]] }
        validate { return [do_validate $req [req_state $req]] }
        verify {
            return [do_verify [req_state $req] [json::str [json::get $req pubkeys]]]
        }
        default { error "unknown cmd $cmd" }
    }
}

# Game-scale framing (2026-11-24): lines over 8 KB may arrive
# gzip-framed as "GZ1:" + base64(gzip(line)) -- the fleet-ssh channel
# is ~25-70 KB/s and raw base64 state lines took minutes at 1,000
# placements. tclsh framing shells to the system base64(1)/gzip(1)
# on temp files (mirrors the lua/fortran ports). Lossless; plain
# lines unchanged.
proc gz_unframe {b64} {
    set fb [tmpfile_with $b64]
    set fo "$fb.out"
    exec -ignorestderr sh -c "base64 -d '$fb' | gzip -dc > '$fo'"
    set f [open $fo r]
    fconfigure $f -encoding binary -translation binary
    set data [read $f]
    close $f
    file delete $fb $fo
    return $data
}
proc gz_frame {data} {
    set fi [tmpfile_with $data]
    set fb "$fi.b64"
    exec -ignorestderr sh -c "gzip -c '$fi' | base64 -w0 > '$fb'"
    set f [open $fb r]
    fconfigure $f -encoding binary -translation binary
    set b64 [read $f]
    close $f
    file delete $fi $fb
    return "GZ1:[string trim $b64]"
}

proc emit {v} {
    puts stdout [json::canon $v]
    flush stdout
}

if {[lindex $argv 0] eq "serve"} {
    while {[gets stdin line] >= 0} {
        if {[string trim $line] eq ""} { continue }
        if {[string range $line 0 3] eq "GZ1:"} {
            set line [gz_unframe [string range $line 4 end]]
        }
        if {[catch {handle $line} resp]} {
            set out [json::canon [json::jobj [list error [json::jstr $resp]]]]
        } else {
            set out [json::canon $resp]
        }
        if {[string length $out] > 8192} { set out [gz_frame $out] }
        puts stdout $out
        flush stdout
    }
} else {
    set line [read stdin]
    set line [string trimright $line "\r\n"]
    if {[catch {handle $line} resp]} {
        puts stderr $resp
        exit 1
    }
    emit $resp
}
