# json.ksh -- minimal JSON parser + canonical serializer in pure ksh93.
# Ported from the bash port's json.sh: `typeset` -> `typeset`, regex
# matches read from .sh.match instead of .sh.match (the regexes
# themselves are held in variables, as in the original). All string
# equality here is on small values (keys, type tags); the large
# payloads (base64 state) only pass through the regex run extractor
# and the printable fast path, both verified at 3 MB on ksh93 1.0.10
# (the [[ == ]] crash documented in phext.ksh's bytes_eq does not
# apply to them).
# Canonical form matches the harness's canon (Python json.dumps with
# sort_keys=True, separators=(",",":"), ensure_ascii=True): compact,
# keys sorted, non-ASCII escaped as \uXXXX. Number literals are kept
# verbatim from the source text so float formatting round-trips
# exactly.
#
# Values live on a node heap in assoc arrays: NT[id] type
# ("str","num","bool","null","arr","obj"), NS[id] scalar payload,
# NC[id] child count, NCH["id,k"] child node id, NK["id,k"] key.
# json_parse TEXT -> JROOT (0 on error, JERR set).

typeset -A NT NS NC NCH NK

function json_parse {
    JS=$1; JI=0; JN=${#1}; JNEXT=0; JERR=""
    NT=(); NS=(); NC=(); NCH=(); NK=()
    _jvalue
    JROOT=$JV
    _jws
    if (( JI < JN )); then JERR="trailing data after JSON value"; JROOT=0; fi
}

function _jws {
    typeset ch
    while (( JI < JN )); do
        ch=${JS:JI:1}
        case $ch in
            ' '|$'\t'|$'\n'|$'\r') JI=$((JI + 1));;
            *) break;;
        esac
    done
}

function _jnew {
    JNEXT=$((JNEXT + 1))
    NT[$JNEXT]=$1
    JN_ID=$JNEXT
}

