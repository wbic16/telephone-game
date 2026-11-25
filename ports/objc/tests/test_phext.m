// Test suite for libphext-objc -- plain assertions.
// Run: test_phext [fixtures_dir]; fixtures are directories holding
// input.phext; each must round-trip byte-identically and normalize
// idempotently. Covers coordinate-preserving REMOVE, DynamicPhext
// and TransitivePhext equivalence with the string API, and the
// native SHA-256 against a known vector.
#import <Foundation/Foundation.h>
#import "Phext.h"
#import "Wire.h"

static int checks = 0, failures = 0;

static void Ok(BOOL cond, NSString *name) {
    checks++;
    if (!cond) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", name.UTF8String);
    }
}

static NSData *D(const char *s) {
    return [NSData dataWithBytes:s length:strlen(s)];
}

static NSData *DB(NSData *a, unsigned char br, NSData *b) {
    NSMutableData *m = [a mutableCopy];
    [m appendBytes:&br length:1];
    [m appendData:b];
    return m;
}

static PhextCoord C(NSString *s) { return PhextCoordParse(s); }

static void EqD(NSData *a, NSData *b, NSString *name) {
    Ok([a isEqualToData:b],
       [NSString stringWithFormat:@"%@ (got len %lu, want len %lu)",
                                  name, (unsigned long)a.length,
                                  (unsigned long)b.length]);
}

static void EqS(NSData *a, NSString *b, NSString *name) {
    EqD(a, D(b.UTF8String), name);
}

