#!/bin/bash
exec </dev/null
set -e
cd ~/telephone-erlang
export PATH=~/tools/asdf-bin:$PATH
export ASDF_DATA_DIR=~/tools/asdf-data
export PATH=$ASDF_DATA_DIR/shims:$PATH
export ASDF_ERLANG_VERSION=27.3.4.20
mkdir -p ebin
erlc -o ebin port/src/phext.erl port/src/dynamic_phext.erl port/src/transitive_phext.erl port/src/wire.erl port/src/telephone.erl port/tests/test_phext.erl
cat > run.sh <<'EOS'
#!/bin/sh
export PATH=$HOME/tools/asdf-bin:$PATH
export ASDF_DATA_DIR=$HOME/tools/asdf-data
export PATH=$ASDF_DATA_DIR/shims:$PATH
export ASDF_ERLANG_VERSION=27.3.4.20
exec erl -noshell -pa $HOME/telephone-erlang/ebin -run telephone boot -- "$@"
EOS
chmod +x run.sh
echo "erlang build ok"
