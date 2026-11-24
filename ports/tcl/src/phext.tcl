# phext.tcl -- libphext port for Tcl (0.6.1 parity semantics; normative
# reference: libphext-py). Phext is a 9-dimensional plain-text format:
# scrolls of text addressed by a Coordinate, separated in the byte
# stream by dimension-break bytes.
#
# Dimension breaks (dimension index -> byte):
#   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
#   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
#   8 scroll 0x17.
# A break at dimension d increments component d and resets all lower
# components to 1. Scroll text is a maximal run of non-break bytes; the
# newline byte 0x0A is ordinary text, NOT a break. All operations are
# on byte strings (channels in binary encoding); text is never
# interpreted as UTF-8.
#
# API (namespace phext):
#   coord_parse / coord_str / coord_cmp      -- "a.b.c/d.e.f/g.h.i"
#   phokenize data   -> ordered list of {coordList text} pairs
#   dephokenize pairs -> canonical phext bytes
#   normalize data   -> phokenize + dephokenize
#   fetch data coord -> text or ""
#   insert / replace / remove data coord text?
#        insert concatenates old+new at an existing coordinate;
#        replace overwrites; remove is COORDINATE-PRESERVING: the
#        scroll's text is deleted and every other scroll keeps its
#        coordinate (the delimiters needed to reach it stay).
#   explode data -> dict coordStr -> text ; implode dict -> bytes
# Classes: DynamicPhext (dynamic-array store, capacity doubles when
# full, halves at quarter-full) and TransitivePhext (branching hash map,
# one dict layer per dimension, depth 9) -- semantics mirror
# libphext-py's phext/dynamic.py and phext/transitive.py: serialize()
# is byte-identical to the buffer API over any edit sequence; stores
# never hold an empty scroll (replace "" removes, insert "" is a no-op).

namespace eval phext {
    variable breaks
    set breaks {}
    foreach b {1 31 30 29 28 26 25 24 23} { lappend breaks [format %c $b] }
    variable isbreak
    array set isbreak {}
    for {set d 0} {$d < 9} {incr d} { set isbreak([lindex $breaks $d]) $d }
}

proc phext::coord_parse {s} {
    set out {}
    foreach grp [split $s /] {
        foreach p [split $grp .] {
            if {![string is integer -strict $p] || $p < 1} {
                error "invalid coordinate $s"
            }
            lappend out $p
        }
    }
    if {[llength $out] != 9} { error "invalid coordinate $s" }
    return $out
}

proc phext::coord_str {c} {
    return [format "%d.%d.%d/%d.%d.%d/%d.%d.%d" {*}$c]
}

proc phext::coord_cmp {a b} {
    for {set i 0} {$i < 9} {incr i} {
        set x [lindex $a $i]; set y [lindex $b $i]
        if {$x < $y} { return -1 }
        if {$x > $y} { return 1 }
    }
    return 0
}

proc phext::_apply_break {coordVar d} {
    upvar $coordVar c
    lset c $d [expr {[lindex $c $d] + 1}]
    for {set k [expr {$d + 1}]} {$k < 9} {incr k} { lset c $k 1 }
}

proc phext::phokenize {data} {
    variable breaks
    variable isbreak
    set out {}
    set coord {1 1 1 1 1 1 1 1 1}
    set n [string length $data]
    set i 0
    while {$i < $n} {
        set ch [string index $data $i]
        if {[info exists isbreak($ch)]} {
            _apply_break coord $isbreak($ch)
            incr i
            continue
        }
        # find the end of this text run: earliest break at or after i
        set end $n
        foreach b $breaks {
            set j [string first $b $data $i]
            if {$j >= 0 && $j < $end} { set end $j }
        }
        lappend out [list $coord [string range $data $i [expr {$end - 1}]]]
        set i $end
    }
    return $out
}

proc phext::_advance {locVar target} {
    variable breaks
    upvar $locVar loc
    if {[coord_cmp $loc $target] >= 0} { return "" }
    set d 0
    while {[lindex $loc $d] == [lindex $target $d]} { incr d }
    set out ""
    for {set k [lindex $loc $d]} {$k < [lindex $target $d]} {incr k} {
        append out [lindex $breaks $d]
    }
    set reached $loc
    lset reached $d [lindex $target $d]
    for {set j [expr {$d + 1}]} {$j < 9} {incr j} { lset reached $j 1 }
    for {set lower [expr {$d + 1}]} {$lower < 9} {incr lower} {
        for {set k 1} {$k < [lindex $target $lower]} {incr k} {
            append out [lindex $breaks $lower]
        }
        lset reached $lower [lindex $target $lower]
    }
    set loc $reached
    return $out
}

