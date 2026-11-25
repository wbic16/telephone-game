// Hub-side CLI for libphext-objc (Exocortical Telephone Game,
// contract v2). Transport: no argument = one JSON object on stdin,
// one JSON response on stdout; argument `serve` = one JSON request
// per line. State travels as base64. Phext logic is this port's own
// Phext.m; SHA-256 is native (Wire.m); JSON via Foundation
// NSJSONSerialization with canonical output from Wire.m. PGP:
// subprocess gpg (NSTask) with per-port GNUPGHOME
// ~/telephone-objc/keys on the hub.
#import <Foundation/Foundation.h>
#import "Phext.h"
#import "Wire.h"

static NSString *const IMPL = @"objc";
static NSString *const KeyHome = @"/home/wbic16/telephone-objc/keys";

static NSArray<PhextScroll *> *CacheMap = nil;
static BOOL CacheOK = NO;

static NSData *B64Dec(NSString *s) {
    if (!s) return [NSData data];
    return [[NSData alloc] initWithBase64EncodedString:s
                                                options:0];
}

static NSString *B64Enc(NSData *d) {
    return [d base64EncodedStringWithOptions:0];
}

static NSData *StateOf(NSDictionary *req) {
    NSString *s = req[@"state"];
    if (!s || s.length == 0) s = req[@"state_b64"];
    return B64Dec(s);
}

static BOOL MapFind(NSArray<PhextScroll *> *map, PhextCoord c,
                    NSData **outText) {
    for (PhextScroll *ps in map)
        if (PhextCoordEq(ps.coord, c)) {
            *outText = ps.text;
            return YES;
        }
    *outText = nil;
    return NO;
}

static int RunTask(NSString *prog, NSArray<NSString *> *args,
                   NSData *stdinData, NSData **outData,
                   NSString *gpgHome) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = prog;
    task.arguments = args;
    if (gpgHome) {
        NSMutableDictionary *env =
            [[[NSProcessInfo processInfo] environment] mutableCopy];
        env[@"GNUPGHOME"] = gpgHome;
        task.environment = env;
    }
    NSPipe *inPipe = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    task.standardOutput = outPipe;
    task.standardError = outPipe;
    [task launch];
    if (stdinData) [inPipe.fileHandleForWriting writeData:stdinData];
    [inPipe.fileHandleForWriting closeFile];
    *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return task.terminationStatus;
}

static void EnsureKeyHome(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:KeyHome
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *out;
    RunTask(@"/bin/chmod", @[ @"700", KeyHome ], nil, &out, nil);
}