function _jvalue {
    _jws
    typeset ch=${JS:JI:1}
    case $ch in
        '{') _jobject;;
        '[') _jarray;;
        '"')
            _jstring
            _jnew str; NS[$JN_ID]=$JSTR_OUT; JV=$JN_ID;;
        't') JI=$((JI + 4)); _jnew bool; NS[$JN_ID]=1; JV=$JN_ID;;
        'f') JI=$((JI + 5)); _jnew bool; NS[$JN_ID]=0; JV=$JN_ID;;
        'n') JI=$((JI + 4)); _jnew null; NS[$JN_ID]=""; JV=$JN_ID;;
        *)
            typeset rest=${JS:JI} re='^[-+0-9.eE]+'
            if [[ $rest =~ $re ]]; then
                _jnew num; NS[$JN_ID]=${.sh.match[0]}; JV=$JN_ID
                JI=$((JI + ${#.sh.match[0]}))
            else
                JERR="bad JSON value at $JI"
                _jnew null; JV=$JN_ID
            fi;;
    esac
}

function _codepoint_utf8 {
    # $1 codepoint -> UTF8_OUT (bytes as a bash string)
    typeset cp=$1 b1 b2 b3 b4 fmt
    if (( cp < 128 )); then
        printf -v UTF8_OUT "\\x$(printf '%02x' "$cp")"
    elif (( cp < 2048 )); then
        b1=$((192 + cp / 64)); b2=$((128 + cp % 64))
        fmt=$(printf '\\x%02x\\x%02x' $b1 $b2); printf -v UTF8_OUT "$fmt"
    elif (( cp < 65536 )); then
        b1=$((224 + cp / 4096)); b2=$((128 + (cp / 64) % 64)); b3=$((128 + cp % 64))
        fmt=$(printf '\\x%02x\\x%02x\\x%02x' $b1 $b2 $b3); printf -v UTF8_OUT "$fmt"
    else
        b1=$((240 + cp / 262144)); b2=$((128 + (cp / 4096) % 64)); b3=$((128 + (cp / 64) % 64)); b4=$((128 + cp % 64))
        fmt=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $b1 $b2 $b3 $b4); printf -v UTF8_OUT "$fmt"
    fi
}

function _jstring {
    JI=$((JI + 1))  # opening quote
    JSTR_OUT=""
    typeset rest re='^[^"\\]*' ch e hex code hex2 lo
    while (( JI < JN )); do
        rest=${JS:JI}
        if [[ $rest =~ $re ]]; then
            JSTR_OUT+=${.sh.match[0]}
            JI=$((JI + ${#.sh.match[0]}))
        fi
        (( JI >= JN )) && break
        ch=${JS:JI:1}
        if [[ $ch == '"' ]]; then JI=$((JI + 1)); return; fi
        # backslash escape
        JI=$((JI + 1))
        e=${JS:JI:1}
        case $e in
            '"') JSTR_OUT+='"';;
            '\') JSTR_OUT+='\';;
            '/') JSTR_OUT+='/';;
            'b') JSTR_OUT+=$'\b';;
            'f') JSTR_OUT+=$'\f';;
            'n') JSTR_OUT+=$'\n';;
            'r') JSTR_OUT+=$'\r';;
            't') JSTR_OUT+=$'\t';;
            'u')
                hex=${JS:JI + 1:4}
                code=$((16#$hex))
                JI=$((JI + 4))
                if (( code >= 55296 && code <= 56319 )) && [[ ${JS:JI + 1:2} == '\u' ]]; then
                    hex2=${JS:JI + 3:4}
                    lo=$((16#$hex2))
                    if (( lo >= 56320 && lo <= 57343 )); then
                        code=$((65536 + (code - 55296) * 1024 + (lo - 56320)))
                        JI=$((JI + 6))
                    fi
                fi
                _codepoint_utf8 $code
                JSTR_OUT+=$UTF8_OUT;;
            *) JERR="bad escape \\$e";;
        esac
        JI=$((JI + 1))
    done
    JERR="unterminated string"
}

function _jobject {
    JI=$((JI + 1))
    _jnew obj; typeset id=$JN_ID; NC[$id]=0
    _jws
    if [[ ${JS:JI:1} == '}' ]]; then JI=$((JI + 1)); JV=$id; return; fi
    typeset k ch
    while true; do
        _jws
        _jstring; k=$JSTR_OUT
        _jws
        JI=$((JI + 1))  # :
        _jvalue
        NC[$id]=$((${NC[$id]} + 1))
        NK["$id,${NC[$id]}"]=$k
        NCH["$id,${NC[$id]}"]=$JV
        _jws
        ch=${JS:JI:1}
        JI=$((JI + 1))
        [[ $ch == '}' ]] && break
        if [[ $ch != ',' ]]; then JERR="expected comma or end of object"; break; fi
    done
    JV=$id
}

function _jarray {
    JI=$((JI + 1))
    _jnew arr; typeset id=$JN_ID; NC[$id]=0
    _jws
    if [[ ${JS:JI:1} == ']' ]]; then JI=$((JI + 1)); JV=$id; return; fi
    typeset ch
    while true; do
        _jvalue
        NC[$id]=$((${NC[$id]} + 1))
        NCH["$id,${NC[$id]}"]=$JV
        _jws
        ch=${JS:JI:1}
        JI=$((JI + 1))
        [[ $ch == ']' ]] && break
        if [[ $ch != ',' ]]; then JERR="expected comma or end of array"; break; fi
    done
    JV=$id
}

# ---- accessors / constructors ----
function jget {
    # $1 id, $2 key -> JG node id or 0
    JG=0
    [[ ${NT[$1]:-} == obj ]] || return
    typeset i
    for (( i = 1; i <= ${NC[$1]}; i++ )); do
        if [[ ${NK["$1,$i"]} == "$2" ]]; then JG=${NCH["$1,$i"]}; return; fi
    done
}
function jhas { jget "$1" "$2"; [[ $JG != 0 ]]; }
function jstr_new { _jnew str; NS[$JN_ID]=$1; }
function jnum_new { _jnew num; NS[$JN_ID]=$1; }
function jnull_new { _jnew null; NS[$JN_ID]=""; }
function jbool_new { _jnew bool; NS[$JN_ID]=$1; }
function jarr_new { _jnew arr; NC[$JN_ID]=0; }
function jobj_new { _jnew obj; NC[$JN_ID]=0; }
function jarr_push { NC[$1]=$((${NC[$1]} + 1)); NCH["$1,${NC[$1]}"]=$2; }
function jobj_set { NC[$1]=$((${NC[$1]} + 1)); NK["$1,${NC[$1]}"]=$2; NCH["$1,${NC[$1]}"]=$3; }

# ---- canonical serializer ----
# ITERATIVE, single frame, explicit stack -- no recursion. The bash
# original recursed (_canon_into), but ksh93 1.0.10 clobbers a
# recursive function's typeset locals (the keys array / loop index)
# across nested calls: canon of a real event body repeated one key
# forever after the first nested array. Object children are emitted
# in sorted key order by repeated smallest-key selection over the
# child list (objects here have <= ~12 keys), tracking the last
# emitted (key, child index) pair per stack frame; no per-frame key
# array is kept. Output is byte-identical to the recursive form:
# compact, keys sorted bytewise (LC_ALL=C), Python ensure_ascii
# string escaping via _canon_str.
function json_canon {
    # $1 node id -> CANON
    JC_BUF=""
    typeset -a st_id st_stage st_idx st_lastkey st_lastidx
    typeset -i sp=1 top id k best child
    typeset bestkey
    st_id[0]=$1; st_stage[0]=0; st_idx[0]=0; st_lastkey[0]=""; st_lastidx[0]=0
    while (( sp > 0 )); do
        top=$((sp - 1)); id=${st_id[$top]}
        case ${NT[$id]} in
            null) JC_BUF+="null"; sp=$((sp - 1));;
            bool) if [[ ${NS[$id]} == 1 ]]; then JC_BUF+="true"; else JC_BUF+="false"; fi; sp=$((sp - 1));;
            num) JC_BUF+=${NS[$id]}; sp=$((sp - 1));;
            str) _canon_str "${NS[$id]}"; JC_BUF+=$CANON_STR; sp=$((sp - 1));;
            arr)
                if (( st_stage[top] == 0 )); then
                    JC_BUF+="["; st_stage[top]=1; st_idx[top]=1
                fi
                if (( st_idx[top] <= ${NC[$id]} )); then
                    child=${NCH["$id,${st_idx[top]}"]}
                    (( st_idx[top] > 1 )) && JC_BUF+=","
                    st_idx[top]=$((st_idx[top] + 1))
                    st_id[$sp]=$child; st_stage[$sp]=0; st_idx[$sp]=0; st_lastkey[$sp]=""; st_lastidx[$sp]=0
                    sp=$((sp + 1))
                else
                    JC_BUF+="]"; sp=$((sp - 1))
                fi;;
            obj)
                if (( st_stage[top] == 0 )); then
                    JC_BUF+="{"; st_stage[top]=1; st_idx[top]=0; st_lastkey[top]=""; st_lastidx[top]=0
                fi
                best=0; bestkey=""
                for (( k = 1; k <= ${NC[$id]}; k++ )); do
                    typeset kk=${NK["$id,$k"]}
                    if (( st_idx[top] > 0 )); then
                        if [[ $kk < ${st_lastkey[$top]} ]]; then continue; fi
                        if [[ $kk == "${st_lastkey[$top]}" ]] && (( k <= st_lastidx[top] )); then continue; fi
                    fi
                    if (( best == 0 )) || [[ $kk < $bestkey ]]; then best=$k; bestkey=$kk; fi
                done
                if (( best == 0 )); then
                    JC_BUF+="}"; sp=$((sp - 1))
                else
                    (( st_idx[top] > 0 )) && JC_BUF+=","
                    _canon_str "$bestkey"
                    JC_BUF+=$CANON_STR":"
                    st_lastkey[top]=$bestkey; st_lastidx[top]=$best; st_idx[top]=$((st_idx[top] + 1))
                    child=${NCH["$id,$best"]}
                    st_id[$sp]=$child; st_stage[$sp]=0; st_idx[$sp]=0; st_lastkey[$sp]=""; st_lastidx[$sp]=0
                    sp=$((sp + 1))
                fi;;
            *) JC_BUF+="null"; sp=$((sp - 1));;
        esac
    done
    CANON=$JC_BUF
}