proc phext::dephokenize {pairs} {
    set out ""
    set loc {1 1 1 1 1 1 1 1 1}
    foreach pair $pairs {
        lassign $pair coord text
        append out [_advance loc $coord]
        append out $text
    }
    return $out
}

proc phext::normalize {data} { return [dephokenize [phokenize $data]] }

proc phext::fetch {data coord} {
    foreach pair [phokenize $data] {
        if {[lindex $pair 0] eq $coord} { return [lindex $pair 1] }
    }
    return ""
}

proc phext::_update {data coord text overwrite} {
    set result {}
    set next [list $coord $text]
    set appended 0
    foreach pair [phokenize $data] {
        lassign $pair pc ptext
        if {!$appended && [coord_cmp $pc $coord] > 0} {
            lappend result $next; set appended 1
        }
        if {!$appended && $pc eq $coord} {
            if {!$overwrite} {
                lset next 1 "$ptext$text"
            }
            lappend result $next; set appended 1
            continue
        }
        lappend result $pair
    }
    if {!$appended} { lappend result $next }
    return [dephokenize $result]
}

proc phext::insert {data coord text} { return [_update $data $coord $text 0] }
proc phext::replace {data coord text} { return [_update $data $coord $text 1] }

proc phext::remove {data coord} {
    # Coordinate-preserving: empty the scroll, then normalize. Later
    # scrolls keep their coordinates (dephokenize re-emits the breaks
    # needed to reach them); no scroll shifts position.
    return [normalize [_update $data $coord "" 1]]
}

proc phext::explode {data} {
    set m [dict create]
    foreach pair [phokenize $data] {
        dict set m [coord_str [lindex $pair 0]] [lindex $pair 1]
    }
    return $m
}

proc phext::implode {m} {
    set coords {}
    dict for {cs text} $m { lappend coords [coord_parse $cs] }
    set coords [lsort -command phext::coord_cmp $coords]
    set pairs {}
    foreach c $coords {
        lappend pairs [list $c [dict get $m [coord_str $c]]]
    }
    return [dephokenize $pairs]
}

# ---------------------------------------------------------------------
# DynamicPhext -- dynamic-array scroll store. Capacity starts at 1,
# doubles when full on append, halves when the load drops to one
# quarter (never at half full -- that thrashes). Kept in strictly
# increasing coordinate order; serialize() is byte-identical to the
# buffer API. Resize instrumentation mirrors the Python original.
oo::class create phext::DynamicPhext {
    variable data n capacity shrinkDiv resizeCount elementsCopied
    constructor {{buffer ""} {shrink_divisor 4}} {
        if {$shrink_divisor < 2} { error "shrink_divisor must be >= 2" }
        set shrinkDiv $shrink_divisor
        set capacity 1; set n 0; set data {}
        set resizeCount 0; set elementsCopied 0
        if {$buffer ne ""} { my load $buffer }
    }
    method _resize {newcap} {
        set capacity $newcap
        incr resizeCount
        incr elementsCopied $n
    }
    method _grow_if_full {} {
        if {$n == $capacity} { my _resize [expr {2 * $capacity}] }
    }
    method _shrink_if_sparse {} {
        if {$capacity > 1 && $n <= $capacity / $shrinkDiv} {
            my _resize [expr {max(1, $capacity / 2)}]
        }
    }
    method capacity {} { return $capacity }
    method resize_count {} { return $resizeCount }
    method elements_copied {} { return $elementsCopied }
    method len {} { return $n }
    method load {buffer} {
        set capacity 1; set n 0; set data {}
        set resizeCount 0; set elementsCopied 0
        foreach pair [phext::phokenize $buffer] { my _push $pair }
    }
    method _push {pair} {
        my _grow_if_full
        lappend data $pair
        incr n
    }
    method scrolls {} { return $data }
    method serialize {} { return [phext::dephokenize $data] }
    method _find {coord} {
        set lo 0; set hi $n
        while {$lo < $hi} {
            set mid [expr {($lo + $hi) / 2}]
            set cmp [phext::coord_cmp [lindex $data $mid 0] $coord]
            if {$cmp < 0} { set lo [expr {$mid + 1}] } \
            elseif {$cmp > 0} { set hi $mid } \
            else { return [list $mid 1] }
        }
        return [list $lo 0]
    }
    method fetch {coord} {
        lassign [my _find $coord] idx found
        return [expr {$found ? [lindex $data $idx 1] : ""}]
    }
    method contains {coord} { return [lindex [my _find $coord] 1] }
    method append {coord text} {
        if {$n > 0 && [phext::coord_cmp $coord [lindex $data end 0]] <= 0} {
            error "append requires a coordinate past the current tail"
        }
        if {$text eq ""} { return }
        my _push [list $coord $text]
    }
    method update {coord text overwrite} {
        lassign [my _find $coord] idx found
        if {$found} {
            if {$text eq ""} {
                if {$overwrite} { my _remove_at $idx }
                return
            }
            if {!$overwrite} { set text "[lindex $data $idx 1]$text" }
            lset data $idx [list $coord $text]
            return
        }
        if {$text eq ""} { return }
        my _grow_if_full
        set data [linsert $data $idx [list $coord $text]]
        incr n
    }
    method insert {coord text} { my update $coord $text 0 }
    method replace {coord text} { my update $coord $text 1 }
    method _remove_at {idx} {
        set data [lreplace $data $idx $idx]
        incr n -1
        my _shrink_if_sparse
    }
    method remove {coord} {
        lassign [my _find $coord] idx found
        if {$found} { my _remove_at $idx }
    }
}

