#!/bin/sh
# Hub CLI runner for libphext-cfml: one JSON request on stdin, one
# JSON response on stdout. Lines over 8 KB travel GZ1-framed both
# ways.
#
# Fast path: a warm Lucee daemon (port/src/daemon.cfm, one
# long-lived CommandBox context) serves the request from the
# queue directory — no per-call JVM/Lucee boot. Fallback: the
# original one-shot CommandBox run of port/src/cli.cfm, used
# whenever the daemon cannot be started or does not answer in
# time. Both paths execute the same cli.cfm dispatch and the
# same on-disk init cache; the daemon caches no verdicts.
D=$HOME/telephone-cfml
mkdir -p $D/cache $D/cache/queue
REQ=$(mktemp $D/cache/req.XXXXXX)
RESP=$(mktemp $D/cache/resp.XXXXXX)
cat > $REQ.raw
if grep -q '^GZ1:' $REQ.raw; then
  sed 's/^GZ1://' $REQ.raw | base64 -d 2>/dev/null | gzip -dc > $REQ
else
  mv $REQ.raw $REQ
fi

emit_resp() {
  if [ -s $RESP ]; then
    if [ $(wc -c < $RESP) -gt 8192 ]; then
      printf 'GZ1:'; gzip -c $RESP | base64 -w0; echo
    else
      cat $RESP; echo
    fi
  else
    echo '{"error":"cfml cli produced no response"}'
  fi
}

daemon_alive() {
  [ -f $D/cache/daemon.heartbeat ] || return 1
  hb=$(cat $D/cache/daemon.heartbeat 2>/dev/null)
  case "$hb" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - hb)) -le 10 ]
}

ensure_daemon() {
  daemon_alive && return 0
  # A live pid with a stale heartbeat is a BUSY daemon (its loop
  # is inside a request), not a dead one: wait for the heartbeat
  # to freshen before ever declaring it dead.
  if [ -f $D/cache/daemon.pid ]; then
    pid=$(cat $D/cache/daemon.pid 2>/dev/null)
    if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
      i=0
      while [ $i -lt 120 ]; do
        daemon_alive && return 0
        kill -0 $pid 2>/dev/null || break
        sleep 0.5; i=$((i+1))
      done
      daemon_alive && return 0
    fi
  fi
  lock=$D/cache/daemon-start.lock
  if mkdir $lock 2>/dev/null; then
    if [ -f $D/cache/daemon.pid ]; then
      kill $(cat $D/cache/daemon.pid 2>/dev/null) 2>/dev/null
    fi
    rm -f $D/cache/daemon.ready
    (setsid $D/boxzip/box $D/port/src/daemon.cfm \
       >>$D/cache/daemon.log 2>&1 </dev/null &)
    rmdir $lock 2>/dev/null
  fi
  # Cold JVM/Lucee boot under hub load can take well over 40 s;
  # waiting for the daemon is never worse than falling back to
  # a second, competing one-shot boot of the same size.
  i=0
  while [ $i -lt 240 ]; do
    daemon_alive && return 0
    sleep 0.5; i=$((i+1))
  done
  return 1
}

ID=$(basename $REQ)
served=0
if ensure_daemon; then
  cp $REQ $D/cache/queue/$ID.tmp
  mv $D/cache/queue/$ID.tmp $D/cache/queue/$ID.req
  i=0
  while [ $i -lt 200 ]; do
    if [ -f $D/cache/queue/$ID.resp ]; then served=1; break; fi
    sleep 0.5; i=$((i+1))
  done
  if [ $served -eq 1 ]; then
    mv $D/cache/queue/$ID.resp $RESP
  else
    rm -f $D/cache/queue/$ID.req $D/cache/queue/$ID.resp \
          $D/cache/queue/$ID.resp.tmp
  fi
fi

if [ $served -eq 0 ]; then
  TELCFML_REQ=$REQ TELCFML_RESP=$RESP $D/boxzip/box $D/port/src/cli.cfm \
    >/dev/null 2>$D/cache/box.err
fi
emit_resp
rm -f $REQ $REQ.raw $RESP
