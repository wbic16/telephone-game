#!/bin/bash
# Hub runner for the smalltalk telephone CLI: the Pharo VM takes
# (request-file, response-file) per invocation via the port's run.st;
# this runner bridges stdin/stdout JSON lines to it, owns the port's
# GNUPGHOME, and does the GZ1 wire framing (lines >8 KB travel as
# "GZ1:"+base64(gzip(line)) in both directions; the Smalltalk CLI itself
# is framing-free).
# Modes: `serve` = persistent line loop; no arg = one-shot (all of stdin
# is one request).
set -u
BASE="$HOME/telephone-smalltalk"
export GNUPGHOME="$BASE/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
VM="$BASE/pharo12/bin/pharo"
IMAGE="$BASE/pharo12/Pharo12.0-SNAPSHOT-64bit-7d5f14cb47.image"
RUNST="$BASE/run.st"
TMPD="$(mktemp -d /tmp/telephone-smalltalk-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

run_one() {
    if [ "${req_head}" = "test" ]; then
        out="$("$VM" --headless "$IMAGE" st "$RUNST" test "$fixtures_dir" 2>/dev/null | grep -a -E '^(fixtures:|smalltalk suite:|FAIL:)' || true)"
        printf '%s\n' "$out"
        return
    fi
    "$VM" --headless "$IMAGE" st "$RUNST" "$TMPD/req.json" "$TMPD/resp.json" >/dev/null 2>"$TMPD/err.txt"
    if [ -s "$TMPD/resp.json" ]; then
        if [ "$(stat -c%s "$TMPD/resp.json")" -gt 8192 ]; then
            printf 'GZ1:'
            gzip -c "$TMPD/resp.json" | base64 -w0
            printf '\n'
        else
            cat "$TMPD/resp.json"
        fi
    else
        printf '%s\n' '{"error":"smalltalk: no response (see runner stderr)"}'
    fi
}

prepare() {
    # $1 = raw request text; sets req_head/fixtures_dir, writes req.json
    req_head="normal"
    fixtures_dir=""
    case "$1" in
        *'"cmd":"test"'*|*'"cmd": "test"'*)
            req_head="test"
            fixtures_dir="$(printf '%s' "$1" | sed -n 's/.*"fixtures"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            ;;
        *)
            printf '%s' "$1" > "$TMPD/req.json"
            ;;
    esac
}

if [ "${1:-}" = "serve" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            GZ1:*) req="$(printf '%s' "${line:4}" | base64 -d 2>/dev/null | gzip -dc)" ;;
            *) req="$line" ;;
        esac
        prepare "$req"
        run_one
    done
else
    req="$(cat)"
    prepare "$req"
    run_one
fi
