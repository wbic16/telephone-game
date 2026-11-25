// libphext-objc -- Objective-C (GNUstep Foundation) port of libphext,
// 0.6.1 parity. Semantics normative from libphext-py: a phext is a
// byte buffer (NSData); nine dimension-break bytes walk a 9-component
// coordinate; scroll text is a maximal run of non-break bytes
// (newline 0x0A is ordinary text). REMOVE is coordinate-preserving:
// the removed coordinate reads "", neighbours do not shift.
#import <Foundation/Foundation.h>

typedef struct {
    long long v[9];
} PhextCoord;

PhextCoord PhextCoordMake(long long a, long long b, long long c,
                          long long d, long long e, long long f,
                          long long g, long long h, long long i);
PhextCoord PhextCoordRoot(void);
BOOL PhextCoordEq(PhextCoord a, PhextCoord b);
int PhextCoordCmp(PhextCoord a, PhextCoord b); // -1, 0, 1 lexicographic
NSString *PhextCoordStr(PhextCoord c);
PhextCoord PhextCoordParse(NSString *s); // raises on invalid

@interface PhextScroll : NSObject
@property(nonatomic) PhextCoord coord;
@property(nonatomic, strong) NSData *text;
+ (instancetype)scrollWithCoord:(PhextCoord)c text:(NSData *)t;
@end

@interface Phext : NSObject
+ (NSArray<PhextScroll *> *)phokenize:(NSData *)buf;
+ (NSData *)dephokenize:(NSArray<PhextScroll *> *)stack;
+ (NSData *)normalize:(NSData *)buf;
+ (NSData *)fetch:(NSData *)buf at:(PhextCoord)c;
+ (NSData *)update:(NSData *)buf at:(PhextCoord)c text:(NSData *)t
         overwrite:(BOOL)overwrite;
+ (NSData *)insert:(NSData *)buf at:(PhextCoord)c text:(NSData *)t;
+ (NSData *)replace:(NSData *)buf at:(PhextCoord)c text:(NSData *)t;
+ (NSData *)remove:(NSData *)buf at:(PhextCoord)c;
+ (NSDictionary<NSString *, NSData *> *)explode:(NSData *)buf;
+ (NSData *)implode:(NSDictionary<NSString *, NSData *> *)map;
@end

// DynamicPhext: capacity-managed dynamic array (double on full,
// shrink at quarter-full), kept in coordinate order.
@interface DynamicPhext : NSObject
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) NSUInteger capacity;
@property(nonatomic, readonly) NSUInteger resizeCount;
@property(nonatomic, readonly) NSUInteger elementsCopied;
- (instancetype)initWithBuffer:(NSData *)buf;
- (NSData *)fetchAt:(PhextCoord)c;
- (void)insertAt:(PhextCoord)c text:(NSData *)t;
- (void)replaceAt:(PhextCoord)c text:(NSData *)t;
- (void)removeAt:(PhextCoord)c;
- (NSData *)serialize;
@end

// TransitivePhext: 9-level branching map -- a tree of nodes, one
// level per dimension, each node mapping a component value to a
// child node.
@interface TransNode : NSObject
@property(nonatomic) long long key;
@property(nonatomic) BOOL isLeaf;
@property(nonatomic, strong) NSData *leaf;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, TransNode *> *kids;
@end

@interface TransitivePhext : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (instancetype)initWithBuffer:(NSData *)buf;
- (NSData *)fetchAt:(PhextCoord)c;
- (void)insertAt:(PhextCoord)c text:(NSData *)t;
- (void)replaceAt:(PhextCoord)c text:(NSData *)t;
- (void)removeAt:(PhextCoord)c;
- (NSData *)serialize;
@end
