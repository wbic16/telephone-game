#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-forth
# gforth 0.7.3 make install does not stage the image; copy it in
[ -f ~/tools/gforth-0.7.3/lib/gforth/0.7.3/gforth.fi ] || cp /tmp/gforth-0.7.3/gforth.fi ~/tools/gforth-0.7.3/lib/gforth/0.7.3/ 2>/dev/null || true
cat > run.sh <<'EOS'
#!/bin/sh
exec $HOME/tools/gforth-0.7.3/bin/gforth $HOME/telephone-forth/port/src/telephone.fs "$@"
EOS
chmod +x run.sh
echo "forth build ok"