# ---------------------------------------------------------------------
# TransitivePhext -- branching hash-map store: one dict layer per
# coordinate dimension (depth 9, derived from the coordinate length),
# leaves holding scroll text. Serialization walks the hierarchy in
# sorted key order at every level = coordinate order.
oo::class create phext::TransitivePhext {
    variable root count depth
    constructor {{buffer ""}} {
        set depth 9
        set root [dict create]; set count 0
        if {$buffer ne ""} { my load $buffer }
    }
    method depth {} { return $depth }
    method len {} { return $count }
    method load {buffer} {
        set root [dict create]; set count 0
        foreach pair [phext::phokenize $buffer] {
            my _put [lindex $pair 0] [lindex $pair 1]
        }
    }
    method _put {key value} {
        set nodeVar root
        # walk/create nested dicts via a recursive helper on values
        set created [my _put_rec root $key 0 $value]
        if {$created} { incr count }
    }
    method _put_rec {nodeVar key level value} {
        upvar $nodeVar node
        set comp [lindex $key $level]
        if {$level == $depth - 1} {
            set created [expr {![dict exists $node $comp]}]
            dict set node $comp $value
            return $created
        }
        if {![dict exists $node $comp]} { dict set node $comp [dict create] }
        set child [dict get $node $comp]
        set created [my _put_rec child $key [expr {$level + 1}] $value]
        dict set node $comp $child
        return $created
    }
    method _fetch_rec {node key level} {
        set comp [lindex $key $level]
        if {![dict exists $node $comp]} { return [list 0 ""] }
        if {$level == $depth - 1} { return [list 1 [dict get $node $comp]] }
        return [my _fetch_rec [dict get $node $comp] $key [expr {$level + 1}]]
    }
    method fetch {coord} {
        lassign [my _fetch_rec $root $coord 0] found val
        return [expr {$found ? $val : ""}]
    }
    method contains {coord} { return [lindex [my _fetch_rec $root $coord 0] 0] }
    method _remove_rec {nodeVar key level} {
        upvar $nodeVar node
        set comp [lindex $key $level]
        if {![dict exists $node $comp]} { return 0 }
        if {$level == $depth - 1} {
            dict unset node $comp
            return 1
        }
        set child [dict get $node $comp]
        set removed [my _remove_rec child $key [expr {$level + 1}]]
        if {$removed} {
            if {[dict size $child] == 0} { dict unset node $comp } \
            else { dict set node $comp $child }
        }
        return $removed
    }
    method remove {coord} {
        if {[my _remove_rec root $coord 0]} { incr count -1 }
    }
    method _items_rec {node prefix outVar} {
        upvar $outVar out
        foreach comp [lsort -integer [dict keys $node]] {
            set val [dict get $node $comp]
            if {[llength $prefix] == $depth - 1} {
                lappend out [list [concat $prefix $comp] $val]
            } else {
                my _items_rec $val [concat $prefix $comp] out
            }
        }
    }
    method scrolls {} {
        set out {}
        my _items_rec $root {} out
        return $out
    }
    method serialize {} { return [phext::dephokenize [my scrolls]] }
    method update {coord text overwrite} {
        if {$text eq ""} {
            if {$overwrite} { my remove $coord }
            return
        }
        if {!$overwrite} {
            lassign [my _fetch_rec $root $coord 0] found existing
            if {$found} { set text "$existing$text" }
        }
        my _put $coord $text
    }
    method insert {coord text} { my update $coord $text 0 }
    method replace {coord text} { my update $coord $text 1 }
    method append {coord text} { my insert $coord $text }
}