static NSString *TrimWS(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *EnsureKey(void) {
    EnsureKeyHome();
    NSData *out;
    RunTask(@"/usr/bin/env",
            @[ [@"GNUPGHOME=" stringByAppendingString:KeyHome], @"gpg",
               @"--batch", @"--list-keys", @"--with-colons" ],
            nil, &out, nil);
    NSString *listing = [[NSString alloc] initWithData:out
                                              encoding:NSUTF8StringEncoding];
    if (![listing containsString:@"pub:"]) {
        RunTask(@"/usr/bin/env",
                @[ [@"GNUPGHOME=" stringByAppendingString:KeyHome],
                   @"gpg", @"--batch", @"--pinentry-mode", @"loopback",
                   @"--passphrase", @"", @"--quick-generate-key",
                   @"telephone-objc", @"ed25519", @"sign", @"never" ],
                nil, &out, nil);
    }
    RunTask(@"/usr/bin/env",
            @[ [@"GNUPGHOME=" stringByAppendingString:KeyHome], @"gpg",
               @"--batch", @"--armor", @"--export", @"telephone-objc" ],
            nil, &out, nil);
    return TrimWS([[NSString alloc] initWithData:out
                                        encoding:NSUTF8StringEncoding]);
}

static NSString *SignDescriptor(id descriptor) {
    EnsureKey();
    NSData *data = [WireCanon(descriptor)
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *out;
    int rc = RunTask(@"/usr/bin/env",
                     @[ [@"GNUPGHOME=" stringByAppendingString:KeyHome],
                        @"gpg", @"--batch", @"--pinentry-mode",
                        @"loopback", @"--passphrase", @"",
                        @"--detach-sign", @"--armor", @"-u",
                        @"telephone-objc" ],
                     data, &out, nil);
    if (rc != 0) [NSException raise:@"Attest" format:@"signing failed"];
    return TrimWS([[NSString alloc] initWithData:out
                                        encoding:NSUTF8StringEncoding]);
}

static BOOL VerifySignature(NSString *pubkeys, NSString *sigB64,
                            NSData *data) {
    NSString *home = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"tel-objc-gpg"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:home error:nil];
    [fm createDirectoryAtPath:home withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:nil];
    NSString *sigFile = [home stringByAppendingPathComponent:@"sig.asc"];
    NSString *dataFile = [home stringByAppendingPathComponent:@"data"];
    [B64Dec(sigB64) writeToFile:sigFile atomically:NO];
    [data writeToFile:dataFile atomically:NO];
    NSData *out;
    NSString *envHome = [@"GNUPGHOME=" stringByAppendingString:home];
    int rc = RunTask(@"/usr/bin/env",
                     @[ envHome, @"gpg", @"--batch", @"--import" ],
                     [pubkeys dataUsingEncoding:NSUTF8StringEncoding],
                     &out, nil);
    if (rc != 0) return NO;
    rc = RunTask(@"/usr/bin/env",
                 @[ envHome, @"gpg", @"--batch", @"--verify", sigFile,
                    dataFile ],
                 nil, &out, nil);
    [fm removeItemAtPath:home error:nil];
    return rc == 0;
}

static NSData *ApplyStep(NSData *data, NSDictionary *step,
                         NSString **fetchSha) {
    *fetchSha = nil;
    NSString *op = step[@"op"];
    PhextCoord c = PhextCoordParse(step[@"coordinate"]);
    if ([op isEqualToString:@"fetch"] ||
        [op isEqualToString:@"navigate"]) {
        *fetchSha = WireSha256Hex([Phext fetch:data at:c]);
        return data;
    }
    NSMutableArray *map = [[Phext phokenize:data] mutableCopy];
    BOOL done = NO;
    for (PhextScroll *ps in map) {
        if (PhextCoordEq(ps.coord, c)) {
            done = YES;
            if ([op isEqualToString:@"insert"]) {
                NSMutableData *m = [ps.text mutableCopy];
                [m appendData:WireTextToBytes(step[@"text"] ?: @"")];
                ps.text = m;
            } else if ([op isEqualToString:@"replace"]) {
                ps.text = WireTextToBytes(step[@"text"] ?: @"");
            } else if ([op isEqualToString:@"remove"]) {
                ps.text = [NSData data];
            } else {
                [NSException raise:@"Apply"
                            format:@"unknown op %@", op];
            }
        }
    }
    if (!done && ![op isEqualToString:@"remove"]) {
        [map addObject:[PhextScroll
                            scrollWithCoord:c
                                       text:WireTextToBytes(
                                                step[@"text"] ?: @"")]];
    }
    return [Phext dephokenize:map];
}

static NSDictionary *VFail(NSUInteger n, NSString *msg) {
    return @{@"impl" : IMPL,
             @"verdict" : @"fail",
             @"placements_checked" : @(n),
             @"first_failure" : @{@"detail" : msg}};
}

static NSDictionary *VerifyStress(NSData *data) {
    NSArray<PhextScroll *> *map = [Phext phokenize:data];
    NSData *txt;
    NSData *keysData = [NSData data];
    if (MapFind(map, PhextCoordParse(@"1.1.1/1.1.1/1.1.2"), &txt))
        keysData = txt;
    if (MapFind(map, PhextCoordParse(@"1.1.1/1.1.1/1.1.3"), &txt)) {
        if (![WireSha256Hex(keysData)
                isEqualToString:TrimWS(WireBytesToText(txt))])
            return VFail(0, @"keys-hash scroll does not match keys");
    }
    NSString *keysText = WireBytesToText(keysData);
    // events sorted by seq component
    NSMutableArray *events = [NSMutableArray array];
    for (PhextScroll *ps in map) {
        PhextCoord c = ps.coord;
        if (c.v[0] == 1 && c.v[1] == 1 && c.v[2] == 1 && c.v[3] == 1 &&
            c.v[4] == 1 && c.v[5] == 1 && c.v[6] == 2 && c.v[7] == 1)
            [events addObject:ps];
    }
    [events sortUsingComparator:^NSComparisonResult(PhextScroll *a,
                                                    PhextScroll *b) {
        return a.coord.v[8] < b.coord.v[8] ? NSOrderedAscending
                                           : NSOrderedDescending;
    }];
    NSUInteger checked = 0;
    NSString *prevHash = nil;
    NSMutableSet *placed = [NSMutableSet set];
    NSMutableDictionary *placedHash = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < events.count; i++) {
        PhextScroll *ps = events[i];
        if (ps.coord.v[8] != (long long)(i + 1))
            return VFail(checked, @"event seq gap");
        NSDictionary *ev = [NSJSONSerialization
            JSONObjectWithData:ps.text options:0 error:nil];
        id prev = ev[@"prev"];
        if (!prevHash) {
            if (prev != [NSNull null])
                return VFail(checked, @"event chain broken");
        } else if (![prev isEqualToString:prevHash]) {
            return VFail(checked, @"event chain broken");
        }
        NSDictionary *body = ev[@"body"];
        prevHash = WireSha256Hex([WireCanon(body)
            dataUsingEncoding:NSUTF8StringEncoding]);
        if ([body[@"type"] isEqualToString:@"placement"]) {
            NSString *coordS = body[@"coord"];
            if ([placed containsObject:coordS])
                return VFail(checked, @"coordinate reused");
            PhextCoord c = PhextCoordParse(coordS);
            if (!MapFind(map, c, &txt))
                return VFail(checked, @"placement scroll missing");
            if (![WireSha256Hex(txt)
                    isEqualToString:body[@"text_sha256"]])
                return VFail(checked, @"placement scroll hash mismatch");
            NSDictionary *desc = @{
                @"turn" : body[@"turn"],
                @"coordinate" : coordS,
                @"scroll_sha256" : body[@"text_sha256"],
                @"file_sha256" : body[@"file_sha256"]
            };
            if (!VerifySignature(keysText, body[@"att"],
                                 [WireCanon(desc)
                                     dataUsingEncoding:
                                         NSUTF8StringEncoding]))
                return VFail(checked, @"attestation fails");
            [placed addObject:coordS];
            placedHash[coordS] = body[@"text_sha256"];
            checked++;
        }
    }
    NSData *idxData = [NSData data];
    if (MapFind(map, PhextCoordParse(@"1.1.1/1.1.1/1.1.1"), &txt))
        idxData = txt;
    NSString *idxText = WireBytesToText(idxData);
    NSUInteger lines = 0;
    for (NSString *line in
         [idxText componentsSeparatedByString:@"\n"]) {
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        lines++;
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count >= 3) {
            if (![placedHash[parts[1]] isEqualToString:parts[2]])
                return VFail(checked, @"index hash mismatch");
        }
    }
    if (lines != checked)
        return VFail(checked, @"index lines != placements");
    return @{@"impl" : IMPL,
             @"verdict" : @"pass",
             @"placements_checked" : @(checked),
             @"first_failure" : [NSNull null]};
}

