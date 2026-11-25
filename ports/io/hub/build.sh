#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-io
IOBIN=$HOME/tools/dl/io-src/build/_build/binaries/io
cat > run.sh <<EOS
#!/bin/sh
cd \$HOME/telephone-io/port || exit 1
if [ "\$1" = "serve" ]; then
  exec $IOBIN src/cli.io serve
else
  exec $IOBIN src/cli.io oneshot
fi
EOS
chmod +x run.sh
mkdir -p gnupg
chmod 700 gnupg
echo "io build ok"
