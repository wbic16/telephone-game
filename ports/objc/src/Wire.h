// Wire helpers for libphext-objc's hub CLI: native SHA-256
// (FIPS 180-4; Foundation has no public SHA-256 on GNUstep),
// Base64 via NSData, canonical JSON (sorted keys, "," / ":"
// separators, ensure_ascii escaping) matching the telephone game's
// pinned formats, and the latin-1 text<->bytes convention.
#import <Foundation/Foundation.h>

NSString *WireSha256Hex(NSData *data);
NSData *WireTextToBytes(NSString *s);
NSString *WireBytesToText(NSData *data);
NSString *WireCanon(id value);
