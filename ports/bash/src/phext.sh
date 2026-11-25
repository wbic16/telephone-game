# phext.sh -- libphext port for Bash (0.6.1 parity semantics; normative
# reference: libphext-py). Phext is a 9-dimensional plain-text format:
# scrolls of text addressed by a Coordinate, separated in the byte
# stream by dimension-break bytes.
#
# Dimension breaks (dimension index -> byte):
#   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
#   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
#   8 scroll 0x17.
# A break at dimension d increments component d and resets all lower
# components to 1. Scroll text is a maximal run of non-break bytes;
# the newline byte 0x0A is ordinary text, NOT a break. Must run under
# LC_ALL=C so string indexing and lengths are bytes (the hub launcher
# exports it).
#
# Remove is COORDINATE-PRESERVING: the scroll's text is deleted and
# every other scroll keeps its coordinate (the delimiters needed to
# reach it stay); later scrolls do NOT shift.
#
# Coordinates are handled internally as comma-joined strings
# "a,b,c,d,e,f,g,h,i"; the string form is "a.b.c/d.e.f/g.h.i".
# Because command substitution strips trailing newlines (and newline
# is ordinary scroll text), functions return byte strings through
# globals (RET / named OUT variables), never through stdout.
#
# API:
#   coord_parse STR -> CP (comma coord or ""); coord_str CC -> CS
#   coord_cmp A B -> CMP (-1/0/1)
#   phokenize DATA -> PH_N, PH_COORD[], PH_TEXT[]
#   dephokenize -> RET (from PH_* slots)
#   normalize DATA -> RET; fetch DATA CC -> RET
#   insert/replace/remove DATA CC TEXT -> RET
#   explode DATA -> EXPL assoc (string-coord keys); implode -> RET
#   DynamicPhext: dyn_* over a capacity-managed indexed array
#     (doubles when full, halves at quarter-full), mirroring
#     phext/dynamic.py; TransitivePhext: trn_* over a branching hash
#     map (assoc arrays keyed by coordinate prefixes, one level per
#     dimension, depth 9), mirroring phext/transitive.py. Both stores
#     serialize byte-identically to the buffer API and never hold an
#     empty scroll (replace "" removes, insert "" is a no-op).

declare -A EXPL=() TRN_LEAF=() TRN_NODE=()
BRK=$'\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17'
declare -a BRKBYTES=($'\x01' $'\x1f' $'\x1e' $'\x1d' $'\x1c' $'\x1a' $'\x19' $'\x18' $'\x17')
declare -A BRKDIM=()
for _d in 0 1 2 3 4 5 6 7 8; do BRKDIM[${BRKBYTES[$_d]}]=$_d; done

