#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-scheme
cat > run.sh <<'EOS'
#!/bin/sh
export GUILE_AUTO_COMPILE=0
exec $HOME/tools/mamba-root/envs/scheme/bin/guile --no-auto-compile $HOME/telephone-scheme/port/src/cli.scm "$@"
EOS
chmod +x run.sh
echo "scheme build ok"
