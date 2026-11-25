#!/bin/bash
exec </dev/null
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export MAMBA_ROOT_PREFIX=$HOME/tools/mamba-root
MM=$HOME/tools/micromamba
mkdir -p ~/tools/dl

install_csh() {
  echo "=== csh via micromamba ==="
  $MM create -y -p $MAMBA_ROOT_PREFIX/envs/csh -c conda-forge tcsh 2>&1 | tail -5
  $MAMBA_ROOT_PREFIX/envs/csh/bin/tcsh --version
}

install_algol() {
  echo "=== algol: Algol 68 Genie ==="
  cd ~/tools/dl
  for url in \
    "https://sourceforge.net/projects/algol68/files/algol68g/Algol%2068%20Genie%203.5.3/a68g-3.5.3.tar.gz/download" \
    "https://jmvdveer.home.xs4all.nl/algol/a68g-3.5.3.tar.gz" ; do
    echo "trying $url"
    curl -sL --max-time 300 -o a68g.tar.gz "$url" && tar tzf a68g.tar.gz >/dev/null 2>&1 && break
  done
  tar tzf a68g.tar.gz | head -3
  rm -rf a68g-src && mkdir a68g-src && tar xzf a68g.tar.gz -C a68g-src --strip-components=1
  cd a68g-src
  ./configure --prefix=$HOME/tools/a68g >/dev/null 2>&1
  make -j4 2>&1 | tail -3
  make install 2>&1 | tail -2
  $HOME/tools/a68g/bin/a68g --version 2>&1 | head -2
  echo 'print(("hello from a68g", newline))' > /tmp/t.a68
  $HOME/tools/a68g/bin/a68g /tmp/t.a68
}

install_icon() {
  echo "=== icon source build ==="
  cd ~/tools/dl
  for url in \
    "https://www2.cs.arizona.edu/icon/ftp/packages/unix/icon-v951src.tar.gz" \
    "https://github.com/gtownsend/icon/archive/refs/heads/master.tar.gz" ; do
    echo "trying $url"
    curl -sL --max-time 600 -o icon.tar.gz "$url" && tar tzf icon.tar.gz >/dev/null 2>&1 && break
  done
  tar tzf icon.tar.gz | head -3
  rm -rf icon-src && mkdir icon-src && tar xzf icon.tar.gz -C icon-src --strip-components=1
  cd icon-src
  ls
  make Configure name=linux 2>&1 | tail -3
  make -j4 2>&1 | tail -5
  ls bin/
  echo 'procedure main() write("hello from icon") end' > /tmp/t.icn
  ./bin/icont -s /tmp/t.icn -x
}

install_io() {
  echo "=== io source build ==="
  cd ~/tools/dl
  curl -sL --max-time 600 -o io.tar.gz "https://github.com/Iolanguage/io/archive/refs/heads/master.tar.gz"
  tar tzf io.tar.gz | head -3
  rm -rf io-src && mkdir io-src && tar xzf io.tar.gz -C io-src --strip-components=1
  cd io-src
  mkdir -p build && cd build
  cmake .. -DCMAKE_INSTALL_PREFIX=$HOME/tools/io -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
  make -j4 2>&1 | tail -5
  make install 2>&1 | tail -3
  ls $HOME/tools/io/bin/ 2>/dev/null
  echo 'writeln("hello from io")' > /tmp/t.io
  $HOME/tools/io/bin/io /tmp/t.io 2>&1 || ./_build/binaries/io /tmp/t.io 2>&1 || find . -name io -type f | head
}

case "$1" in
  csh) install_csh ;;
  algol) install_algol ;;
  icon) install_icon ;;
  io) install_io ;;
esac
echo "DONE $1 rc=$?"