coord_parse() {
    # $1 = "a.b.c/d.e.f/g.h.i" -> CP comma form, or "" if invalid
    local s=$1 g1 g2 g3 p out="" i
    IFS='/' read -r g1 g2 g3 <<< "$s"
    if [[ -z ${g3:-} || $s == */*/*/* ]]; then CP=""; return; fi
    for g in "$g1" "$g2" "$g3"; do
        IFS='.' read -ra p <<< "$g"
        if [[ ${#p[@]} -ne 3 ]]; then CP=""; return; fi
        for i in 0 1 2; do
            if ! [[ ${p[$i]} =~ ^[0-9]+$ ]] || (( 10#${p[$i]} < 1 )); then CP=""; return; fi
            out+="${out:+,}$((10#${p[$i]}))"
        done
    done
    CP=$out
}

coord_str() {
    local -a a
    IFS=',' read -ra a <<< "$1"
    CS="${a[0]}.${a[1]}.${a[2]}/${a[3]}.${a[4]}.${a[5]}/${a[6]}.${a[7]}.${a[8]}"
}

coord_cmp() {
    local -a x y
    IFS=',' read -ra x <<< "$1"
    IFS=',' read -ra y <<< "$2"
    local i
    for i in 0 1 2 3 4 5 6 7 8; do
        if (( x[i] < y[i] )); then CMP=-1; return; fi
        if (( x[i] > y[i] )); then CMP=1; return; fi
    done
    CMP=0
}

_apply_break() {
    # W array (global, 1-based components in W[1..9]); $1 = dimension
    local d=$1 k
    W[$((d + 1))]=$(( ${W[$((d + 1))]} + 1 ))
    for (( k = d + 2; k <= 9; k++ )); do W[$k]=1; done
}

_walker_str() {
    WS="${W[1]},${W[2]},${W[3]},${W[4]},${W[5]},${W[6]},${W[7]},${W[8]},${W[9]}"
}

_encode_breaks() {
    # $1 data -> ENC: escape the sentinel byte 0x02 by doubling and
    # encode each dimension break as 0x02<digit>. The substitutions
    # run in 16 KB chunks, joined in one expansion: a whole-string
    # ${var//pat/rep} pass costs per-replacement x whole-string, so
    # on a game-scale state (~1.3M break bytes in 2.2 MB) the nine
    # unchunked passes took ~67 s where the chunked form takes ~2 s,
    # byte-identical (all patterns are single bytes, so no match can
    # straddle a chunk boundary).
    local data=$1 n=${#1} pos=0 chunk d i
    local -a pieces=()
    ENC=""
    # Run-length tiers (only when the data holds no literal 0x02 --
    # see phokenize): precompute, per dimension, the pattern of ten
    # consecutive single-break markers and its token replacement.
    # T1 letters a-i = x10, T2 letters j-r = x100, T3 letters A-I =
    # x1000. A tier pattern that straddles a chunk boundary simply
    # does not collapse there; the uncollapsed markers are still
    # valid single-break markers in the joined stream, so chunking
    # stays exact.
    local tiers=0
    local -a TP1=() TP2=() TP3=() TR1=() TR2=() TR3=()
    local T1S="abcdefghi" T2S="jklmnopqr" T3S="ABCDEFGHI"
    if [[ $data != *$'\x02'* ]]; then
        tiers=1
        for d in 0 1 2 3 4 5 6 7 8; do
            TP1[$d]=""; TP2[$d]=""; TP3[$d]=""
            for (( i = 0; i < 10; i++ )); do
                TP1[$d]+=$'\x02'"$d"
                TP2[$d]+=$'\x02'"${T1S:$d:1}"
                TP3[$d]+=$'\x02'"${T2S:$d:1}"
            done
            TR1[$d]=$'\x02'"${T1S:$d:1}"
            TR2[$d]=$'\x02'"${T2S:$d:1}"
            TR3[$d]=$'\x02'"${T3S:$d:1}"
        done
    fi
    while (( pos < n )); do
        chunk=${data:pos:16384}
        chunk=${chunk//$'\x02'/$'\x02\x02'}
        for d in 0 1 2 3 4 5 6 7 8; do
            chunk=${chunk//${BRKBYTES[$d]}/$'\x02'"$d"}
        done
        if (( tiers )); then
            for d in 0 1 2 3 4 5 6 7 8; do chunk=${chunk//${TP1[$d]}/${TR1[$d]}}; done
            for d in 0 1 2 3 4 5 6 7 8; do chunk=${chunk//${TP2[$d]}/${TR2[$d]}}; done
            for d in 0 1 2 3 4 5 6 7 8; do chunk=${chunk//${TP3[$d]}/${TR3[$d]}}; done
        fi
        pieces+=("$chunk")
        pos=$((pos + 16384))
    done
    local IFS=''
    ENC="${pieces[*]}"
}

phokenize() {
    # Fast walker: escape the sentinel byte 0x02 by doubling, encode
    # each dimension break as 0x02<digit>, then split on 0x02 (the
    # split and substitutions run at C speed inside bash). A state
    # machine over the parts rebuilds (coordinate, text) scrolls:
    # an empty part is an escaped sentinel (literal 0x02 in the text),
    # a part starting with a digit is a break marker whose remainder
    # is the next run. A trailing 0x03 guard byte keeps the final
    # field alive through read -a and is stripped at the end.
    local data=$1 enc d
    _encode_breaks "$data"
    enc=$ENC
    enc+=$'\x03'
    local -a parts=()
    # word splitting (C speed) on the sentinel; globbing off so scroll
    # text is never treated as a pattern
    local oldifs=$IFS
    IFS=$'\x02'
    set -f
    parts=($enc)
    set +f
    IFS=$oldifs
    PH_N=0
    PH_COORD=(); PH_TEXT=()
    W=(x 1 1 1 1 1 1 1 1 1)
    # Walker state in scalars (w1..w9 = coordinate components):
    # array indexing and function calls per break cost ~10-30 us,
    # and a canonical game state holds ~1.3M breaks; scalar case
    # arms apply a break (increment + unrolled resets) inline.
    # Marker chars: digit d = one break at dimension d; when the
    # encoder's run-length tiers are active (data held no literal
    # 0x02, so every 0x02 in the stream is a genuine marker -- with
    # a literal 0x02 present, an escape pair followed by digit text
    # could masquerade as a marker run, so the tiers stay off and
    # these arms simply never fire), a-i = x10 breaks, j-r = x100,
    # A-I = x1000, letter offset = dimension.
    local cur="" cont=1 part dim d mult
    local w1=1 w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1
    for part in "${parts[@]}"; do
        if (( ! cont )) && [[ -z $cur ]]; then
            # pure break marker, no pending text: fast path
            case $part in
                0) w1=$((w1+1)); w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                1) w2=$((w2+1)); w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                2) w3=$((w3+1)); w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                3) w4=$((w4+1)); w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                4) w5=$((w5+1)); w6=1 w7=1 w8=1 w9=1; continue;;
                5) w6=$((w6+1)); w7=1 w8=1 w9=1; continue;;
                6) w7=$((w7+1)); w8=1 w9=1; continue;;
                7) w8=$((w8+1)); w9=1; continue;;
                8) w9=$((w9+1)); continue;;
                a) w1=$((w1+10)); w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                b) w2=$((w2+10)); w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                c) w3=$((w3+10)); w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                d) w4=$((w4+10)); w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                e) w5=$((w5+10)); w6=1 w7=1 w8=1 w9=1; continue;;
                f) w6=$((w6+10)); w7=1 w8=1 w9=1; continue;;
                g) w7=$((w7+10)); w8=1 w9=1; continue;;
                h) w8=$((w8+10)); w9=1; continue;;
                i) w9=$((w9+10)); continue;;
                j) w1=$((w1+100)); w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                k) w2=$((w2+100)); w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                l) w3=$((w3+100)); w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                m) w4=$((w4+100)); w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                n) w5=$((w5+100)); w6=1 w7=1 w8=1 w9=1; continue;;
                o) w6=$((w6+100)); w7=1 w8=1 w9=1; continue;;
                p) w7=$((w7+100)); w8=1 w9=1; continue;;
                q) w8=$((w8+100)); w9=1; continue;;
                r) w9=$((w9+100)); continue;;
                A) w1=$((w1+1000)); w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                B) w2=$((w2+1000)); w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                C) w3=$((w3+1000)); w4=1 w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                D) w4=$((w4+1000)); w5=1 w6=1 w7=1 w8=1 w9=1; continue;;
                E) w5=$((w5+1000)); w6=1 w7=1 w8=1 w9=1; continue;;
                F) w6=$((w6+1000)); w7=1 w8=1 w9=1; continue;;
                G) w7=$((w7+1000)); w8=1 w9=1; continue;;
                H) w8=$((w8+1000)); w9=1; continue;;
                I) w9=$((w9+1000)); continue;;
            esac
        fi
        if (( cont )); then
            cur+=$part
            cont=0
            continue
        fi
        if [[ -z $part ]]; then
            cur+=$'\x02'
            cont=1
            continue
        fi
        dim=${part:0:1}
        case $dim in
            [0-8]) d=$dim; mult=1;;
            a) d=0; mult=10;; b) d=1; mult=10;; c) d=2; mult=10;;
            d) d=3; mult=10;; e) d=4; mult=10;; f) d=5; mult=10;;
            g) d=6; mult=10;; h) d=7; mult=10;; i) d=8; mult=10;;
            j) d=0; mult=100;; k) d=1; mult=100;; l) d=2; mult=100;;
            m) d=3; mult=100;; n) d=4; mult=100;; o) d=5; mult=100;;
            p) d=6; mult=100;; q) d=7; mult=100;; r) d=8; mult=100;;
            A) d=0; mult=1000;; B) d=1; mult=1000;; C) d=2; mult=1000;;
            D) d=3; mult=1000;; E) d=4; mult=1000;; F) d=5; mult=1000;;
            G) d=6; mult=1000;; H) d=7; mult=1000;; I) d=8; mult=1000;;
            *) d=0; mult=0;;
        esac
        if [[ -n $cur ]]; then
            PH_N=$((PH_N + 1))
            PH_COORD[$PH_N]="$w1,$w2,$w3,$w4,$w5,$w6,$w7,$w8,$w9"; PH_TEXT[$PH_N]=$cur
        fi
        if (( mult )); then
            case $d in
                0) w1=$((w1+mult)); w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1;;
                1) w2=$((w2+mult)); w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1;;
                2) w3=$((w3+mult)); w4=1 w5=1 w6=1 w7=1 w8=1 w9=1;;
                3) w4=$((w4+mult)); w5=1 w6=1 w7=1 w8=1 w9=1;;
                4) w5=$((w5+mult)); w6=1 w7=1 w8=1 w9=1;;
                5) w6=$((w6+mult)); w7=1 w8=1 w9=1;;
                6) w7=$((w7+mult)); w8=1 w9=1;;
                7) w8=$((w8+mult)); w9=1;;
                8) w9=$((w9+mult));;
            esac
        fi
        cur=${part:1}
    done
    cur=${cur%$'\x03'}
    if [[ -n $cur ]]; then
        PH_N=$((PH_N + 1))
        PH_COORD[$PH_N]="$w1,$w2,$w3,$w4,$w5,$w6,$w7,$w8,$w9"; PH_TEXT[$PH_N]=$cur
    fi
    W=(x $w1 $w2 $w3 $w4 $w5 $w6 $w7 $w8 $w9)
}

