#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-algol
A68="$HOME/tools/a68g/bin/a68g --heap 6000000000 --stack 100000000 --frame 100000000"
# assemble the test program: BEGIN + library + base64/files + test main + END
{
  echo "BEGIN"
  cat port/src/phext.decl.a68
  cat port/src/b64.decl.a68
  cat port/tests/test-main.a68
  echo "END"
} > test_phext.a68
# assemble the CLI programs (serve + one-shot mains)
{
  echo "BEGIN"
  cat port/src/phext.decl.a68
  cat port/src/b64.decl.a68
  cat port/src/json.decl.a68
  cat port/src/game.decl.a68
  cat port/src/cli-serve.main.a68
  echo "END"
} > cli-serve.a68
{
  echo "BEGIN"
  cat port/src/phext.decl.a68
  cat port/src/b64.decl.a68
  cat port/src/json.decl.a68
  cat port/src/game.decl.a68
  cat port/src/cli-oneshot.main.a68
  echo "END"
} > cli-oneshot.a68
cat > run.sh <<'EOS'
#!/bin/sh
if [ "$1" = "serve" ]; then
  exec stdbuf -o0 $HOME/tools/a68g/bin/a68g --heap 6000000000 --stack 100000000 --frame 100000000 $HOME/telephone-algol/cli-serve.a68
else
  exec $HOME/tools/a68g/bin/a68g --heap 6000000000 --stack 100000000 --frame 100000000 $HOME/telephone-algol/cli-oneshot.a68
fi
EOS
chmod +x run.sh
mkdir -p gnupg
chmod 700 gnupg
echo "algol build ok"
