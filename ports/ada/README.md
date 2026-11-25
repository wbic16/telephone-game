# libphext-ada

Ada port of libphext, 0.6.1 parity, for the Exocortical Telephone Game
(contract v2). Semantics normative from libphext-py: `src/phext.adb`
implements the buffer API plus DynamicPhext (dynamic array, double on
full / shrink at quarter-full) and TransitivePhext (9-level branching
map). REMOVE is coordinate-preserving. `src/wire.adb` provides native
SHA-256, Base64, a JSON parser and the canonical JSON serializer;
`src/cli.adb` is the hub-side CLI wrapping only this port's libphext,
with PGP via subprocess gpg (GNUPGHOME ~/telephone-ada/keys).
Toolchain: GNAT 14.2.1 via Alire (alr toolchain --select
gnat_native), user-level on aletheia-core, no sudo; tool symlinks in
~/telephone-ada/env/bin.
