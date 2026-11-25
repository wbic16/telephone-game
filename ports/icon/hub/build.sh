#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-icon
export PATH=$HOME/tools/icon/bin:$PATH
cd port/src
icont -s -o telephone cli.icn
cd ~/telephone-icon
cat > run.sh <<'EOS'
#!/bin/sh
exec $HOME/telephone-icon/port/src/telephone "$@"
EOS
chmod +x run.sh port/src/telephone
echo "icon build ok"
