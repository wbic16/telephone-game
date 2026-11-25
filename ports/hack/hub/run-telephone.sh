#!/bin/bash
# Hub runner for the hack telephone CLI: the HHVM script takes
# (request-file, response-file) per invocation; this runner bridges
# stdin/stdout JSON lines to it, owns the port's GNUPGHOME, and does
# the GZ1 wire framing (lines >8 KB travel as "GZ1:"+base64(gzip(line))
# in both directions; the Hack CLI itself is framing-free).
HHVM="$HOME/telephone-hack/bin/hhvm"
SCRIPT="$HOME/telephone-hack/src/telephone.hack"
export GNUPGHOME="$HOME/telephone-hack/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
TMPD=$(mktemp -d /tmp/telephone-hack-run.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
run_one() {
  "$HHVM" "$SCRIPT" "$TMPD/req" "$TMPD/resp"
  if [ -s "$TMPD/resp" ] && [ "$(stat -c%s "$TMPD/resp")" -gt 8192 ]; then
    printf 'GZ1:'
    gzip -c "$TMPD/resp" | base64 -w0
    printf '\n'
  else
    cat "$TMPD/resp"
  fi
}
if [ "$1" = "serve" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      GZ1:*) printf '%s' "${line:4}" | base64 -d 2>/dev/null | gzip -dc > "$TMPD/req" ;;
      *) printf '%s' "$line" > "$TMPD/req" ;;
    esac
    run_one
  done
else
  cat > "$TMPD/req"
  "$HHVM" "$SCRIPT" "$TMPD/req" "$TMPD/resp"
  cat "$TMPD/resp"
fi
