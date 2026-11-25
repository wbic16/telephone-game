#import "Phext.h"

static const unsigned char DimBreaks[9] = {
    0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17};

static int BreakDim(unsigned char b) {
    for (int i = 0; i < 9; i++)
        if (DimBreaks[i] == b) return i;
    return -1;
}

PhextCoord PhextCoordMake(long long a, long long b, long long c,
                          long long d, long long e, long long f,
                          long long g, long long h, long long i) {
    PhextCoord r = {{a, b, c, d, e, f, g, h, i}};
    return r;
}

PhextCoord PhextCoordRoot(void) {
    return PhextCoordMake(1, 1, 1, 1, 1, 1, 1, 1, 1);
}

BOOL PhextCoordEq(PhextCoord a, PhextCoord b) {
    return PhextCoordCmp(a, b) == 0;
}

int PhextCoordCmp(PhextCoord a, PhextCoord b) {
    for (int i = 0; i < 9; i++) {
        if (a.v[i] < b.v[i]) return -1;
        if (a.v[i] > b.v[i]) return 1;
    }
    return 0;
}

NSString *PhextCoordStr(PhextCoord c) {
    return [NSString stringWithFormat:@"%lld.%lld.%lld/%lld.%lld.%lld/"
                                       "%lld.%lld.%lld",
                                      c.v[0], c.v[1], c.v[2], c.v[3],
                                      c.v[4], c.v[5], c.v[6], c.v[7],
                                      c.v[8]];
}

PhextCoord PhextCoordParse(NSString *s) {
    NSArray *groups = [s componentsSeparatedByString:@"/"];
    if (groups.count != 3)
        [NSException raise:@"InvalidCoordinate"
                    format:@"coordinate must be a.b.c/d.e.f/g.h.i: %@", s];
    long long vals[9];
    int n = 0;
    for (NSString *g in groups) {
        for (NSString *p in [g componentsSeparatedByString:@"."]) {
            if (n > 8 || p.length == 0)
                [NSException raise:@"InvalidCoordinate"
                            format:@"invalid coordinate: %@", s];
            vals[n++] = [p longLongValue];
            // reject non-numeric junk: round-trip the component
            if (![[NSString stringWithFormat:@"%lld", vals[n - 1]]
                    isEqualToString:p])
                [NSException raise:@"InvalidCoordinate"
                            format:@"invalid coordinate: %@", s];
        }
    }
    if (n != 9)
        [NSException raise:@"InvalidCoordinate"
                    format:@"invalid coordinate: %@", s];
    PhextCoord r;
    for (int i = 0; i < 9; i++) {
        if (vals[i] < 1)
            [NSException raise:@"InvalidCoordinate"
                        format:@"coordinate components >= 1: %@", s];
        r.v[i] = vals[i];
    }
    return r;
}

static void ApplyBreak(PhextCoord *c, int d) {
    c->v[d] += 1;
    for (int k = d + 1; k < 9; k++) c->v[k] = 1;
}

@implementation PhextScroll
+ (instancetype)scrollWithCoord:(PhextCoord)c text:(NSData *)t {
    PhextScroll *s = [[self alloc] init];
    s.coord = c;
    s.text = t;
    return s;
}
@end

@implementation Phext

+ (NSArray<PhextScroll *> *)phokenize:(NSData *)buf {
    NSMutableArray *out = [NSMutableArray array];
    const unsigned char *bytes = buf.bytes;
    NSUInteger len = buf.length;
    PhextCoord coord = PhextCoordRoot();
    NSUInteger runStart = 0;
    for (NSUInteger i = 0; i < len; i++) {
        int d = BreakDim(bytes[i]);
        if (d >= 0) {
            if (i > runStart) {
                NSData *text = [NSData dataWithBytes:bytes + runStart
                                              length:i - runStart];
                [out addObject:[PhextScroll scrollWithCoord:coord
                                                       text:text]];
            }
            ApplyBreak(&coord, d);
            runStart = i + 1;
        }
    }
    if (len >= runStart && len > 0) {
        NSData *text = [NSData dataWithBytes:bytes + runStart
                                      length:len - runStart];
        if (text.length > 0)
            [out addObject:[PhextScroll scrollWithCoord:coord text:text]];
    } else if (len == runStart && len > 0) {
        // trailing run handled above
    }
    if (len > 0 && runStart < len) {
        // unreachable; kept for clarity
    }
    if (len > 0 && runStart == len) {
        // buffer ended with a break: no trailing scroll
    }
    // Edge: buffer nonempty and last run already appended when
    // runStart < len; when the loop ended without a final break the
    // block above appended it. When len>0 and runStart==0 handled too.
    return out;
}

