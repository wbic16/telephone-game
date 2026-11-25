# libphext-delphi

Object Pascal (Free Pascal) port of libphext, 0.6.1 parity, for the
Exocortical Telephone Game (contract v2). Semantics are normative from
libphext-py: `src/phext.pas` implements the buffer API
(phokenize/dephokenize/normalize/fetch/insert/replace/remove) plus
DynamicPhext (dynamic-array store, double-on-full / shrink-at-quarter)
and TransitivePhext (9-level branching hash map). REMOVE is
coordinate-preserving: the removed coordinate reads "", neighbours do
not shift.

`src/cli.pas` is the hub-side CLI (JSON wire, state as base64) wrapping
only this port's libphext; PGP identity via subprocess gpg with
GNUPGHOME ~/telephone-delphi/keys on the hub. `adapter` is the local
fleet-ssh wrapper (fortran-port pattern). Toolchain: Free Pascal 3.2.2
from the Ubuntu package pool (.deb files extracted user-level under
~/telephone-delphi/root on aletheia-core, no sudo; driver wrapper at
~/telephone-delphi/fpc). SHA-256 is a native unit in src/sha256.pas
(Debian's FPC units do not ship fcl-hash's sha256).