_advance() {
    # $1 = loc comma, $2 = target comma -> ADV break bytes; LOCARR set
    local -a la ta
    IFS=',' read -ra la <<< "$1"
    IFS=',' read -ra ta <<< "$2"
    ADV=""
    coord_cmp "$1" "$2"
    if (( CMP >= 0 )); then LOCARR=("${la[@]}"); return; fi
    local d=0 k lower
    while [[ ${la[$d]} == "${ta[$d]}" ]]; do d=$((d + 1)); done
    for (( k = la[d]; k < ta[d]; k++ )); do ADV+=${BRKBYTES[$d]}; done
    local -a reached=("${la[@]}")
    reached[$d]=${ta[$d]}
    for (( k = d + 1; k < 9; k++ )); do reached[$k]=1; done
    for (( lower = d + 1; lower < 9; lower++ )); do
        for (( k = 1; k < ta[lower]; k++ )); do ADV+=${BRKBYTES[$lower]}; done
        reached[$lower]=${ta[$lower]}
    done
    LOCARR=("${reached[@]}")
}

dephokenize() {
    # uses PH_N / PH_COORD / PH_TEXT -> RET; pieces are joined in one
    # expansion (repeated string append would be quadratic)
    local -a pieces=()
    local loc="1,1,1,1,1,1,1,1,1" i
    for (( i = 1; i <= PH_N; i++ )); do
        _advance "$loc" "${PH_COORD[$i]}"
        pieces+=("$ADV" "${PH_TEXT[$i]}")
        loc="${LOCARR[0]},${LOCARR[1]},${LOCARR[2]},${LOCARR[3]},${LOCARR[4]},${LOCARR[5]},${LOCARR[6]},${LOCARR[7]},${LOCARR[8]}"
    done
    local IFS=''
    RET="${pieces[*]}"
}