+ (NSData *)advanceFrom:(PhextCoord *)loc to:(PhextCoord)target {
    NSMutableData *out = [NSMutableData data];
    if (PhextCoordCmp(*loc, target) >= 0) return out;
    int dim = 0;
    while (loc->v[dim] == target.v[dim]) dim++;
    for (long long j = 0; j < target.v[dim] - loc->v[dim]; j++)
        [out appendBytes:&DimBreaks[dim] length:1];
    loc->v[dim] = target.v[dim];
    for (int lower = dim + 1; lower < 9; lower++) loc->v[lower] = 1;
    for (int lower = dim + 1; lower < 9; lower++) {
        for (long long j = 0; j < target.v[lower] - 1; j++)
            [out appendBytes:&DimBreaks[lower] length:1];
        loc->v[lower] = target.v[lower];
    }
    return out;
}

+ (NSData *)dephokenize:(NSArray<PhextScroll *> *)stack {
    NSArray *sorted = [stack sortedArrayUsingComparator:
        ^NSComparisonResult(PhextScroll *a, PhextScroll *b) {
            int c = PhextCoordCmp(a.coord, b.coord);
            return c < 0 ? NSOrderedAscending
                         : (c > 0 ? NSOrderedDescending : NSOrderedSame);
        }];
    NSMutableData *out = [NSMutableData data];
    PhextCoord loc = PhextCoordRoot();
    for (PhextScroll *ps in sorted) {
        if (ps.text.length == 0) continue;
        [out appendData:[self advanceFrom:&loc to:ps.coord]];
        [out appendData:ps.text];
    }
    return out;
}

+ (NSData *)normalize:(NSData *)buf {
    return [self dephokenize:[self phokenize:buf]];
}

+ (NSData *)fetch:(NSData *)buf at:(PhextCoord)c {
    for (PhextScroll *ps in [self phokenize:buf])
        if (PhextCoordEq(ps.coord, c)) return ps.text;
    return [NSData data];
}

+ (NSData *)update:(NSData *)buf at:(PhextCoord)c text:(NSData *)t
         overwrite:(BOOL)overwrite {
    NSMutableArray *result = [NSMutableArray array];
    PhextScroll *next = [PhextScroll scrollWithCoord:c text:t];
    BOOL appended = NO;
    for (PhextScroll *ps in [self phokenize:buf]) {
        if (PhextCoordCmp(ps.coord, c) > 0 && !appended) {
            [result addObject:next];
            appended = YES;
        }
        if (PhextCoordEq(ps.coord, c) && !appended) {
            if (!overwrite) {
                NSMutableData *merged = [ps.text mutableCopy];
                [merged appendData:t];
                next.text = merged;
            }
            [result addObject:next];
            appended = YES;
            continue;
        }
        [result addObject:ps];
    }
    if (!appended) [result addObject:next];
    return [self dephokenize:result];
}

+ (NSData *)insert:(NSData *)buf at:(PhextCoord)c text:(NSData *)t {
    return [self update:buf at:c text:t overwrite:NO];
}

+ (NSData *)replace:(NSData *)buf at:(PhextCoord)c text:(NSData *)t {
    return [self update:buf at:c text:t overwrite:YES];
}

+ (NSData *)remove:(NSData *)buf at:(PhextCoord)c {
    return [self normalize:[self update:buf at:c text:[NSData data]
                             overwrite:YES]];
}

+ (NSDictionary<NSString *, NSData *> *)explode:(NSData *)buf {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (PhextScroll *ps in [self phokenize:buf])
        m[PhextCoordStr(ps.coord)] = ps.text;
    return m;
}

+ (NSData *)implode:(NSDictionary<NSString *, NSData *> *)map {
    NSMutableArray *stack = [NSMutableArray array];
    for (NSString *k in map)
        [stack addObject:[PhextScroll scrollWithCoord:PhextCoordParse(k)
                                                  text:map[k]]];
    return [self dephokenize:stack];
}

@end

#pragma mark - DynamicPhext

@interface DynamicPhext () {
    NSMutableArray<PhextScroll *> *_items;
    NSUInteger _cap;
    NSUInteger _resizeCount;
    NSUInteger _elementsCopied;
}
@end

@implementation DynamicPhext

- (instancetype)initWithBuffer:(NSData *)buf {
    self = [super init];
    _items = [NSMutableArray array];
    _cap = 1;
    _resizeCount = 0;
    _elementsCopied = 0;
    for (PhextScroll *ps in [Phext phokenize:buf])
        [self putAt:ps.coord text:ps.text merge:NO];
    return self;
}

- (NSUInteger)count { return _items.count; }
- (NSUInteger)capacity { return _cap; }
- (NSUInteger)resizeCount { return _resizeCount; }
- (NSUInteger)elementsCopied { return _elementsCopied; }

- (void)resizeTo:(NSUInteger)newCap {
    _cap = newCap;
    _resizeCount++;
    _elementsCopied += _items.count;
}

- (void)growIfFull {
    if (_items.count == _cap) [self resizeTo:_cap * 2];
}

- (void)shrinkIfSparse {
    if (_cap > 1 && _items.count <= _cap / 4)
        [self resizeTo:MAX((NSUInteger)1, _cap / 2)];
}

