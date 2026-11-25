#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-elixir
cat > run.sh <<'EOS'
#!/bin/sh
export PATH=$HOME/tools/asdf-bin:$PATH
export ASDF_DATA_DIR=$HOME/tools/asdf-data
export PATH=$ASDF_DATA_DIR/shims:$PATH
export ASDF_ERLANG_VERSION=27.3.4.20
export ASDF_ELIXIR_VERSION=main-otp-27
exec elixir $HOME/telephone-elixir/port/src/cli.ex "$@"
EOS
chmod +x run.sh
# smoke: the CLI loads
./run.sh </dev/null
echo "elixir build ok"