normalize() {
    phokenize "$1"
    dephokenize
}

fetch() {
    # $1 data, $2 comma coord -> RET
    phokenize "$1"
    local i
    RET=""
    for (( i = 1; i <= PH_N; i++ )); do
        if [[ ${PH_COORD[$i]} == "$2" ]]; then RET=${PH_TEXT[$i]}; return; fi
    done
}

_update() {
    # $1 data, $2 comma coord, $3 text, $4 overwrite(0/1) -> RET
    local data=$1 coord=$2 text=$3 overwrite=$4
    phokenize "$data"
    local -a oc ot
    local ocn=0 appended=0 i
    for (( i = 1; i <= PH_N; i++ )); do
        coord_cmp "${PH_COORD[$i]}" "$coord"
        if (( appended == 0 && CMP > 0 )); then
            ocn=$((ocn + 1)); oc[$ocn]=$coord; ot[$ocn]=$text; appended=1
        fi
        if (( appended == 0 )) && [[ ${PH_COORD[$i]} == "$coord" ]]; then
            ocn=$((ocn + 1)); oc[$ocn]=$coord
            if (( overwrite )); then ot[$ocn]=$text; else ot[$ocn]=${PH_TEXT[$i]}$text; fi
            appended=1
            continue
        fi
        ocn=$((ocn + 1)); oc[$ocn]=${PH_COORD[$i]}; ot[$ocn]=${PH_TEXT[$i]}
    done
    if (( appended == 0 )); then
        ocn=$((ocn + 1)); oc[$ocn]=$coord; ot[$ocn]=$text
    fi
    PH_N=$ocn
    PH_COORD=(); PH_TEXT=()
    for (( i = 1; i <= ocn; i++ )); do PH_COORD[$i]=${oc[$i]}; PH_TEXT[$i]=${ot[$i]}; done
    dephokenize
}