- (NSInteger)find:(PhextCoord)c found:(BOOL *)found {
    NSInteger lo = 0, hi = (NSInteger)_items.count - 1;
    *found = NO;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        int cmp = PhextCoordCmp(_items[mid].coord, c);
        if (cmp == 0) {
            *found = YES;
            return mid;
        }
        if (cmp < 0) lo = mid + 1; else hi = mid - 1;
    }
    return lo;
}

- (void)putAt:(PhextCoord)c text:(NSData *)t merge:(BOOL)merge {
    BOOL found;
    NSInteger idx = [self find:c found:&found];
    if (found) {
        if (merge) {
            NSMutableData *m = [_items[idx].text mutableCopy];
            [m appendData:t];
            _items[idx].text = m;
        } else {
            _items[idx].text = t;
        }
        return;
    }
    [self growIfFull];
    [_items insertObject:[PhextScroll scrollWithCoord:c text:t]
                 atIndex:(NSUInteger)idx];
}

- (NSData *)fetchAt:(PhextCoord)c {
    BOOL found;
    NSInteger idx = [self find:c found:&found];
    return found ? _items[idx].text : [NSData data];
}

- (void)insertAt:(PhextCoord)c text:(NSData *)t {
    if (t.length == 0) return;
    [self putAt:c text:t merge:YES];
}

- (void)replaceAt:(PhextCoord)c text:(NSData *)t {
    if (t.length == 0) {
        [self removeAt:c];
        return;
    }
    [self putAt:c text:t merge:NO];
}

- (void)removeAt:(PhextCoord)c {
    BOOL found;
    NSInteger idx = [self find:c found:&found];
    if (!found) return;
    [_items removeObjectAtIndex:(NSUInteger)idx];
    [self shrinkIfSparse];
}

- (NSData *)serialize {
    return [Phext dephokenize:_items];
}

@end

#pragma mark - TransitivePhext

@implementation TransNode
- (instancetype)init {
    self = [super init];
    _kids = [NSMutableDictionary dictionary];
    return self;
}
@end

@interface TransitivePhext () {
    TransNode *_root;
    NSUInteger _count;
}
@end

@implementation TransitivePhext

- (instancetype)initWithBuffer:(NSData *)buf {
    self = [super init];
    _root = [[TransNode alloc] init];
    _count = 0;
    for (PhextScroll *ps in [Phext phokenize:buf])
        [self replaceAt:ps.coord text:ps.text];
    return self;
}

- (NSUInteger)count { return _count; }

- (TransNode *)walk:(PhextCoord)c create:(BOOL)create {
    TransNode *cur = _root;
    for (int d = 0; d < 9; d++) {
        NSNumber *k = @(c.v[d]);
        TransNode *kid = cur.kids[k];
        if (!kid) {
            if (!create) return nil;
            kid = [[TransNode alloc] init];
            kid.key = c.v[d];
            cur.kids[k] = kid;
        }
        cur = kid;
    }
    return cur;
}

- (NSData *)fetchAt:(PhextCoord)c {
    TransNode *n = [self walk:c create:NO];
    return (n && n.isLeaf) ? n.leaf : [NSData data];
}

- (void)insertAt:(PhextCoord)c text:(NSData *)t {
    if (t.length == 0) return;
    TransNode *n = [self walk:c create:YES];
    if (n.isLeaf) {
        NSMutableData *m = [n.leaf mutableCopy];
        [m appendData:t];
        n.leaf = m;
    } else {
        n.isLeaf = YES;
        n.leaf = t;
        _count++;
    }
}

- (void)replaceAt:(PhextCoord)c text:(NSData *)t {
    if (t.length == 0) {
        [self removeAt:c];
        return;
    }
    TransNode *n = [self walk:c create:YES];
    if (!n.isLeaf) _count++;
    n.isLeaf = YES;
    n.leaf = t;
}

- (void)removeAt:(PhextCoord)c {
    TransNode *n = [self walk:c create:NO];
    if (n && n.isLeaf) {
        n.isLeaf = NO;
        n.leaf = [NSData data];
        _count--;
    }
}

- (void)collect:(TransNode *)node depth:(int)depth
         prefix:(PhextCoord *)prefix into:(NSMutableArray *)out {
    if (depth == 9) {
        if (node.isLeaf)
            [out addObject:[PhextScroll scrollWithCoord:*prefix
                                                   text:node.leaf]];
        return;
    }
    NSArray *keys = [node.kids.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *k in keys) {
        prefix->v[depth] = k.longLongValue;
        [self collect:node.kids[k] depth:depth + 1 prefix:prefix
                 into:out];
    }
}

- (NSData *)serialize {
    NSMutableArray *out = [NSMutableArray array];
    PhextCoord prefix = PhextCoordRoot();
    [self collect:_root depth:0 prefix:&prefix into:out];
    return [Phext dephokenize:out];
}

@end
