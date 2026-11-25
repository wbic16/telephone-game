#!/bin/bash
# telephone.sh -- Exocortical Telephone Game CLI (contract v2) for the
# Bash libphext port. Wire protocol: one JSON request in, one JSON
# response out; with the argument "serve" it loops over JSON lines.
# Commands: id, echo, elect, choose, apply, keygen, attest, validate
# (both the prior_state form and the driver's init/event_coord/
# index_line form), init, verify. All phext operations use this port's
# own phext.sh; JSON uses this port's own json.sh. PGP via subprocess
# gpg (key home $TELEPHONE_GNUPGHOME or ~/telephone-bash/gnupg; private
# keys never leave it). sha256/base64 via coreutils subprocesses (data
# utilities, not phext logic).

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/phext.sh"
source "$DIR/json.sh"

IMPL="bash"
INDEX_CS="1.1.1/1.1.1/1.1.1"
KEYS_CS="1.1.1/1.1.1/1.1.2"
KH_CS="1.1.1/1.1.1/1.1.3"
KEY_UID="libphext telephone bash"
GNUPG_HOME=${TELEPHONE_GNUPGHOME:-$HOME/telephone-bash/gnupg}
mkdir -p "$GNUPG_HOME" && chmod 700 "$GNUPG_HOME"
export GNUPGHOME=$GNUPG_HOME
TMPBASE="/tmp/telephone-bash-$$"
CACHE_SET=0
declare -A CACHE=() BEFORE=() NEW=() SC=() IDX=() SEEN=()

# ------------------------------------------------------------ utilities
write_file() { printf '%s' "$2" > "$1"; }
read_file() {
    RF=""
    IFS= read -r -d '' RF < "$1" || true
}
sha256hex_of() {
    # SHA_IN -> SHA_OUT
    write_file "$TMPBASE-sha" "$SHA_IN"
    SHA_OUT=$(sha256sum "$TMPBASE-sha")
    SHA_OUT=${SHA_OUT%% *}
    rm -f "$TMPBASE-sha"
}
b64_encode_of() {
    # B64_IN -> B64_OUT
    write_file "$TMPBASE-b64" "$B64_IN"
    B64_OUT=$(base64 -w0 "$TMPBASE-b64")
    rm -f "$TMPBASE-b64"
}
b64_decode_of() {
    # B64_IN (text) -> B64_OUT (bytes)
    printf '%s' "$B64_IN" | base64 -d > "$TMPBASE-b64d" 2>/dev/null
    read_file "$TMPBASE-b64d"
    B64_OUT=$RF
    rm -f "$TMPBASE-b64d"
}
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    TRIMMED=$s
}
trim_nl() {
    local s=$1
    TRIMMED=${s%$'\n'}
}

# ------------------------------------------------------------ gpg
do_keygen() {
    if ! gpg --batch --yes --list-keys --with-colons 2>/dev/null | grep -q '^pub:'; then
        gpg --batch --yes --pinentry-mode loopback --passphrase "" \
            --quick-generate-key "$KEY_UID" ed25519 sign never 2>/dev/null
    fi
    local pub
    pub=$(gpg --batch --yes --armor --export "$KEY_UID" 2>/dev/null)
    [[ $pub == *$'\n' ]] || pub+=$'\n'
    jobj_new; local r=$JN_ID
    jstr_new "$IMPL"; jobj_set $r impl $JN_ID
    jstr_new "$pub"; jobj_set $r pubkey $JN_ID
    RESP_ID=$r
}
detach_sign() {
    # $1 data -> SIG_OUT armored
    write_file "$TMPBASE-desc" "$1"
    gpg --batch --yes --pinentry-mode loopback --passphrase "" \
        --detach-sign --armor --local-user "$KEY_UID" \
        --output "$TMPBASE-desc.asc" "$TMPBASE-desc" 2>/dev/null
    read_file "$TMPBASE-desc.asc"
    SIG_OUT=$RF
    rm -f "$TMPBASE-desc" "$TMPBASE-desc.asc"
}
verify_signature() {
    # $1 pubkeys, $2 data, $3 signature -> returns 0/1
    local dir="$TMPBASE-verify" home
    home="$dir/gnupg"
    rm -rf "$dir"; mkdir -p "$home"; chmod 700 "$home"
    write_file "$dir/keys.asc" "$1"
    write_file "$dir/data" "$2"
    write_file "$dir/sig.asc" "$3"
    local rc=1
    if gpg --batch --yes --homedir "$home" --import "$dir/keys.asc" >/dev/null 2>&1; then
        if gpg --batch --yes --homedir "$home" --verify "$dir/sig.asc" "$dir/data" >/dev/null 2>&1; then
            rc=0
        fi
    fi
    rm -rf "$dir"
    return $rc
}