insert() { _update "$1" "$2" "$3" 0; }
replace() { _update "$1" "$2" "$3" 1; }
remove() {
    # Coordinate-preserving: empty the scroll, then normalize; later
    # scrolls keep their coordinates.
    _update "$1" "$2" "" 1
    normalize "$RET"
}

explode() {
    phokenize "$1"
    EXPL=()
    local i
    for (( i = 1; i <= PH_N; i++ )); do
        coord_str "${PH_COORD[$i]}"
        EXPL[$CS]=${PH_TEXT[$i]}
    done
}

_padded_key() {
    # $1 comma coord -> PAD: fixed-width components, byte order ==
    # coordinate order
    local -a a
    IFS=',' read -ra a <<< "$1"
    printf -v PAD '%012d%012d%012d%012d%012d%012d%012d%012d%012d' "${a[@]}"
}

_sorted_expl_coords() {
    # -> SORTED array of comma coords of EXPL keys, coordinate order
    local -a lines=()
    local k line
    for k in "${!EXPL[@]}"; do
        coord_parse "$k"
        _padded_key "$CP"
        lines+=("$PAD $CP")
    done
    SORTED=()
    while IFS= read -r line; do
        SORTED+=("${line#* }")
    done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)
}

implode() {
    _sorted_expl_coords
    PH_N=${#SORTED[@]}
    PH_COORD=(); PH_TEXT=()
    local i
    for (( i = 0; i < PH_N; i++ )); do
        PH_COORD[$((i + 1))]=${SORTED[$i]}
        coord_str "${SORTED[$i]}"
        PH_TEXT[$((i + 1))]=${EXPL[$CS]}
    done
    dephokenize
}

# ---------------------------------------------------------------------
# DynamicPhext -- dynamic-array store over DYN_* globals.
# Capacity starts at 1, doubles when full, halves at quarter-full.
dyn_init() {
    DYN_N=0; DYN_CAP=1; DYN_RESIZES=0; DYN_COPIED=0
    DYN_COORD=(); DYN_TEXT=()
    if [[ -n $1 ]]; then
        phokenize "$1"
        local i
        for (( i = 1; i <= PH_N; i++ )); do dyn_push "${PH_COORD[$i]}" "${PH_TEXT[$i]}"; done
    fi
}
dyn_resize() { DYN_CAP=$1; DYN_RESIZES=$((DYN_RESIZES + 1)); DYN_COPIED=$((DYN_COPIED + DYN_N)); }
dyn_grow_if_full() { if (( DYN_N == DYN_CAP )); then dyn_resize $((2 * DYN_CAP)); fi; }
dyn_shrink_if_sparse() {
    if (( DYN_CAP > 1 && DYN_N <= DYN_CAP / 4 )); then
        local nc=$((DYN_CAP / 2)); (( nc < 1 )) && nc=1
        dyn_resize $nc
    fi
}
dyn_push() {
    dyn_grow_if_full
    DYN_N=$((DYN_N + 1))
    DYN_COORD[$DYN_N]=$1; DYN_TEXT[$DYN_N]=$2
}
dyn_find() {
    # $1 comma coord -> DYN_FOUND (0/1), DYN_IDX (1-based or insertion point)
    local lo=1 hi=$DYN_N mid
    DYN_FOUND=0; DYN_IDX=1
    while (( lo <= hi )); do
        mid=$(( (lo + hi) / 2 ))
        coord_cmp "${DYN_COORD[$mid]}" "$1"
        if (( CMP < 0 )); then lo=$((mid + 1))
        elif (( CMP > 0 )); then hi=$((mid - 1))
        else DYN_FOUND=1; DYN_IDX=$mid; return; fi
    done
    DYN_IDX=$lo
}
dyn_fetch() {
    dyn_find "$1"
    if (( DYN_FOUND )); then RET=${DYN_TEXT[$DYN_IDX]}; else RET=""; fi
}
dyn_serialize() {
    PH_N=$DYN_N
    PH_COORD=(); PH_TEXT=()
    local i
    for (( i = 1; i <= DYN_N; i++ )); do PH_COORD[$i]=${DYN_COORD[$i]}; PH_TEXT[$i]=${DYN_TEXT[$i]}; done
    dephokenize
}
dyn_remove_at() {
    local idx=$1 i
    for (( i = idx; i < DYN_N; i++ )); do
        DYN_COORD[$i]=${DYN_COORD[$((i + 1))]}; DYN_TEXT[$i]=${DYN_TEXT[$((i + 1))]}
    done
    unset 'DYN_COORD[$DYN_N]' 'DYN_TEXT[$DYN_N]'
    DYN_N=$((DYN_N - 1))
    dyn_shrink_if_sparse
}
dyn_update() {
    # $1 coord, $2 text, $3 overwrite
    local c=$1 t=$2 overwrite=$3 idx i
    dyn_find "$c"
    if (( DYN_FOUND )); then
        idx=$DYN_IDX
        if [[ -z $t ]]; then
            if (( overwrite )); then dyn_remove_at "$idx"; fi
            return
        fi
        if (( overwrite )); then DYN_TEXT[$idx]=$t; else DYN_TEXT[$idx]=${DYN_TEXT[$idx]}$t; fi
        return
    fi
    [[ -z $t ]] && return
    idx=$DYN_IDX
    dyn_grow_if_full
    for (( i = DYN_N; i >= idx; i-- )); do
        DYN_COORD[$((i + 1))]=${DYN_COORD[$i]}; DYN_TEXT[$((i + 1))]=${DYN_TEXT[$i]}
    done
    DYN_COORD[$idx]=$c; DYN_TEXT[$idx]=$t
    DYN_N=$((DYN_N + 1))
}
dyn_insert() { dyn_update "$1" "$2" 0; }
dyn_replace() { dyn_update "$1" "$2" 1; }
dyn_remove() { dyn_find "$1"; if (( DYN_FOUND )); then dyn_remove_at "$DYN_IDX"; fi; }

# ---------------------------------------------------------------------
# TransitivePhext -- branching hash-map store over TRN_* globals.
# TRN_LEAF[full comma coord] = text; TRN_NODE[prefix] marks branch
# nodes (one level per dimension, depth 9). Fetch/put/remove walk one
# prefix level per dimension. Serialization is in coordinate order.
trn_init() {
    TRN_LEAF=(); TRN_NODE=(); TRN_N=0
    if [[ -n $1 ]]; then
        phokenize "$1"
        local i
        for (( i = 1; i <= PH_N; i++ )); do trn_put "${PH_COORD[$i]}" "${PH_TEXT[$i]}"; done
    fi
}
trn_put() {
    local -a a
    IFS=',' read -ra a <<< "$1"
    local prefix="" i
    for (( i = 0; i < 9; i++ )); do
        if (( i > 0 )); then prefix+=","; fi
        prefix+=${a[$i]}
        TRN_NODE[$prefix]=1
    done
    if [[ -z ${TRN_LEAF[$1]+x} ]]; then TRN_N=$((TRN_N + 1)); fi
    TRN_LEAF[$1]=$2
}
trn_fetch() {
    if [[ -n ${TRN_LEAF[$1]+x} ]]; then RET=${TRN_LEAF[$1]}; else RET=""; fi
}
trn_remove() {
    if [[ -z ${TRN_LEAF[$1]+x} ]]; then return; fi
    unset 'TRN_LEAF[$1]'
    TRN_N=$((TRN_N - 1))
    local -a a
    IFS=',' read -ra a <<< "$1"
    local i p prefix k has
    for (( i = 9; i >= 1; i-- )); do
        prefix=""
        for (( p = 0; p < i; p++ )); do
            if (( p > 0 )); then prefix+=","; fi
            prefix+=${a[$p]}
        done
        has=0
        for k in "${!TRN_LEAF[@]}"; do
            if [[ $k == "$prefix"* ]]; then has=1; break; fi
        done
        if (( has == 0 )); then unset 'TRN_NODE[$prefix]'; else break; fi
    done
}
trn_update() {
    # $1 coord, $2 text, $3 overwrite
    if [[ -z $2 ]]; then
        if (( $3 )); then trn_remove "$1"; fi
        return
    fi
    local t=$2
    if (( $3 == 0 )) && [[ -n ${TRN_LEAF[$1]+x} ]]; then t=${TRN_LEAF[$1]}$t; fi
    trn_put "$1" "$t"
}
trn_insert() { trn_update "$1" "$2" 0; }
trn_replace() { trn_update "$1" "$2" 1; }
trn_serialize() {
    local -a lines=()
    local k line
    for k in "${!TRN_LEAF[@]}"; do
        _padded_key "$k"
        lines+=("$PAD $k")
    done
    local -a cc=()
    while IFS= read -r line; do
        cc+=("${line#* }")
    done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)
    PH_N=${#cc[@]}
    PH_COORD=(); PH_TEXT=()
    local i
    for (( i = 0; i < PH_N; i++ )); do
        PH_COORD[$((i + 1))]=${cc[$i]}
        PH_TEXT[$((i + 1))]=${TRN_LEAF[${cc[$i]}]}
    done
    dephokenize
}