static void WalkFixtures(NSString *dir, int *count, int *identical,
                         int *idem) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir
                                                   error:nil]) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir;
        [fm fileExistsAtPath:path isDirectory:&isDir];
        if (isDir) {
            WalkFixtures(path, count, identical, idem);
        } else if ([name isEqualToString:@"input.phext"]) {
            (*count)++;
            NSData *data = [NSData dataWithContentsOfFile:path];
            if ([[Phext normalize:data] isEqualToData:data])
                (*identical)++;
            else
                fprintf(stderr, "fixture round-trip differs: %s\n",
                        path.UTF8String);
            if ([[Phext normalize:[Phext normalize:data]]
                    isEqualToData:[Phext normalize:data]])
                (*idem)++;
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // SHA-256 known vector: sha256("abc")
        Ok([WireSha256Hex(D("abc"))
               isEqualToString:@"ba7816bf8f01cfea414140de5dae2223"
                                "b00361a396177a9cb410ff61f20015ad"],
           @"sha256(abc)");

        // coordinate
        Ok([PhextCoordStr(C(@"1.2.3/4.5.6/7.8.9"))
               isEqualToString:@"1.2.3/4.5.6/7.8.9"],
           @"coord format");
        Ok(PhextCoordCmp(C(@"1.1.1/1.1.1/1.1.1"),
                         C(@"1.1.1/1.1.1/1.1.2")) < 0, @"order scroll");
        @try {
            C(@"0.1.1/1.1.1/1.1.1");
            Ok(NO, @"coord rejects 0");
        } @catch (NSException *e) {
            Ok(YES, @"coord rejects 0");
        }
        @try {
            C(@"1.1/1.1.1/1.1.1");
            Ok(NO, @"coord rejects short");
        } @catch (NSException *e) {
            Ok(YES, @"coord rejects short");
        }

        // phokenize
        NSArray *sc = [Phext phokenize:D("hello")];
        Ok(sc.count == 1, @"one scroll");
        Ok([PhextCoordStr([sc[0] coord])
               isEqualToString:@"1.1.1/1.1.1/1.1.1"], @"first coord");
        EqD([sc[0] text], D("hello"), @"first text");
        NSData *gap = DB(DB(D("a"), 0x17, D("b")), 0x17,
                         DB(D(""), 0x17, D("c\nline2")));
        sc = [Phext phokenize:gap];
        Ok(sc.count == 3, @"scroll breaks");
        Ok([PhextCoordStr([sc[1] coord])
               isEqualToString:@"1.1.1/1.1.1/1.1.2"], @"second coord");
        Ok([PhextCoordStr([sc[2] coord])
               isEqualToString:@"1.1.1/1.1.1/1.1.4"],
           @"gap coord advance");
        EqD([sc[2] text], D("c\nline2"), @"newline is ordinary text");
        sc = [Phext phokenize:DB(D("x"), 0x01, D("y"))];
        Ok([PhextCoordStr([sc[1] coord])
               isEqualToString:@"2.1.1/1.1.1/1.1.1"],
           @"library break resets");
        Ok([Phext phokenize:[NSData data]].count == 0, @"empty buffer");
        {
            unsigned char raw[] = {'a', 0x00, 0xFF, 'b'};
            sc = [Phext phokenize:[NSData dataWithBytes:raw length:4]];
            Ok(sc.count == 1, @"binary text is one scroll");
            Ok([sc[0] text].length == 4, @"binary text preserved");
        }

        // round trip
        NSData *sample = DB(DB(D("alpha"), 0x17, D("beta")), 0x18,
                            DB(D("gamma"), 0x01, D("delta")));
        EqD([Phext dephokenize:[Phext phokenize:sample]], sample,
            @"round trip sample");

        // fetch incl. gaps
        NSData *buf = DB(DB(D("one"), 0x17, D("two")), 0x17,
                         DB(D(""), 0x17, D("four")));
        EqS([Phext fetch:buf at:C(@"1.1.1/1.1.1/1.1.1")], @"one",
            @"fetch 1");
        EqS([Phext fetch:buf at:C(@"1.1.1/1.1.1/1.1.4")], @"four",
            @"fetch 4");
        EqS([Phext fetch:buf at:C(@"1.1.1/1.1.1/1.1.3")], @"",
            @"gap fetch is empty");
        EqS([Phext fetch:buf at:C(@"9.9.9/9.9.9/9.9.9")], @"",
            @"far gap fetch is empty");

        // insert
        NSData *out = [Phext insert:D("base") at:C(@"1.1.1/1.1.1/1.1.1")
                               text:D("+more")];
        EqS([Phext fetch:out at:C(@"1.1.1/1.1.1/1.1.1")], @"base+more",
            @"insert appends after existing");
        out = [Phext insert:[NSData data] at:C(@"1.1.1/1.1.1/1.1.3")
                       text:D("new")];
        EqD(out, DB(DB(D(""), 0x17, D("")), 0x17, D("new")),
            @"insert at gap emits breaks");

        // replace / remove: REMOVE IS COORDINATE-PRESERVING
        out = [Phext replace:DB(D("old"), 0x17, D("keep"))
                          at:C(@"1.1.1/1.1.1/1.1.1") text:D("new")];
        EqD(out, DB(D("new"), 0x17, D("keep")), @"replace overwrites");
        NSData *abc = DB(DB(D("a"), 0x17, D("b")), 0x17, D("c"));
        out = [Phext remove:abc at:C(@"1.1.1/1.1.1/1.1.2")];
        EqD(out, DB(DB(D("a"), 0x17, D("")), 0x17, D("c")),
            @"remove leaves a gap");
        EqS([Phext fetch:out at:C(@"1.1.1/1.1.1/1.1.2")], @"",
            @"removed coordinate reads empty");
        EqS([Phext fetch:out at:C(@"1.1.1/1.1.1/1.1.3")], @"c",
            @"neighbour keeps its coordinate");
        Ok([Phext remove:D("only") at:C(@"1.1.1/1.1.1/1.1.1")].length ==
               0,
           @"remove sole scroll");
        EqD([Phext remove:D("a") at:C(@"5.5.5/5.5.5/5.5.5")], D("a"),
            @"remove gap is a no-op");

        // DynamicPhext equivalence
        DynamicPhext *dyn = [[DynamicPhext alloc] initWithBuffer:abc];
        EqS([dyn fetchAt:C(@"1.1.1/1.1.1/1.1.2")], @"b", @"dyn fetch");
        [dyn insertAt:C(@"1.1.1/1.1.1/1.1.2") text:D("!")];
        EqS([dyn fetchAt:C(@"1.1.1/1.1.1/1.1.2")], @"b!",
            @"dyn insert merges");
        [dyn replaceAt:C(@"1.1.1/1.1.1/1.1.5") text:D("deep")];
        [dyn removeAt:C(@"1.1.1/1.1.1/1.1.1")];
        EqS([dyn fetchAt:C(@"1.1.1/1.1.1/1.1.1")], @"",
            @"dyn remove is a gap");
        EqS([dyn fetchAt:C(@"1.1.1/1.1.1/1.1.3")], @"c",
            @"dyn neighbour unshifted");
        NSData *stringPath = [Phext
            remove:[Phext insert:[Phext insert:abc
                                             at:C(@"1.1.1/1.1.1/1.1.2")
                                           text:D("!")]
                              at:C(@"1.1.1/1.1.1/1.1.5")
                            text:D("deep")]
                at:C(@"1.1.1/1.1.1/1.1.1")];
        EqD([dyn serialize], stringPath, @"dyn serialize = string path");
        Ok(dyn.capacity >= dyn.count, @"dyn capacity >= count");

        // TransitivePhext equivalence
        TransitivePhext *trn =
            [[TransitivePhext alloc] initWithBuffer:abc];
        EqS([trn fetchAt:C(@"1.1.1/1.1.1/1.1.3")], @"c", @"trans fetch");
        [trn insertAt:C(@"1.1.1/1.1.1/1.1.2") text:D("!")];
        [trn replaceAt:C(@"2.1.1/1.1.1/1.1.1") text:D("lib2")];
        [trn removeAt:C(@"1.1.1/1.1.1/1.1.1")];
        EqS([trn fetchAt:C(@"1.1.1/1.1.1/1.1.1")], @"",
            @"trans remove is a gap");
        EqS([trn fetchAt:C(@"1.1.1/1.1.1/1.1.3")], @"c",
            @"trans neighbour unshifted");
        EqD([trn serialize],
            DB(DB(DB(D(""), 0x17, D("b!")), 0x17, D("c")), 0x01,
               D("lib2")),
            @"trans serialize = string path");

        // fixtures
        if (argc >= 2) {
            int count = 0, identical = 0, idem = 0;
            WalkFixtures([NSString stringWithUTF8String:argv[1]],
                         &count, &identical, &idem);
            printf("fixtures: %d/%d byte-identical, %d/%d "
                   "normalize-idempotent\n",
                   identical, count, idem, count);
            Ok(identical == count, @"fixtures all byte-identical");
            Ok(count == 16, @"fixture count is 16");
        }

        printf("objc suite: %d checks, %d failures\n", checks, failures);
        return failures > 0 ? 1 : 0;
    }
}