static NSDictionary *Dispatch(NSDictionary *req) {
    NSString *cmd = req[@"cmd"];
    if ([cmd isEqualToString:@"id"]) return @{@"impl" : IMPL};
    if ([cmd isEqualToString:@"keygen"])
        return @{@"impl" : IMPL, @"pubkey" : EnsureKey()};
    if ([cmd isEqualToString:@"echo"]) {
        NSString *s = [NSString stringWithFormat:
            @"{\"impl\":\"%@\",\"ping\":%@}", IMPL,
            WireCanon(req[@"ping"])];
        return @{@"impl" : IMPL,
                 @"echo" : WireSha256Hex(
                     [s dataUsingEncoding:NSUTF8StringEncoding])};
    }
    if ([cmd isEqualToString:@"elect"]) {
        NSArray *cands = req[@"candidates"];
        NSMutableArray *pool = [NSMutableArray array];
        for (NSString *c in cands)
            if (![c isEqualToString:IMPL]) [pool addObject:c];
        if (pool.count == 0) pool = [cands mutableCopy];
        NSString *seed = WireSha256Hex([[NSString stringWithFormat:
            @"%@-elect:%@:%@:%@", IMPL, req[@"position"],
            req[@"turn"], [cands componentsJoinedByString:@","]]
            dataUsingEncoding:NSUTF8StringEncoding]);
        unsigned idx = 0;
        [[NSScanner scannerWithString:[seed substringToIndex:8]]
            scanHexInt:&idx];
        return @{@"elect" : pool[idx % pool.count]};
    }
    if ([cmd isEqualToString:@"choose"]) {
        NSData *data = StateOf(req);
        NSArray *map = [Phext phokenize:data];
        PhextCoord c = PhextCoordParse(req[@"position"]);
        NSData *t;
        while (MapFind(map, c, &t)) c.v[8] += 1;
        return @{@"op" : @"insert",
                 @"coordinate" : PhextCoordStr(c),
                 @"text" : [NSString stringWithFormat:
                     @"%@ was here, turn %@", IMPL, req[@"turn"]]};
    }
    if ([cmd isEqualToString:@"apply"]) {
        NSString *fs;
        NSData *out = ApplyStep(StateOf(req), req[@"step"], &fs);
        NSMutableDictionary *r = [@{@"state_b64" : B64Enc(out),
                                    @"state_sha256" : WireSha256Hex(out)}
            mutableCopy];
        if (fs) r[@"fetch_sha256"] = fs;
        return r;
    }
    if ([cmd isEqualToString:@"attest"]) {
        return @{@"signature" : B64Enc([SignDescriptor(req[@"descriptor"])
                     dataUsingEncoding:NSUTF8StringEncoding])};
    }
    if ([cmd isEqualToString:@"init"]) {
        CacheMap = [Phext phokenize:StateOf(req)];
        CacheOK = YES;
        return @{@"impl" : IMPL, @"verdict" : @"pass"};
    }
    if ([cmd isEqualToString:@"validate"]) {
        if (req[@"prior_state"]) {
            NSDictionary *step = req[@"step"];
            PhextCoord cc = PhextCoordParse(step[@"coordinate"]);
            NSArray *newMap = [Phext phokenize:StateOf(req)];
            NSArray *prior = [Phext phokenize:B64Dec(req[@"prior_state"])];
            NSData *pt;
            NSString *bad = nil;
            if (!MapFind(newMap, cc, &pt))
                bad = @"placed scroll missing";
            else if (![pt isEqualToData:WireTextToBytes(step[@"text"])])
                bad = @"placed scroll text != step text";
            else {
                for (PhextScroll *ps in prior) {
                    if (!MapFind(newMap, ps.coord, &pt) ||
                        ![pt isEqualToData:ps.text]) {
                        bad = @"prior scroll overwritten";
                        break;
                    }
                }
                if (!bad) {
                    NSUInteger added = 0;
                    for (PhextScroll *ps in newMap)
                        if (!MapFind(prior, ps.coord, &pt)) added++;
                    if (added != 1)
                        bad = @"expected exactly one added scroll";
                }
            }
            NSMutableDictionary *r = [@{@"impl" : IMPL} mutableCopy];
            if (!bad) {
                r[@"verdict"] = @"pass";
            } else {
                r[@"verdict"] = @"fail";
                r[@"detail"] = bad;
            }
            return r;
        }
        if (!CacheOK)
            return @{@"impl" : IMPL, @"verdict" : @"fail",
                     @"detail" : @"validate before init"};
        NSDictionary *step = req[@"step"];
        PhextCoord cc = PhextCoordParse(step[@"coordinate"]);
        PhextCoord ev = PhextCoordParse(req[@"event_coord"]);
        NSArray *newMap = [Phext phokenize:StateOf(req)];
        NSData *pt;
        NSString *bad = nil;
        if (!MapFind(newMap, cc, &pt) ||
            ![pt isEqualToData:WireTextToBytes(step[@"text"])])
            bad = @"placed scroll missing or altered";
        else {
            PhextCoord idxC = PhextCoordParse(@"1.1.1/1.1.1/1.1.1");
            for (PhextScroll *ps in CacheMap) {
                if (PhextCoordEq(ps.coord, idxC)) continue;
                if (!MapFind(newMap, ps.coord, &pt) ||
                    ![pt isEqualToData:ps.text]) {
                    bad = @"prior scroll overwritten";
                    break;
                }
            }
            if (!bad) {
                for (PhextScroll *ps in newMap) {
                    if (!MapFind(CacheMap, ps.coord, &pt) &&
                        !PhextCoordEq(ps.coord, cc) &&
                        !PhextCoordEq(ps.coord, ev)) {
                        bad = @"unexpected new scroll";
                        break;
                    }
                }
            }
            if (!bad) {
                if (!MapFind(newMap, idxC, &pt))
                    bad = @"index missing";
                else if (![WireBytesToText(pt)
                             containsString:req[@"index_line"]])
                    bad = @"index does not record the placement";
            }
        }
        NSMutableDictionary *r = [@{@"impl" : IMPL} mutableCopy];
        if (!bad) {
            r[@"verdict"] = @"pass";
            CacheMap = newMap;
        } else {
            r[@"verdict"] = @"fail";
            r[@"detail"] = bad;
        }
        return r;
    }
    if ([cmd isEqualToString:@"verify"])
        return VerifyStress(StateOf(req));
    if ([cmd isEqualToString:@"fetch"]) {
        NSData *t = [Phext fetch:StateOf(req)
                                at:PhextCoordParse(req[@"coordinate"])];
        return @{@"text_b64" : B64Enc(t), @"text" : WireBytesToText(t)};
    }
    if ([cmd isEqualToString:@"explode"]) {
        NSMutableDictionary *inner = [NSMutableDictionary dictionary];
        for (PhextScroll *ps in [Phext phokenize:StateOf(req)])
            inner[PhextCoordStr(ps.coord)] = B64Enc(ps.text);
        return @{@"map" : inner};
    }
    if ([cmd isEqualToString:@"implode"]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSDictionary *inner = req[@"map"];
        for (NSString *k in inner) m[k] = B64Dec(inner[k]);
        NSData *out = [Phext implode:m];
        return @{@"state_b64" : B64Enc(out),
                 @"state_sha256" : WireSha256Hex(out)};
    }
    if ([cmd isEqualToString:@"insert"]) {
        NSData *data = StateOf(req);
        PhextCoord c = PhextCoordParse(req[@"coordinate"]);
        NSData *t;
        if (MapFind([Phext phokenize:data], c, &t))
            return @{@"error" : @"coordinate already occupied"};
        NSData *out = [Phext insert:data at:c
                               text:B64Dec(req[@"text_b64"])];
        return @{@"state_b64" : B64Enc(out),
                 @"state_sha256" : WireSha256Hex(out)};
    }
    [NSException raise:@"Dispatch" format:@"unknown cmd %@", cmd];
    return nil;
}

