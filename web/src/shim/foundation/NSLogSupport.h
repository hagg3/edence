// NSLogSupport.h — D3a shim for the real `NSLog` C function (233 call sites — the highest-
// traffic single Foundation symbol in the engine, see foundation-usage.md). NOTE: the actual
// NSLog(...) *macro* the engine's call sites expand through is defined in the UNMODIFIED
// ../../../Eden_Prefix.pch (force-included for engine sources via CMakeLists.txt's
// `-include`, not duplicated here):
//     #ifndef __OPTIMIZE__
//     #    define NSLog(...) NSLog(__VA_ARGS__)   // expands to a call to THIS function
//     #else
//     #    define NSLog(...) {}                   // compiled away entirely in Release
//     #endif
// `__OPTIMIZE__` is auto-defined by clang at -O1 and above, so this "just works" the same way
// it did on device: Debug builds (-O0, see CMakeLists.txt) log; Release (-O2) compiles NSLog
// out with zero overhead, matching the original iOS build's behavior exactly.
#ifndef EDEN_SHIM_NSLOGSUPPORT_H
#define EDEN_SHIM_NSLOGSUPPORT_H

@class NSString;

#ifdef __cplusplus
extern "C" {
#endif
void NSLog(NSString *format, ...);
#ifdef __cplusplus
}
#endif

#endif
