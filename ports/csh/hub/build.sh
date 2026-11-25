#!/bin/bash
# Assemble ~/telephone-csh: the run wrapper pins the micromamba
# tcsh, the per-port GNUPGHOME, and the port directory (the CLI
# locates phext.tcsh/json.tcsh next to itself via $0:h).
#
# run.sh owns the request-line intake loop on purpose: tcsh's
# $< input operator PARSES each line (quotes stripped, braces
# grouped), so JSON request lines cannot enter through tcsh's
# stdin. sh stages each line byte-exactly to $W/req.raw and the
# tcsh CLI does all protocol work from files. $W persists for
# the whole serve session so init's exploded-state cache is
# there for the following validate (deferred init).
set -e
H="$HOME/telephone-csh"
mkdir -p "$H/gnupg"
chmod 700 "$H/gnupg"
cat > "$H/run.sh" <<'EOS'
#!/bin/sh
export PATH="$HOME/tools/mamba-root/envs/csh/bin:$PATH"
export GNUPGHOME="$HOME/telephone-csh/gnupg"
cd "$HOME/telephone-csh/port"
W="/tmp/tel-csh-$$"
mkdir -p "$W"
if [ "$1" = "serve" ]; then
  while IFS= read -r line; do
    # dash's builtin printf: the request line can be ~3 MB and
    # an external printf would cap it at the 128 KB argv limit
    printf '%s' "$line" > "$W/req.raw"
    tcsh src/cli.tcsh handle "$W" > "$W/resp.txt"
    tcsh src/cli.tcsh emit "$W/resp.txt"
  done
else
  # one-shot wire form: the whole stdin is one request, with
  # no trailing newline
  cat > "$W/req.raw"
  tcsh src/cli.tcsh handle "$W" > "$W/resp.txt"
  tcsh src/cli.tcsh emit "$W/resp.txt"
fi
rm -rf "$W"
EOS
chmod +x "$H/run.sh"
echo "telephone-csh assembled"