// Game-scale framing (wave-2 pattern): lines over 8 KB may arrive
// as "GZ1:" + base64(gzip(line)) over the slow fleet-ssh channel;
// large replies are framed the same way. (De)compression shells to
// gzip/base64 via /bin/sh (Fortran precedent).
// (De)compression runs on temp files, not pipes: at game scale a
// pipe-fed child deadlocks against a parent that is still writing
// the multi-megabyte stdin while the child's stdout pipe is full.
static NSData *GzUnframe(NSData *lineData) {
    static const char prefix[4] = {'G', 'Z', '1', ':'};
    if (lineData.length >= 4 &&
        memcmp(lineData.bytes, prefix, 4) == 0) {
        [lineData writeToFile:@"/tmp/tel-objc-gz.b64" atomically:NO];
        NSData *out = nil;
        RunTask(@"/bin/sh",
                @[@"-c", @"sed 's/^GZ1://' /tmp/tel-objc-gz.b64 | "
                    @"base64 -d 2>/dev/null | gzip -dc "
                    @"> /tmp/tel-objc-req.bin"],
                nil, &out, nil);
        NSData *plain = [NSData dataWithContentsOfFile:
            @"/tmp/tel-objc-req.bin"];
        if (plain) return plain;
    }
    return lineData;
}

