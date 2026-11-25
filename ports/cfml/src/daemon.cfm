<cfscript>
// Warm daemon for libphext-cfml: keeps one Lucee context (and
// the compiled cli/phext sources) alive on the hub and serves
// hub CLI requests from a queue directory (~/telephone-cfml/
// cache/queue), one at a time, in filename order. hub/run-cli.sh
// drops <id>.req files (atomically renamed into place) and
// waits for <id>.resp; it falls back to the one-shot CommandBox
// run whenever the daemon is not answering, so this daemon is
// an accelerator, never a single point of failure.
//
// The daemon exits when the port sources change on disk (hash
// check every heartbeat — a code sync never leaves stale code
// serving) or when cache/daemon.stop appears. It re-reads the
// on-disk init cache (cache/state.b64) on every validate,
// exactly like the one-shot path: no verdicts or state are
// cached in the process across requests beyond what cli.cfm
// itself keeps on disk.

include "cli.cfm";

function daemonSrcHash() {
    var base = homeDir() & "/telephone-cfml/port/src/";
    return hash(fileRead(base & "phext.cfm", "utf-8") &
                fileRead(base & "cli.cfm", "utf-8") &
                fileRead(base & "daemon.cfm", "utf-8"), "SHA-256");
}
function daemonNowSec() {
    return int(createObject("java", "java.lang.System")
        .currentTimeMillis() / 1000);
}

qDir = cacheDir() & "/queue";
if (!directoryExists(qDir)) directoryCreate(qDir);
myHash = daemonSrcHash();
try {
    var pid = createObject("java", "java.lang.ProcessHandle")
        .current().pid();
    fileWrite(cacheDir() & "/daemon.pid", toString(pid), "utf-8");
} catch (any e) {
    // pid file is a convenience for run-cli.sh stale cleanup;
    // the heartbeat below is the liveness signal of record.
}
fileWrite(cacheDir() & "/daemon.heartbeat",
          toString(daemonNowSec()), "utf-8");
fileWrite(cacheDir() & "/daemon.ready", myHash, "utf-8");
idle = 0;
while (true) {
    if (fileExists(cacheDir() & "/daemon.stop")) {
        fileDelete(cacheDir() & "/daemon.stop");
        break;
    }
    var reqs = directoryList(qDir, false, "name", "*.req", "asc");
    if (arrayLen(reqs) > 0) {
        idle = 0;
        // heartbeat at request start too: a daemon busy on one
        // long request must not look dead to run-cli.sh (which
        // also pid-checks before ever killing — see ensure_daemon)
        fileWrite(cacheDir() & "/daemon.heartbeat",
                  toString(daemonNowSec()), "utf-8");
        var name = reqs[1];
        var id = reReplace(name, "\.req$", "");
        processRequestFile(qDir & "/" & name,
                           qDir & "/" & id & ".resp.tmp");
        fileMove(qDir & "/" & id & ".resp.tmp",
                 qDir & "/" & id & ".resp");
        fileDelete(qDir & "/" & name);
    } else {
        sleep(25);
        idle++;
        if (idle % 20 == 0) {
            fileWrite(cacheDir() & "/daemon.heartbeat",
                      toString(daemonNowSec()), "utf-8");
            if (daemonSrcHash() != myHash) break;
        }
    }
}
if (fileExists(cacheDir() & "/daemon.ready")) {
    fileDelete(cacheDir() & "/daemon.ready");
}
</cfscript>
