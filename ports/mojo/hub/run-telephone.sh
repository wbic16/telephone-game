#!/bin/bash
# Hub runner for the mojo telephone CLI: the compiled Mojo binary takes
# (request-file, response-file) per invocation; this runner bridges
# stdin/stdout JSON lines to it, owns the port's GNUPGHOME, and does
# the GZ1 wire framing (lines >8 KB travel as "GZ1:"+base64(gzip(line))
# in both directions; the Mojo CLI itself is framing-free).
BIN="$HOME/telephone-mojo/bin/telephone"
export GNUPGHOME="$HOME/telephone-mojo/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
TMPD=$(mktemp -d /tmp/telephone-mojo-run.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
run_one() {
  "$BIN" "$TMPD/req" "$TMPD/resp"
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
  "$BIN" "$TMPD/req" "$TMPD/resp"
  cat "$TMPD/resp"
fi
