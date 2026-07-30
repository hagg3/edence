// platform_shims.h — small platform primitives the engine gets from iOS's libc/Foundation but
// that Emscripten's sysroot does not provide. Included from the <Foundation/Foundation.h>
// trampoline, because that is how engine files receive these on device (via the prefix header)
// and this port does not edit engine sources.
//
// Two things live here, both named explicitly by web-port-plan.md's Stage P1 list of seams
// ("Replace arc4random→arc4random-equivalent, CFAbsoluteTime→…"):
//
//   * arc4random  — BSD libc on Darwin, absent from Emscripten's libc entirely (checked: it
//                   appears nowhere in the sysroot except libc++ internals). 17 call sites,
//                   all gameplay randomness (BlockBreak particle scatter, creature AI).
//   * MAX / MIN   — Foundation's <NSObjCRuntime.h> macros, used by BlockBreak.mm and Model.mm.
//
// (CFAbsoluteTimeGetCurrent, the third Stage P1 seam, is in framework/CoreFoundation/ instead,
// since it is a genuine CF function rather than a libc gap.)
#ifndef EDEN_SHIM_PLATFORM_SHIMS_H
#define EDEN_SHIM_PLATFORM_SHIMS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Same contract as BSD's: a uniformly distributed uint32_t, no seeding required, never fails.
// The implementation is NOT cryptographic (see platform_shims.cpp) — every call site in this
// engine is gameplay dice, and nothing here guards a secret.
uint32_t arc4random(void);
uint32_t arc4random_uniform(uint32_t upper_bound);

#ifdef __cplusplus
}
#endif

// Foundation's definitions, guarded the same way Apple's are — several third-party files under
// Classes/ define these themselves before use.
#ifndef MAX
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef ABS
#define ABS(a) (((a) < 0) ? (-(a)) : (a))
#endif

#endif
