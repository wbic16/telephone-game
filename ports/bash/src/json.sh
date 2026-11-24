# json.sh -- minimal JSON parser + canonical serializer in pure bash.
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

declare -A NT=() NS=() NC=() NCH=() NK=()

json_parse() {
    JS=$1; JI=0; JN=${#1}; JNEXT=0; JERR=""
    NT=(); NS=(); NC=(); NCH=(); NK=()
    _jvalue
    JROOT=$JV
    _jws
    if (( JI < JN )); then JERR="trailing data after JSON value"; JROOT=0; fi
}

_jws() {
    local ch
    while (( JI < JN )); do
        ch=${JS:JI:1}
        case $ch in
            ' '|$'\t'|$'\n'|$'\r') JI=$((JI + 1));;
            *) break;;
        esac
    done
}

_jnew() {
    JNEXT=$((JNEXT + 1))
    NT[$JNEXT]=$1
    JN_ID=$JNEXT
}

_jvalue() {
    _jws
    local ch=${JS:JI:1}
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
            local rest=${JS:JI} re='^[-+0-9.eE]+'
            if [[ $rest =~ $re ]]; then
                _jnew num; NS[$JN_ID]=${BASH_REMATCH[0]}; JV=$JN_ID
                JI=$((JI + ${#BASH_REMATCH[0]}))
            else
                JERR="bad JSON value at $JI"
                _jnew null; JV=$JN_ID
            fi;;
    esac
}

_codepoint_utf8() {
    # $1 codepoint -> UTF8_OUT (bytes as a bash string)
    local cp=$1 b1 b2 b3 b4 fmt
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

_jstring() {
    JI=$((JI + 1))  # opening quote
    JSTR_OUT=""
    local rest re='^[^"\\]*' ch e hex code hex2 lo
    while (( JI < JN )); do
        rest=${JS:JI}
        if [[ $rest =~ $re ]]; then
            JSTR_OUT+=${BASH_REMATCH[0]}
            JI=$((JI + ${#BASH_REMATCH[0]}))
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

_jobject() {
    JI=$((JI + 1))
    _jnew obj; local id=$JN_ID; NC[$id]=0
    _jws
    if [[ ${JS:JI:1} == '}' ]]; then JI=$((JI + 1)); JV=$id; return; fi
    local k ch
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

_jarray() {
    JI=$((JI + 1))
    _jnew arr; local id=$JN_ID; NC[$id]=0
    _jws
    if [[ ${JS:JI:1} == ']' ]]; then JI=$((JI + 1)); JV=$id; return; fi
    local ch
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
jget() {
    # $1 id, $2 key -> JG node id or 0
    JG=0
    [[ ${NT[$1]:-} == obj ]] || return
    local i
    for (( i = 1; i <= ${NC[$1]}; i++ )); do
        if [[ ${NK["$1,$i"]} == "$2" ]]; then JG=${NCH["$1,$i"]}; return; fi
    done
}
jhas() { jget "$1" "$2"; [[ $JG != 0 ]]; }
jstr_new() { _jnew str; NS[$JN_ID]=$1; }
jnum_new() { _jnew num; NS[$JN_ID]=$1; }
jnull_new() { _jnew null; NS[$JN_ID]=""; }
jbool_new() { _jnew bool; NS[$JN_ID]=$1; }
jarr_new() { _jnew arr; NC[$JN_ID]=0; }
jobj_new() { _jnew obj; NC[$JN_ID]=0; }
jarr_push() { NC[$1]=$((${NC[$1]} + 1)); NCH["$1,${NC[$1]}"]=$2; }
jobj_set() { NC[$1]=$((${NC[$1]} + 1)); NK["$1,${NC[$1]}"]=$2; NCH["$1,${NC[$1]}"]=$3; }

# ---- canonical serializer ----
json_canon() {
    # $1 node id -> CANON (wrapper over the append-style walker)
    JC_BUF=""
    _canon_into "$1"
    CANON=$JC_BUF
}

_canon_into() {
    # appends the canonical form of node $1 to JC_BUF
    local id=$1 i
    case ${NT[$id]} in
        null) JC_BUF+="null";;
        bool) if [[ ${NS[$id]} == 1 ]]; then JC_BUF+="true"; else JC_BUF+="false"; fi;;
        num) JC_BUF+=${NS[$id]};;
        str) _canon_str "${NS[$id]}"; JC_BUF+=$CANON_STR;;
        arr)
            JC_BUF+="["
            for (( i = 1; i <= ${NC[$id]}; i++ )); do
                (( i > 1 )) && JC_BUF+=","
                _canon_into "${NCH["$id,$i"]}"
            done
            JC_BUF+="]";;
        obj)
            local -a keys=()
            for (( i = 1; i <= ${NC[$id]}; i++ )); do keys+=("${NK["$id,$i"]}"); done
            local j tmp
            for (( i = 1; i < ${#keys[@]}; i++ )); do
                tmp=${keys[$i]}; j=$((i - 1))
                while (( j >= 0 )) && [[ ${keys[$j]} > $tmp ]]; do
                    keys[$((j + 1))]=${keys[$j]}; j=$((j - 1))
                done
                keys[$((j + 1))]=$tmp
            done
            JC_BUF+="{"
            for (( i = 0; i < ${#keys[@]}; i++ )); do
                (( i > 0 )) && JC_BUF+=","
                _canon_str "${keys[$i]}"
                JC_BUF+=$CANON_STR":"
                jget "$id" "${keys[$i]}"
                _canon_into "$JG"
            done
            JC_BUF+="}";;
        *) JC_BUF+="null";;
    esac
}

_canon_str() {
    # $1 string -> CANON_STR (quoted, Python ensure_ascii escaping)
    CANON_STR='"'
    local s=$1 rest re='^[^"\\]*' chunk ch
    local i=0 n=${#s}
    while (( i < n )); do
        rest=${s:i}
        if [[ $rest =~ $re ]]; then
            chunk=${BASH_REMATCH[0]}
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

_escape_run() {
    # Escape a run of ordinary chars -> ESCAPED. Fast path: a chunk of
    # printable ASCII (space..tilde) needs no escaping at all. Game
    # strings are ASCII, where byte-wise \uXXXX escaping of the rest
    # is exactly Python's codepoint-wise form.
    local chunk=$1
    if [[ $chunk =~ ^[[:print:]]+$ ]]; then ESCAPED=$chunk; return; fi
    ESCAPED=""
    local i ch b
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
