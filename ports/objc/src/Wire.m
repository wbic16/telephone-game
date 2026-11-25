#import "Wire.h"
#include <stdint.h>
#include <string.h>

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
    0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
    0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
    0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

NSString *WireSha256Hex(NSData *data) {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    const unsigned char *msg = data.bytes;
    size_t len = data.length;
    size_t padded = ((len + 9 + 63) / 64) * 64;
    unsigned char *buf = calloc(padded, 1);
    memcpy(buf, msg, len);
    buf[len] = 0x80;
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++)
        buf[padded - 1 - i] = (unsigned char)(bits >> (i * 8));
    for (size_t off = 0; off < padded; off += 64) {
        uint32_t w[64];
        for (int t = 0; t < 16; t++)
            w[t] = ((uint32_t)buf[off + t * 4] << 24) |
                   ((uint32_t)buf[off + t * 4 + 1] << 16) |
                   ((uint32_t)buf[off + t * 4 + 2] << 8) |
                   (uint32_t)buf[off + t * 4 + 3];
        for (int t = 16; t < 64; t++) {
            uint32_t s0 = ROTR(w[t - 15], 7) ^ ROTR(w[t - 15], 18) ^
                          (w[t - 15] >> 3);
            uint32_t s1 = ROTR(w[t - 2], 17) ^ ROTR(w[t - 2], 19) ^
                          (w[t - 2] >> 10);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4],
                 f = h[5], g = h[6], hh = h[7];
        for (int t = 0; t < 64; t++) {
            uint32_t S1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + K256[t] + w[t];
            uint32_t S0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            hh = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    free(buf);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < 8; i++) [out appendFormat:@"%08x", h[i]];
    return out;
}

NSData *WireTextToBytes(NSString *s) {
    NSMutableData *out = [NSMutableData data];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n;) {
        uint32_t cp = [s characterAtIndex:i];
        NSUInteger adv = 1;
        if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n) {
            uint32_t lo = [s characterAtIndex:i + 1];
            if (lo >= 0xDC00 && lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                adv = 2;
            }
        }
        if (cp < 256) {
            unsigned char b = (unsigned char)cp;
            [out appendBytes:&b length:1];
        } else {
            NSData *utf8 = [[NSString stringWithFormat:@"%C", (unichar)0]
                dataUsingEncoding:NSUTF8StringEncoding];
            (void)utf8;
            // Encode the codepoint as UTF-8 manually.
            unsigned char tmp[4];
            int tl;
            if (cp < 0x800) {
                tmp[0] = 0xC0 | (cp >> 6);
                tmp[1] = 0x80 | (cp & 0x3F);
                tl = 2;
            } else if (cp < 0x10000) {
                tmp[0] = 0xE0 | (cp >> 12);
                tmp[1] = 0x80 | ((cp >> 6) & 0x3F);
                tmp[2] = 0x80 | (cp & 0x3F);
                tl = 3;
            } else {
                tmp[0] = 0xF0 | (cp >> 18);
                tmp[1] = 0x80 | ((cp >> 12) & 0x3F);
                tmp[2] = 0x80 | ((cp >> 6) & 0x3F);
                tmp[3] = 0x80 | (cp & 0x3F);
                tl = 4;
            }
            [out appendBytes:tmp length:tl];
        }
        i += adv;
    }
    return out;
}

NSString *WireBytesToText(NSData *data) {
    NSMutableString *out = [NSMutableString string];
    const unsigned char *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++)
        [out appendFormat:@"%C", (unichar)b[i]];
    return out;
}

static NSString *CanonStr(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n;) {
        uint32_t cp = [s characterAtIndex:i];
        NSUInteger adv = 1;
        if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < n) {
            uint32_t lo = [s characterAtIndex:i + 1];
            if (lo >= 0xDC00 && lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                adv = 2;
            }
        }
        switch (cp) {
            case 0x22: [out appendString:@"\\\""]; break;
            case 0x5C: [out appendString:@"\\\\"]; break;
            case 0x0A: [out appendString:@"\\n"]; break;
            case 0x0D: [out appendString:@"\\r"]; break;
            case 0x09: [out appendString:@"\\t"]; break;
            case 0x08: [out appendString:@"\\b"]; break;
            case 0x0C: [out appendString:@"\\f"]; break;
            default:
                if (cp >= 0x20 && cp < 0x7F) {
                    [out appendFormat:@"%C", (unichar)cp];
                } else if (cp <= 0xFFFF) {
                    [out appendFormat:@"\\u%04x", cp];
                } else {
                    uint32_t x = cp - 0x10000;
                    [out appendFormat:@"\\u%04x\\u%04x",
                         0xD800 + (x >> 10), 0xDC00 + (x & 0x3FF)];
                }
        }
        i += adv;
    }
    [out appendString:@"\""];
    return out;
}

NSString *WireCanon(id v) {
    if (v == nil || v == [NSNull null]) return @"null";
    if ([v isKindOfClass:[NSString class]]) return CanonStr(v);
    if ([v isKindOfClass:[NSNumber class]]) {
        if (strcmp([v objCType], @encode(BOOL)) == 0 ||
            strcmp([v objCType], "c") == 0 && ([v isEqual:@YES] ||
                                               [v isEqual:@NO])) {
            // NSNumber booleans from NSJSONSerialization have a
            // distinct type encoding on GNUstep ("c" may collide);
            // callers pass booleans only via JSON parse, where
            // GNUstep yields NSNumber with bool type. Fall through to
            // the double check below for safety.
        }
        double d = [v doubleValue];
        if (d == (double)[v longLongValue])
            return [NSString stringWithFormat:@"%lld",
                             [v longLongValue]];
        return [NSString stringWithFormat:@"%g", d];
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableString *out = [NSMutableString stringWithString:@"["];
        BOOL first = YES;
        for (id item in (NSArray *)v) {
            if (!first) [out appendString:@","];
            first = NO;
            [out appendString:WireCanon(item)];
        }
        [out appendString:@"]"];
        return out;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = v;
        NSArray *keys = [d.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
        NSMutableString *out = [NSMutableString stringWithString:@"{"];
        BOOL first = YES;
        for (NSString *k in keys) {
            if (!first) [out appendString:@","];
            first = NO;
            [out appendString:CanonStr(k)];
            [out appendString:@":"];
            [out appendString:WireCanon(d[k])];
        }
        [out appendString:@"}"];
        return out;
    }
    return @"null";
}
