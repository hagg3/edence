# The Hand-Written ObjC Runtime Shim

Not in the root docs at all — Emscripten ships no Objective-C runtime, so this port
carries its own. Split out from [third-party.md](third-party.md) because it's dense
and referenced from several other docs (execution-flow, conventions-and-pitfalls).

## ABI choice
`-fobjc-runtime=gnustep-2.0` fails to compile for wasm — it needs ELF/COFF section
features the wasm object format doesn't have. Measured (not guessed) that
`gnustep-1.9`, `gnustep-1.8`, `gcc`, and `objfw` all compile; **gnustep-1.9** was
picked as the newest of the working set. Paired flags:
`-fconstant-string-class=NSConstantString -fno-objc-arc` (manual retain/release,
matching the root engine's own pre-ARC style).

`src/shim/objc/objc_abi.h` + `objc_runtime.cpp` implement this ABI from scratch.

## Dispatch model
**Slot-based**, not IMP-based: `objc_msg_lookup_sender`/`objc_slot_lookup_super`
return a `struct objc_slot*`, looked up per send via an `unordered_map<uint64,
slot*>` — there is no inline cache. This is a real, measured perf cost (e.g.
`Hud.mm` alone issues 275 message sends), accepted rather than optimized away.

## The ivar-layout sentinel fix (pass 7)
Under `-x objective-c++`, a class whose **entire ancestor chain has zero own
ivars** gets a `-1` sentinel first-ivar offset and a `+1`-biased `instance_size`
from the compiler. The runtime detects this sentinel and applies "+1 to own-size
and every offset" to compensate. **Not handled**: a class with own ivars sitting
after a superclass that *also* has own ivars — re-measure if you hit that shape;
don't assume the existing fix generalizes.

Reproduce any ivar-layout measurement yourself rather than trusting memory:
```
em++ -x objective-c++ -fobjc-runtime=gnustep-1.9 -fno-objc-arc -S -emit-llvm -o - FILE.mm | grep ...
```
(see `PORT-STATUS.md` for the exact grep pattern used historically). This is the
concrete instance of [conventions-and-pitfalls.md](conventions-and-pitfalls.md)'s
"measure, don't reason" rule — the ivar bug was mis-diagnosed at least once before
being measured directly.

## Constant strings and NSObject cluster
- `NSObject` — zero ivars; retain counts live in a side table, not inline.
- `NSString` — zero-ivar abstract base.
- `NSConstantString` — three words: `{isa, const char*, unsigned length}`, backing
  the 743 `@"..."` literals in the engine.
- `EdenConcreteString` — `std::string`-backed concrete subclass for runtime-built
  strings.

## `RuntimeError: function signature mismatch`
Under this ABI, this almost always means **a message was sent to a class with no
`@implementation`** (a missing `@implementation` still links fine — it just
dispatches into nothing) — check that first before suspecting a bad function
prototype. See [conventions-and-pitfalls.md](conventions-and-pitfalls.md).
