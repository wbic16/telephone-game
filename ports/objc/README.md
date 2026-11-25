# libphext-objc

Objective-C port of libphext, 0.6.1 parity, for the Exocortical
Telephone Game (contract v2). Semantics normative from libphext-py:
`src/Phext.m` implements the buffer API over NSData plus DynamicPhext
(dynamic array, double on full / shrink at quarter-full) and
TransitivePhext (9-level branching map). REMOVE is
coordinate-preserving. `src/Wire.m` provides native SHA-256 and the
canonical JSON serializer; `src/cli.m` is the hub-side CLI wrapping
only this port's libphext, PGP via subprocess gpg (GNUPGHOME
~/telephone-objc/keys). Toolchain: GNUstep user-level source build on
aletheia-core, no sudo.
