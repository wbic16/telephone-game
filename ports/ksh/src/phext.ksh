# phext.ksh -- libphext port for KornShell93 (0.6.1 parity semantics;
# normative reference: libphext-py). Phext is a 9-dimensional plain-text
# format: scrolls of text addressed by a Coordinate, separated in the
# byte stream by dimension-break bytes.
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
#     (doubles when full, halves at quarter-full); TransitivePhext:
#     trn_* over an associative map keyed by coordinate string.
#     Both stores serialize byte-identically to the buffer API and
#     never hold an empty scroll (replace "" removes, insert "" is
#     a no-op).

typeset -A EXPL TRN_LEAF BRKDIM
typeset -a PH_COORD PH_TEXT DYN_COORD DYN_TEXT SORTED
BRK=$'\x01\x1f\x1e\x1d\x1c\x1a\x19\x18\x17'
typeset -a BRKBYTES
BRKBYTES=($'\x01' $'\x1f' $'\x1e' $'\x1d' $'\x1c' $'\x1a' $'\x19' $'\x18' $'\x17')
typeset _d
for _d in 0 1 2 3 4 5 6 7 8; do BRKDIM[${BRKBYTES[$_d]}]=$_d; done

function bytes_eq {
    # $1 $2 -> return 0 iff byte-identical. Chunked equality: ksh93
    # 1.0.10's [[ $a == "$b" ]] DIES (exit 255, no diagnostic) on
    # multi-MB operands -- measured on aletheia-core 2026-11-24:
    # [[ == ]] passes at 2,800,000 B and kills the shell at
    # 3,000,000 B (single-scroll 'A' strings), while the phext
    # operations themselves (phokenize/dephokenize/normalize) handle
    # 9,405,538 B fine. The wave-6b "sentinel-split segfault" was
    # this comparison in the test harness, not the split. Never use
    # [[ == ]] on scroll text or whole buffers; compare in 64 KB
    # slices (each slice compare is far below the crash threshold).
    [[ ${#1} != ${#2} ]] && return 1
    typeset -i n=${#1} pos=0
    while (( pos < n )); do
        [[ ${1:pos:65536} == "${2:pos:65536}" ]] || return 1
        pos=$((pos + 65536))
    done
    return 0
}

function coord_parse {
    # $1 = "a.b.c/d.e.f/g.h.i" -> CP comma form, or "" if invalid
    typeset s=$1 g1 g2 g3 out="" i g
    typeset -a p
    IFS='/' read g1 g2 g3 <<< "$s"
    if [[ -z ${g3:-} || $s == */*/*/* ]]; then CP=""; return; fi
    for g in "$g1" "$g2" "$g3"; do
        IFS='.' read -A p <<< "$g"
        if (( ${#p[@]} != 3 )); then CP=""; return; fi
        for i in 0 1 2; do
            if [[ ${p[$i]} != +([0-9]) ]] || (( 10#${p[$i]} < 1 )); then CP=""; return; fi
            out+="${out:+,}$((10#${p[$i]}))"
        done
    done
    CP=$out
}

function coord_str {
    typeset -a a
    IFS=',' read -A a <<< "$1"
    CS="${a[0]}.${a[1]}.${a[2]}/${a[3]}.${a[4]}.${a[5]}/${a[6]}.${a[7]}.${a[8]}"
}

function coord_cmp {
    typeset -a x y
    typeset i
    IFS=',' read -A x <<< "$1"
    IFS=',' read -A y <<< "$2"
    for i in 0 1 2 3 4 5 6 7 8; do
        if (( x[i] < y[i] )); then CMP=-1; return; fi
        if (( x[i] > y[i] )); then CMP=1; return; fi
    done
    CMP=0
}

function _encode_breaks {
    # $1 data -> ENC: escape the sentinel byte 0x02 by doubling and
    # encode each dimension break as 0x02<digit>. Substitutions run in
    # 16 KB chunks joined in one expansion (whole-string passes cost
    # per-replacement x whole-string; all patterns are single bytes,
    # so no match can straddle a chunk boundary).
    typeset data=$1 chunk d
    typeset -i n=${#1} pos=0
    typeset -a pieces
    pieces=()
    ENC=""
    while (( pos < n )); do
        chunk=${data:pos:16384}
        chunk=${chunk//$'\x02'/$'\x02\x02'}
        for d in 0 1 2 3 4 5 6 7 8; do
            chunk=${chunk//${BRKBYTES[$d]}/$'\x02'"$d"}
        done
        pieces+=("$chunk")
        pos=$((pos + 16384))
    done
    typeset IFS=''
    ENC="${pieces[*]}"
}

function phokenize {
    # Sentinel-split walker: escape 0x02 by doubling, encode breaks as
    # 0x02<digit>, split on 0x02 at C speed. An empty part is an
    # escaped sentinel (literal 0x02 in the text); a part starting
    # with a digit is a break marker whose remainder is the next run.
    # A trailing 0x03 guard byte keeps the final field alive through
    # the split and is stripped at the end. Coordinate components live
    # in scalars w1..w9; breaks apply inline via case arms.
    typeset data=$1 enc part dim
    typeset -i d mult cont=1
    _encode_breaks "$data"
    enc=$ENC
    enc+=$'\x03'
    typeset -a parts
    typeset oldifs=$IFS
    IFS=$'\x02'
    set -f
    parts=($enc)
    set +f
    IFS=$oldifs
    PH_N=0
    PH_COORD=(); PH_TEXT=()
    typeset cur=""
    typeset -i w1=1 w2=1 w3=1 w4=1 w5=1 w6=1 w7=1 w8=1 w9=1
    for part in "${parts[@]}"; do
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
            *) d=0; mult=0;;
        esac
        if [[ -n $cur ]]; then
            PH_N=$((PH_N + 1))
            PH_COORD[$PH_N]="$w1,$w2,$w3,$w4,$w5,$w6,$w7,$w8,$w9"; PH_TEXT[$PH_N]=$cur
        fi
        if (( mult )); then
            case $d in
                0) w1=$((w1+mult)); w2=1; w3=1; w4=1; w5=1; w6=1; w7=1; w8=1; w9=1;;
                1) w2=$((w2+mult)); w3=1; w4=1; w5=1; w6=1; w7=1; w8=1; w9=1;;
                2) w3=$((w3+mult)); w4=1; w5=1; w6=1; w7=1; w8=1; w9=1;;
                3) w4=$((w4+mult)); w5=1; w6=1; w7=1; w8=1; w9=1;;
                4) w5=$((w5+mult)); w6=1; w7=1; w8=1; w9=1;;
                5) w6=$((w6+mult)); w7=1; w8=1; w9=1;;
                6) w7=$((w7+mult)); w8=1; w9=1;;
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
}

function _advance {
    # $1 = loc comma, $2 = target comma -> ADV break bytes; LOCSTR set
    typeset -a la ta
    typeset -i d=0 k lower
    IFS=',' read -A la <<< "$1"
    IFS=',' read -A ta <<< "$2"
    ADV=""
    coord_cmp "$1" "$2"
    if (( CMP >= 0 )); then LOCSTR=$1; return; fi
    while [[ ${la[$d]} == "${ta[$d]}" ]]; do d=$((d + 1)); done
    for (( k = la[d]; k < ta[d]; k++ )); do ADV+=${BRKBYTES[$d]}; done
    typeset -a reached
    reached=("${la[@]}")
    reached[$d]=${ta[$d]}
    for (( k = d + 1; k < 9; k++ )); do reached[$k]=1; done
    for (( lower = d + 1; lower < 9; lower++ )); do
        for (( k = 1; k < ta[lower]; k++ )); do ADV+=${BRKBYTES[$lower]}; done
        reached[$lower]=${ta[$lower]}
    done
    LOCSTR="${reached[0]},${reached[1]},${reached[2]},${reached[3]},${reached[4]},${reached[5]},${reached[6]},${reached[7]},${reached[8]}"
}

function dephokenize {
    # uses PH_N / PH_COORD / PH_TEXT -> RET; pieces joined in one
    # expansion (repeated string append would be quadratic)
    typeset -a pieces
    typeset loc="1,1,1,1,1,1,1,1,1"
    typeset -i i
    pieces=()
    for (( i = 1; i <= PH_N; i++ )); do
        _advance "$loc" "${PH_COORD[$i]}"
        pieces+=("$ADV" "${PH_TEXT[$i]}")
        loc=$LOCSTR
    done
    typeset IFS=''
    RET="${pieces[*]}"
}

function normalize {
    phokenize "$1"
    dephokenize
}

function fetch {
    # $1 data, $2 comma coord -> RET
    typeset -i i
    phokenize "$1"
    RET=""
    for (( i = 1; i <= PH_N; i++ )); do
        if [[ ${PH_COORD[$i]} == "$2" ]]; then RET=${PH_TEXT[$i]}; return; fi
    done
}

function _update {
    # $1 data, $2 comma coord, $3 text, $4 overwrite(0/1) -> RET
    typeset data=$1 coord=$2 text=$3 overwrite=$4
    typeset -a oc ot
    typeset -i ocn=0 appended=0 i
    phokenize "$data"
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

function insert { _update "$1" "$2" "$3" 0; }
function replace { _update "$1" "$2" "$3" 1; }
function remove {
    # Coordinate-preserving: empty the scroll, then normalize; later
    # scrolls keep their coordinates.
    _update "$1" "$2" "" 1
    normalize "$RET"
}

function explode {
    typeset -i i
    phokenize "$1"
    EXPL=()
    for (( i = 1; i <= PH_N; i++ )); do
        coord_str "${PH_COORD[$i]}"
        EXPL[$CS]=${PH_TEXT[$i]}
    done
}

function _padded_key {
    # $1 comma coord -> PAD: fixed-width components, byte order ==
    # coordinate order
    typeset -a a
    IFS=',' read -A a <<< "$1"
    printf -v PAD '%012d%012d%012d%012d%012d%012d%012d%012d%012d' "${a[@]}"
}

function _sorted_expl_coords {
    # -> SORTED array of comma coords of EXPL keys, coordinate order
    typeset -a lines
    typeset k line
    lines=()
    for k in "${!EXPL[@]}"; do
        coord_parse "$k"
        _padded_key "$CP"
        lines+=("$PAD $CP")
    done
    SORTED=()
    while IFS= read -r line; do
        SORTED+=("${line#* }")
    done <<< "$(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)"
}

function implode {
    typeset -i i
    _sorted_expl_coords
    PH_N=${#SORTED[@]}
    PH_COORD=(); PH_TEXT=()
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
function dyn_init {
    DYN_N=0; DYN_CAP=1; DYN_RESIZES=0; DYN_COPIED=0
    DYN_COORD=(); DYN_TEXT=()
    if [[ -n $1 ]]; then
        typeset -i i
        phokenize "$1"
        for (( i = 1; i <= PH_N; i++ )); do dyn_push "${PH_COORD[$i]}" "${PH_TEXT[$i]}"; done
    fi
}
function dyn_resize { DYN_CAP=$1; DYN_RESIZES=$((DYN_RESIZES + 1)); DYN_COPIED=$((DYN_COPIED + DYN_N)); }
function dyn_grow_if_full { if (( DYN_N == DYN_CAP )); then dyn_resize $((2 * DYN_CAP)); fi; }
function dyn_shrink_if_sparse {
    if (( DYN_CAP > 1 && DYN_N <= DYN_CAP / 4 )); then
        typeset -i nc=$((DYN_CAP / 2)); (( nc < 1 )) && nc=1
        dyn_resize $nc
    fi
}
function dyn_push {
    dyn_grow_if_full
    DYN_N=$((DYN_N + 1))
    DYN_COORD[$DYN_N]=$1; DYN_TEXT[$DYN_N]=$2
}
function dyn_find {
    # $1 comma coord -> DYN_FOUND (0/1), DYN_IDX (1-based or insertion point)
    typeset -i lo=1 hi=$DYN_N mid
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
function dyn_fetch {
    dyn_find "$1"
    if (( DYN_FOUND )); then RET=${DYN_TEXT[$DYN_IDX]}; else RET=""; fi
}
function dyn_serialize {
    typeset -i i
    PH_N=$DYN_N
    PH_COORD=(); PH_TEXT=()
    for (( i = 1; i <= DYN_N; i++ )); do PH_COORD[$i]=${DYN_COORD[$i]}; PH_TEXT[$i]=${DYN_TEXT[$i]}; done
    dephokenize
}
function dyn_remove_at {
    typeset -i idx=$1 i
    for (( i = idx; i < DYN_N; i++ )); do
        DYN_COORD[$i]=${DYN_COORD[$((i + 1))]}; DYN_TEXT[$i]=${DYN_TEXT[$((i + 1))]}
    done
    unset DYN_COORD[$DYN_N] DYN_TEXT[$DYN_N]
    DYN_N=$((DYN_N - 1))
    dyn_shrink_if_sparse
}
function dyn_update {
    # $1 coord, $2 text, $3 overwrite
    typeset c=$1 t=$2 overwrite=$3
    typeset -i idx i
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
function dyn_insert { dyn_update "$1" "$2" 0; }
function dyn_replace { dyn_update "$1" "$2" 1; }
function dyn_remove { dyn_find "$1"; if (( DYN_FOUND )); then dyn_remove_at "$DYN_IDX"; fi; }

# ---------------------------------------------------------------------
# TransitivePhext -- associative-map store over TRN_* globals, keyed
# by full coordinate string. Serialization is in coordinate order.
function trn_init {
    TRN_LEAF=(); TRN_N=0
    if [[ -n $1 ]]; then
        typeset -i i
        phokenize "$1"
        for (( i = 1; i <= PH_N; i++ )); do trn_put "${PH_COORD[$i]}" "${PH_TEXT[$i]}"; done
    fi
}
function trn_put {
    # $1 comma coord, $2 text (stored under the string-coord key)
    coord_str "$1"
    if [[ -z ${TRN_LEAF[$CS]+x} ]]; then TRN_N=$((TRN_N + 1)); fi
    TRN_LEAF[$CS]=$2
}
function trn_fetch {
    coord_str "$1"
    if [[ -n ${TRN_LEAF[$CS]+x} ]]; then RET=${TRN_LEAF[$CS]}; else RET=""; fi
}
function trn_remove {
    coord_str "$1"
    if [[ -z ${TRN_LEAF[$CS]+x} ]]; then return; fi
    unset TRN_LEAF[$CS]
    TRN_N=$((TRN_N - 1))
}
function trn_update {
    # $1 comma coord, $2 text, $3 overwrite
    if [[ -z $2 ]]; then
        if (( $3 )); then trn_remove "$1"; fi
        return
    fi
    typeset t=$2
    coord_str "$1"
    if (( $3 == 0 )) && [[ -n ${TRN_LEAF[$CS]+x} ]]; then t=${TRN_LEAF[$CS]}$t; fi
    trn_put "$1" "$t"
}
function trn_insert { trn_update "$1" "$2" 0; }
function trn_replace { trn_update "$1" "$2" 1; }
function trn_serialize {
    typeset -a lines cc
    typeset k line
    typeset -i i
    lines=(); cc=()
    for k in "${!TRN_LEAF[@]}"; do
        coord_parse "$k"
        _padded_key "$CP"
        lines+=("$PAD $CP")
    done
    while IFS= read -r line; do
        cc+=("${line#* }")
    done <<< "$(printf '%s\n' "${lines[@]}" | LC_ALL=C sort)"
    PH_N=${#cc[@]}
    PH_COORD=(); PH_TEXT=()
    for (( i = 0; i < PH_N; i++ )); do
        PH_COORD[$((i + 1))]=${cc[$i]}
        coord_str "${cc[$i]}"
        PH_TEXT[$((i + 1))]=${TRN_LEAF[$CS]}
    done
    dephokenize
}
