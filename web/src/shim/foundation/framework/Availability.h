// Trampoline for `<Availability.h>`, unconditionally #imported at the top of the PARENT
// tree's ../../../../Eden_Prefix.pch (untouched — we force-include that file as-is for
// engine sources, see CMakeLists.txt, rather than duplicate its NSLog-macro/diagnostic-pragma
// logic here). Apple's real Availability.h only defines SDK version-check macros
// (__IPHONE_3_0 etc.) that the pch's own `#ifndef __IPHONE_3_0` / #warning guard against —
// leaving it undefined here just means that harmless warning fires once per translation unit,
// exactly as it would on a very old SDK. No content needed beyond "the file exists".
//
// UPDATE (this pass): "no content needed" turned out to be wrong for one macro.
// Classes/CDAudioManager.h branches on `#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 30000` and takes
// the pre-3.0 path when it is undefined (undefined identifiers evaluate to 0 in #if), asking for
// "CDXMacOSXSupport.h" — a file that is NOT in this tree, because the shipped app never compiled
// that branch. Defining these reproduces the shipped build's own configuration (Eden-Info.plist
// targets iOS 3.0+); it is not a porting choice so much as restoring a fact the SDK supplied.
#ifndef EDEN_TRAMPOLINE_AVAILABILITY_H
#define EDEN_TRAMPOLINE_AVAILABILITY_H

#define __IPHONE_2_0     20000
#define __IPHONE_3_0     30000
#define __IPHONE_4_0     40000

#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
#define __IPHONE_OS_VERSION_MIN_REQUIRED __IPHONE_3_0
#endif
#ifndef __IPHONE_OS_VERSION_MAX_ALLOWED
#define __IPHONE_OS_VERSION_MAX_ALLOWED __IPHONE_4_0
#endif

#endif