function _canon_str {
    # $1 string -> CANON_STR (quoted, Python ensure_ascii escaping)
    CANON_STR='"'
    typeset s=$1 rest re='^[^"\\]*' chunk ch
    typeset i=0 n=${#s}
    while (( i < n )); do
        rest=${s:i}
        if [[ $rest =~ $re ]]; then
            chunk=${.sh.match[0]}
            _escape_run "$chunk"
            CANON_STR+=$ESCAPED
            i=$((i + ${#chunk}))
        fi
        (( i >= n )) && break
        ch=${s:i:1}
        if [[ $ch == '"' ]]; then CANON_STR+='\"'; else CANON_STR+='\\'; fi
        i=$((i + 1))
    done
    CANON_STR+='"'
}

function _escape_run {
    # Escape a run of ordinary chars -> ESCAPED. Fast path: a chunk of
    # printable ASCII (space..tilde) needs no escaping at all. Game
    # strings are ASCII, where byte-wise \uXXXX escaping of the rest
    # is exactly Python's codepoint-wise form.
    typeset chunk=$1
    if [[ $chunk =~ ^[[:print:]]+$ ]]; then ESCAPED=$chunk; return; fi
    ESCAPED=""
    typeset i ch b
    for (( i = 0; i < ${#chunk}; i++ )); do
        ch=${chunk:i:1}
        printf -v b '%d' "'$ch"
        case $b in
            8) ESCAPED+='\b';;
            9) ESCAPED+='\t';;
            10) ESCAPED+='\n';;
            12) ESCAPED+='\f';;
            13) ESCAPED+='\r';;
            *)
                if (( b < 32 || b > 126 )); then
                    printf -v ch '\\u%04x' "$b"
                    ESCAPED+=$ch
                else
                    ESCAPED+=$ch
                fi;;
        esac
    done
}
