# json.tcl -- minimal JSON parser + canonical serializer in pure Tcl.
# Canonical form matches the harness's canon (Python json.dumps with
# sort_keys=True, separators=(",",":"), ensure_ascii=True): compact,
# keys sorted, non-ASCII escaped as \uXXXX. Number literals are kept
# verbatim from the source text so float formatting round-trips
# exactly (the same trick the Go port uses with json.Number).
#
# Value representation: a two-element list {type payload}:
#   str  -> decoded string        num -> raw literal text
#   bool -> 0/1                   null -> {}
#   arr  -> list of values        obj -> flat list {k1 v1 k2 v2 ...}

namespace eval json {
    variable S ""; variable I 0; variable N 0
    variable LB [format %c 123]; variable RB [format %c 125]
    variable LSQ [format %c 91]; variable RSQ [format %c 93]
    variable QUOTE [format %c 34]
}

proc json::parse {text} {
    variable S; variable I; variable N
    set S $text; set I 0; set N [string length $text]
    set v [_value]
    _ws
    if {$I != $N} { error "trailing data after JSON value" }
    return $v
}

proc json::_ws {} {
    variable S; variable I; variable N
    while {$I < $N} {
        set c [string index $S $I]
        if {$c eq " " || $c eq "\t" || $c eq "\n" || $c eq "\r"} { incr I } else break
    }
}

proc json::_value {} {
    variable S; variable I; variable N
    variable LB; variable LSQ; variable QUOTE
    _ws
    set c [string index $S $I]
    if {$c eq $LB} { return [_object] }
    if {$c eq $LSQ} { return [_array] }
    if {$c eq $QUOTE} { return [list str [_string]] }
    if {$c eq "t"} { incr I 4; return [list bool 1] }
    if {$c eq "f"} { incr I 5; return [list bool 0] }
    if {$c eq "n"} { incr I 4; return [list null {}] }
    set start $I
    while {$I < $N} {
        set ch [string index $S $I]
        if {[string match {[-+0-9.eE]} $ch]} { incr I } else break
    }
    if {$I == $start} { error "bad JSON value at $I" }
    return [list num [string range $S $start [expr {$I - 1}]]]
}

proc json::_string {} {
    variable S; variable I; variable N
    incr I ;# opening quote
    set out ""
    while {$I < $N} {
        set c [string index $S $I]
        if {$c eq "\""} { incr I; return $out }
        if {$c eq "\\"} {
            incr I
            set e [string index $S $I]
            switch -- $e {
                {"} { append out "\"" }
                "\\" { append out "\\" }
                "/" { append out "/" }
                "b" { append out "\b" }
                "f" { append out "\f" }
                "n" { append out "\n" }
                "r" { append out "\r" }
                "t" { append out "\t" }
                "u" {
                    set hex [string range $S [expr {$I + 1}] [expr {$I + 4}]]
                    set code [scan $hex %x]
                    incr I 4
                    if {$code >= 0xD800 && $code <= 0xDBFF &&
                        [string range $S $I [expr {$I + 1}]] eq "\\u"} {
                        set hex2 [string range $S [expr {$I + 2}] [expr {$I + 5}]]
                        set lo [scan $hex2 %x]
                        if {$lo >= 0xDC00 && $lo <= 0xDFFF} {
                            set code [expr {0x10000 + (($code - 0xD800) << 10) + ($lo - 0xDC00)}]
                            incr I 6
                        }
                    }
                    append out [format %c $code]
                }
                default { error "bad escape \\$e" }
            }
            incr I
            continue
        }
        append out $c
        incr I
    }
    error "unterminated string"
}

proc json::_object {} {
    variable S; variable I
    incr I
    set pairs {}
    _ws
    variable RB
    if {[string index $S $I] eq $RB} { incr I; return [list obj {}] }
    while {1} {
        _ws
        set k [_string]
        _ws
        incr I
        set v [_value]
        lappend pairs $k $v
        _ws
        set c [string index $S $I]
        incr I
        if {$c eq $RB} break
        if {$c ne ","} { error "expected comma or end of object" }
    }
    return [list obj $pairs]
}

proc json::_array {} {
    variable S; variable I
    incr I ;# [
    set items {}
    _ws
    if {[string index $S $I] eq "]"} { incr I; return [list arr {}] }
    while {1} {
        lappend items [_value]
        _ws
        set c [string index $S $I]
        incr I
        if {$c eq "]"} break
        if {$c ne ","} { error "expected , or ] in array" }
    }
    return [list arr $items]
}

# ---- accessors ----
proc json::type {v} { return [lindex $v 0] }
proc json::str {v} {
    if {[lindex $v 0] ne "str"} { error "not a string" }
    return [lindex $v 1]
}
proc json::num {v} { return [lindex $v 1] }
proc json::get {v key} {
    foreach {k val} [lindex $v 1] {
        if {$k eq $key} { return $val }
    }
    return ""
}
proc json::has {v key} {
    foreach {k val} [lindex $v 1] {
        if {$k eq $key} { return 1 }
    }
    return 0
}
# constructors
proc json::jstr {s} { return [list str $s] }
proc json::jnum {n} { return [list num $n] }
proc json::jbool {b} { return [list bool [expr {$b ? 1 : 0}]] }
proc json::jnull {} { return [list null {}] }
proc json::jarr {items} { return [list arr $items] }
proc json::jobj {pairs} { return [list obj $pairs] }

# ---- canonical serializer ----
proc json::canon {v} {
    switch -- [lindex $v 0] {
        "null" { return "null" }
        "bool" { return [expr {[lindex $v 1] ? "true" : "false"}] }
        "num" { return [lindex $v 1] }
        "str" { return [_canon_str [lindex $v 1]] }
        "arr" {
            set parts {}
            foreach item [lindex $v 1] { lappend parts [canon $item] }
            return "\[[join $parts ,]\]"
        }
        "obj" {
            set d [dict create]
            foreach {k val} [lindex $v 1] { dict set d $k $val }
            set parts {}
            foreach k [lsort [dict keys $d]] {
                lappend parts "[_canon_str $k]:[canon [dict get $d $k]]"
            }
            return "{[join $parts ,]}"
        }
    }
    error "bad json value"
}

proc json::_canon_str {s} {
    set out "\""
    foreach ch [split $s ""] {
        set code [scan $ch %c]
        switch -- $ch {
            "\"" { append out "\\\"" }
            "\\" { append out "\\\\" }
            "\b" { append out "\\b" }
            "\f" { append out "\\f" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            "\t" { append out "\\t" }
            default {
                if {$code < 0x20 || $code > 0x7E} {
                    if {$code > 0xFFFF} {
                        set hi [expr {0xD800 + (($code - 0x10000) >> 10)}]
                        set lo [expr {0xDC00 + (($code - 0x10000) & 0x3FF)}]
                        append out [format "\\u%04x\\u%04x" $hi $lo]
                    } else {
                        append out [format "\\u%04x" $code]
                    }
                } else {
                    append out $ch
                }
            }
        }
    }
    append out "\""
    return $out
}