static NSString *GzFrame(NSString *resp) {
    NSData *data = [resp dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 8192) {
        [data writeToFile:@"/tmp/tel-objc-resp.bin" atomically:NO];
        NSData *out = nil;
        RunTask(@"/bin/sh",
                @[@"-c", @"gzip -c /tmp/tel-objc-resp.bin | "
                    @"base64 -w0 > /tmp/tel-objc-resp.b64"],
                nil, &out, nil);
        NSData *b64d = [NSData dataWithContentsOfFile:
            @"/tmp/tel-objc-resp.b64"];
        if (b64d) {
            NSString *b64 = [[[NSString alloc]
                initWithData:b64d encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return [@"GZ1:" stringByAppendingString:b64];
        }
    }
    return resp;
}

static void HandleLine(NSData *lineData) {
    @try {
        NSDictionary *req = [NSJSONSerialization
            JSONObjectWithData:GzUnframe(lineData) options:0 error:nil];
        NSDictionary *resp = Dispatch(req);
        printf("%s\n", [GzFrame(WireCanon(resp)) UTF8String]);
    } @catch (NSException *e) {
        printf("%s\n", [[NSString stringWithFormat:
            @"{\"error\":\"%@\"}", e.reason] UTF8String]);
    }
    fflush(stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL serve = argc >= 2 && strcmp(argv[1], "serve") == 0;
        NSMutableData *line = [NSMutableData data];
        int ch;
        BOOL any = NO;
        while ((ch = getchar()) != EOF) {
            any = YES;
            if (ch == '\n') {
                if (line.length > 0) HandleLine(line);
                line = [NSMutableData data];
                if (!serve) break;
            } else {
                unsigned char b = (unsigned char)ch;
                [line appendBytes:&b length:1];
            }
        }
        if (line.length > 0) HandleLine(line);
        (void)any;
    }
    return 0;
}