# ------------------------------------------------------------ game logic
echo_value() {
    # $1 ping node id -> ECHO_OUT
    local game="" round="" nonce=""
    jget "$1" game; [[ $JG != 0 ]] && game=${NS[$JG]}
    jget "$1" round
    if [[ $JG != 0 ]]; then round=${NS[$JG]}
    else jget "$1" turn; [[ $JG != 0 ]] && round=${NS[$JG]}; fi
    jget "$1" nonce; [[ $JG != 0 ]] && nonce=${NS[$JG]}
    SHA_IN="$IMPL|$game|$round|$nonce"
    sha256hex_of
    ECHO_OUT=$SHA_OUT
}
elect_winner() {
    # $1 position, $2 candidates node id, $3 turn -> ELECT_OUT
    local position=$1 cand=$2 turn=$3
    local joined="" i
    for (( i = 1; i <= ${NC[$cand]}; i++ )); do
        (( i > 1 )) && joined+=","
        joined+=${NS[${NCH["$cand,$i"]}]}
    done
    local tch
    printf -v tch '\\x%02x' $(( turn % 256 ))
    printf -v tch "$tch"
    SHA_IN="$position$tch$joined"
    sha256hex_of
    local b0=$((16#${SHA_OUT:0:2}))
    ELECT_OUT=${NS[${NCH["$cand,$(( b0 % ${NC[$cand]} + 1 ))"]}]}
}
wrap999() { WRAP=$(( ($1 - 1) % 999 + 1 )); }
next_coord_str() {
    local -a a
    IFS=',' read -ra a <<< "$1"
    local d
    for (( d = 8; d >= 0; d-- )); do
        if (( a[d] < 999 )); then a[d]=$((a[d] + 1)); break; fi
        a[d]=1
    done
    NCS="${a[0]},${a[1]},${a[2]},${a[3]},${a[4]},${a[5]},${a[6]},${a[7]},${a[8]}"
}
choose_adventure() {
    # $1 state, $2 position, $3 turn -> RESP_ID (step object)
    local state=$1 position=$2 turn=$3
    explode "$state"
    coord_parse "$position"
    local -a a
    IFS=',' read -ra a <<< "$CP"
    local tch
    printf -v tch '\\x%02x' $(( turn % 256 ))
    printf -v tch "$tch"
    SHA_IN="$position$tch$state"
    sha256hex_of
    local b1=$((16#${SHA_OUT:2:2})) b2=$((16#${SHA_OUT:4:2}))
    local dim=$(( b1 % 9 ))
    wrap999 $(( a[dim] + 1 + b2 % 3 ))
    a[dim]=$WRAP
    local cand="${a[0]},${a[1]},${a[2]},${a[3]},${a[4]},${a[5]},${a[6]},${a[7]},${a[8]}"
    coord_str "$cand"; local cs=$CS
    while [[ -n ${EXPL[$cs]+x} || $cs == "$INDEX_CS" || $cs == "$KEYS_CS" || $cs == "$KH_CS" ]]; do
        next_coord_str "$cand"; cand=$NCS
        coord_str "$cand"; cs=$CS
    done
    jobj_new; local r=$JN_ID
    jstr_new "insert"; jobj_set $r op $JN_ID
    jstr_new "$cs"; jobj_set $r coordinate $JN_ID
    jstr_new "$IMPL turn $turn at $cs"; jobj_set $r text $JN_ID
    RESP_ID=$r
}
apply_step() {
    # $1 state, $2 step node id -> RESP_ID
    local state=$1 step=$2
    jget "$step" op; local op=${NS[$JG]}
    jget "$step" coordinate; local cs=${NS[$JG]}
    coord_parse "$cs"; local coord=$CP
    jget "$step" text; local text=""; [[ $JG != 0 ]] && text=${NS[$JG]}
    local fh=""
    case $op in
        insert) insert "$state" "$coord" "$text";;
        replace) replace "$state" "$coord" "$text";;
        remove) remove "$state" "$coord";;
        fetch) fetch "$state" "$coord"; SHA_IN=$RET; sha256hex_of; fh=$SHA_OUT; RET=$state;;
        *) RET=$state;;
    esac
    local newstate=$RET
    jobj_new; local r=$JN_ID
    B64_IN=$newstate; b64_encode_of
    jstr_new "$B64_OUT"; jobj_set $r state_b64 $JN_ID
    SHA_IN=$newstate; sha256hex_of
    jstr_new "$SHA_OUT"; jobj_set $r state_sha256 $JN_ID
    if [[ -n $fh ]]; then jstr_new "$fh"; else jnull_new; fi
    jobj_set $r fetch_sha256 $JN_ID
    RESP_ID=$r
}
vfail() {
    jobj_new; local r=$JN_ID
    jstr_new "$IMPL"; jobj_set $r impl $JN_ID
    jstr_new "fail"; jobj_set $r verdict $JN_ID
    jstr_new "$1"; jobj_set $r detail $JN_ID
    RESP_ID=$r
}
vpass() {
    jobj_new; local r=$JN_ID
    jstr_new "$IMPL"; jobj_set $r impl $JN_ID
    jstr_new "pass"; jobj_set $r verdict $JN_ID
    if [[ -n $1 ]]; then jstr_new "$1"; jobj_set $r detail $JN_ID; fi
    RESP_ID=$r
}
do_validate() {
    # $1 req node id, $2 state -> RESP_ID
    local req=$1 state=$2
    jget "$req" step; local step=$JG
    jget "$step" op; local op=${NS[$JG]}
    jget "$step" coordinate; local cs=${NS[$JG]}
    coord_parse "$cs"; local coord=$CP
    jget "$step" text; local text=""; [[ $JG != 0 ]] && text=${NS[$JG]}
    jget "$req" prior_state
    if [[ $JG != 0 ]]; then
        local prior_b64=${NS[$JG]}
        if [[ $op != insert ]]; then vfail "step op is not insert"; return; fi
        fetch "$state" "$coord"
        if [[ $RET != "$text" ]]; then
            vfail "placed scroll absent or content differs at $cs"; return
        fi
        B64_IN=$prior_b64; b64_decode_of; local prior=$B64_OUT
        fetch "$prior" "$coord"
        if [[ -n $RET ]]; then
            vfail "coordinate was not unused in the prior state"; return
        fi
        explode "$prior"; BEFORE=(); local k
        for k in "${!EXPL[@]}"; do BEFORE[$k]=${EXPL[$k]}; done
        explode "$state"
        if (( ${#EXPL[@]} != ${#BEFORE[@]} + 1 )); then
            vfail "scroll count did not grow by exactly one"; return
        fi
        for k in "${!BEFORE[@]}"; do
            if [[ -z ${EXPL[$k]+x} || ${EXPL[$k]} != "${BEFORE[$k]}" ]]; then
                vfail "a prior scroll was overwritten: $k"; return
            fi
        done
        vpass "placed at unused coordinate; all prior scrolls intact"
        return
    fi
    # driver form: cached prior map + event_coord + index_line
    if (( CACHE_SET == 0 )); then vfail "validate called before init"; return; fi
    jget "$req" event_coord; local ev=${NS[$JG]}
    jget "$req" index_line; local line=${NS[$JG]}
    explode "$state"; NEW=(); local k
    for k in "${!EXPL[@]}"; do NEW[$k]=${EXPL[$k]}; done
    if [[ -z ${NEW[$cs]+x} || ${NEW[$cs]} != "$text" ]]; then
        vfail "placed scroll missing or altered"; return
    fi
    for k in "${!CACHE[@]}"; do
        [[ $k == "$INDEX_CS" ]] && continue
        if [[ -z ${NEW[$k]+x} || ${NEW[$k]} != "${CACHE[$k]}" ]]; then
            vfail "prior scroll overwritten at $k"; return
        fi
    done
    for k in "${!NEW[@]}"; do
        if [[ -z ${CACHE[$k]+x} && $k != "$cs" && $k != "$ev" ]]; then
            vfail "unexpected new scroll at $k"; return
        fi
    done
    local idx=""; [[ -n ${NEW[$INDEX_CS]+x} ]] && idx=${NEW[$INDEX_CS]}
    trim_nl "$idx"; local idx_t=$TRIMMED
    trim_nl "$line"; local line_t=$TRIMMED
    if [[ ${idx_t: -${#line_t}} != "$line_t" ]]; then
        vfail "index does not record the placement"; return
    fi
    CACHE=()
    for k in "${!NEW[@]}"; do CACHE[$k]=${NEW[$k]}; done
    vpass ""
}
verify_fail() {
    jobj_new; local r=$JN_ID
    jstr_new "$IMPL"; jobj_set $r impl $JN_ID
    jstr_new "fail"; jobj_set $r verdict $JN_ID
    jnum_new "$1"; jobj_set $r placements_checked $JN_ID
    jobj_new; local ff=$JN_ID
    jstr_new "$2"; jobj_set $ff detail $JN_ID
    jobj_set $r first_failure $ff
    RESP_ID=$r
}
do_verify() {
    # $1 state, $2 pubkeys -> RESP_ID
    local state=$1 pubkeys=$2
    explode "$state"; SC=(); local k
    for k in "${!EXPL[@]}"; do SC[$k]=${EXPL[$k]}; done
    if [[ -z ${SC[$KEYS_CS]+x} || -z ${SC[$KEYS_CS]} ]]; then
        verify_fail 0 "no public-keys scroll at 1.1.1/1.1.1/1.1.2"; return
    fi
    local keys_text=${SC[$KEYS_CS]}
    trim "$pubkeys"; local pk_t=$TRIMMED
    trim "$keys_text"; local kt_t=$TRIMMED
    if [[ $pk_t != "$kt_t" ]]; then
        verify_fail 0 "supplied pubkeys do not match the inscribed keys scroll"; return
    fi
    if [[ -z ${SC[$KH_CS]+x} ]]; then
        verify_fail 0 "no keys-hash scroll at 1.1.1/1.1.1/1.1.3"; return
    fi
    SHA_IN=$keys_text; sha256hex_of
    trim "${SC[$KH_CS]}"
    if [[ $TRIMMED != "$SHA_OUT" ]]; then
        verify_fail 0 "keys-hash scroll does not match the keys scroll"; return
    fi
    IDX=()
    if [[ -n ${SC[$INDEX_CS]+x} ]]; then
        local -a lines fields
        mapfile -t lines <<< "${SC[$INDEX_CS]}"
        local ln
        for ln in "${lines[@]}"; do
            [[ -z $ln || $ln == '#'* ]] && continue
            read -ra fields <<< "$ln"
            if (( ${#fields[@]} != 4 )); then
                verify_fail 0 "malformed index line: $ln"; return
            fi
            IDX[${fields[1]}]="${fields[0]}"$'\x1c'"${fields[2]}"$'\x1c'"${fields[3]}"
        done
    fi
    local checked=0 prev_hash="" seq ev body cs th fh ab turn_raw actor
    SEEN=()
    for (( seq = 1; ; seq++ )); do
        local evcs="1.1.1/1.1.1/2.1.$seq"
        [[ -n ${SC[$evcs]+x} ]] || break
        json_parse "${SC[$evcs]}"
        ev=$JROOT
        if [[ $ev == 0 ]] || ! jhas "$ev" body; then
            verify_fail $checked "event $seq lacks a body object"; return
        fi
        jget "$ev" body; body=$JG
        if (( seq == 1 )); then
            jget "$ev" prev
            if [[ ${NT[$JG]} != null ]]; then
                verify_fail $checked "event 1 prev is not null"; return
            fi
        else
            jget "$ev" prev
            if [[ ${NS[$JG]} != "$prev_hash" ]]; then
                verify_fail $checked "event chain broken at seq $seq"; return
            fi
        fi
        json_canon "$body"
        SHA_IN=$CANON; sha256hex_of; prev_hash=$SHA_OUT
        jget "$body" type
        [[ $JG != 0 && ${NS[$JG]} == placement ]] || continue
        jget "$body" coord; cs=${NS[$JG]}
        jget "$body" text_sha256; th=${NS[$JG]}
        jget "$body" file_sha256; fh=${NS[$JG]}
        jget "$body" att; ab=${NS[$JG]}
        jget "$body" turn; turn_raw=${NS[$JG]}
        jget "$body" actor; actor=${NS[$JG]}
        if [[ -z $cs || -z $th || -z $fh || -z $ab ]]; then
            verify_fail $checked "event $seq lacks coord/text_sha256/file_sha256/att"; return
        fi
        if [[ -n ${SEEN[$cs]+x} ]]; then
            verify_fail $checked "coordinate reused at $cs"; return
        fi
        if [[ -z ${SC[$cs]+x} ]]; then
            verify_fail $checked "placement missing at $cs"; return
        fi
        SHA_IN=${SC[$cs]}; sha256hex_of
        if [[ $SHA_OUT != "$th" ]]; then
            verify_fail $checked "placement hash mismatch at $cs"; return
        fi
        if [[ -z ${IDX[$cs]+x} ]]; then
            verify_fail $checked "index mismatch at $cs"; return
        fi
        local -a iefields
        IFS=$'\x1c' read -ra iefields <<< "${IDX[$cs]}"
        if [[ ${iefields[1]} != "$th" || ${iefields[0]} != "$turn_raw" || ${iefields[2]} != "$actor" ]]; then
            verify_fail $checked "index mismatch at $cs"; return
        fi
        # attestation descriptor (canonical JSON), signed by the actor
        jobj_new; local desc=$JN_ID
        jget "$body" turn; local turn_node=$JG
        jobj_set $desc turn $turn_node
        jstr_new "$cs"; jobj_set $desc coordinate $JN_ID
        jstr_new "$th"; jobj_set $desc scroll_sha256 $JN_ID
        jstr_new "$fh"; jobj_set $desc file_sha256 $JN_ID
        json_canon "$desc"
        B64_IN=$ab; b64_decode_of
        if ! verify_signature "$pubkeys" "$CANON" "$B64_OUT"; then
            verify_fail $checked "event $seq signature: gpg verify failed"; return
        fi
        SEEN[$cs]=1
        checked=$((checked + 1))
    done
    if (( checked == 0 )); then
        verify_fail 0 "no placement events found"; return
    fi
    for k in "${!IDX[@]}"; do
        if [[ -z ${SEEN[$k]+x} ]]; then
            verify_fail $checked "index lists a placement with no event: $k"; return
        fi
    done
    jobj_new; local r=$JN_ID
    jstr_new "$IMPL"; jobj_set $r impl $JN_ID
    jstr_new "pass"; jobj_set $r verdict $JN_ID
    jnum_new "$checked"; jobj_set $r placements_checked $JN_ID
    jnull_new; jobj_set $r first_failure $JN_ID
    RESP_ID=$r
}
req_state() {
    # $1 req node id -> STATE_OUT
    STATE_OUT=""
    jget "$1" state
    if [[ $JG != 0 ]]; then B64_IN=${NS[$JG]}; b64_decode_of; STATE_OUT=$B64_OUT; return; fi
    jget "$1" state_b64
    if [[ $JG != 0 ]]; then B64_IN=${NS[$JG]}; b64_decode_of; STATE_OUT=$B64_OUT; fi
}
handle() {
    local line=$1
    json_parse "$line"
    local req=$JROOT
    if [[ $req == 0 ]]; then
        jobj_new; local r=$JN_ID
        jstr_new "JSON parse error: $JERR"; jobj_set $r error $JN_ID
        json_canon $r; RESP=$CANON; return
    fi
    jget "$req" cmd; local cmd=${NS[$JG]}
    case $cmd in
        id)
            jobj_new; local r=$JN_ID
            jstr_new "$IMPL"; jobj_set $r impl $JN_ID
            json_canon $r; RESP=$CANON;;
        echo)
            jget "$req" ping; local ping=$JG
            echo_value "$ping"
            jobj_new; local r=$JN_ID
            jstr_new "$IMPL"; jobj_set $r impl $JN_ID
            jstr_new "$ECHO_OUT"; jobj_set $r echo $JN_ID
            json_canon $r; RESP=$CANON;;
        elect)
            jget "$req" position; local position=${NS[$JG]}
            jget "$req" candidates; local cand=$JG
            jget "$req" turn; local turn=${NS[$JG]}
            elect_winner "$position" "$cand" "$turn"
            jobj_new; local r=$JN_ID
            jstr_new "$ELECT_OUT"; jobj_set $r elect $JN_ID
            json_canon $r; RESP=$CANON;;
        choose)
            jget "$req" position; local position=${NS[$JG]}
            jget "$req" turn; local turn=${NS[$JG]}
            req_state "$req"
            choose_adventure "$STATE_OUT" "$position" "$turn"
            json_canon $RESP_ID; RESP=$CANON;;
        apply)
            jget "$req" step; local step=$JG
            req_state "$req"
            apply_step "$STATE_OUT" "$step"
            json_canon $RESP_ID; RESP=$CANON;;
        keygen)
            do_keygen
            json_canon $RESP_ID; RESP=$CANON;;
        attest)
            jget "$req" descriptor; local desc=$JG
            json_canon "$desc"
            detach_sign "$CANON"
            jobj_new; local r=$JN_ID
            jstr_new "$SIG_OUT"; jobj_set $r signature $JN_ID
            json_canon $r; RESP=$CANON;;
        init)
            req_state "$req"
            explode "$STATE_OUT"
            CACHE=(); local k
            for k in "${!EXPL[@]}"; do CACHE[$k]=${EXPL[$k]}; done
            CACHE_SET=1
            jobj_new; local r=$JN_ID
            jstr_new "$IMPL"; jobj_set $r impl $JN_ID
            jstr_new "pass"; jobj_set $r verdict $JN_ID
            json_canon $r; RESP=$CANON;;
        validate)
            req_state "$req"
            # NOTE: req_state may re-run jget; req node ids stay valid
            do_validate "$req" "$STATE_OUT"
            json_canon $RESP_ID; RESP=$CANON;;
        verify)
            jget "$req" pubkeys; local pubkeys=${NS[$JG]}
            req_state "$req"
            do_verify "$STATE_OUT" "$pubkeys"
            json_canon $RESP_ID; RESP=$CANON;;
        *)
            jobj_new; local r=$JN_ID
            jstr_new "unknown cmd $cmd"; jobj_set $r error $JN_ID
            json_canon $r; RESP=$CANON;;
    esac
}

if [[ ${1:-} == serve ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        # Game-scale framing (2026-11-24): lines over 8 KB may arrive
        # gzip-framed as "GZ1:" + base64(gzip(line)) -- the fleet-ssh
        # channel is ~25-70 KB/s and raw base64 state lines took
        # minutes at 1,000 placements. Lossless; plain lines unchanged.
        if [[ $line == GZ1:* ]]; then
            line=$(printf '%s' "${line:4}" | base64 -d | gzip -dc)
        fi
        handle "$line"
        if (( ${#RESP} > 8192 )); then
            RESP="GZ1:$(printf '%s' "$RESP" | gzip -c | base64 -w0)"
        fi
        printf '%s\n' "$RESP"
    done
else
    IFS= read -r -d '' ALL || true
    handle "${ALL%$'\n'}"
    printf '%s\n' "$RESP"
fi
