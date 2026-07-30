// Trampoline for `#import <Foundation/Foundation.h>` (angle-bracket — safe to redirect via
// include-path ordering; see gl_es1_shim's framework/OpenGLES/ES1/gl.h for why quoted
// "X.h" includes CANNOT be redirected this way, only angle-bracket ones). This directory
// (web/src/shim/foundation/framework/) is added to the include path BEFORE any system
// dirs in CMakeLists.txt, so this is the only `<Foundation/Foundation.h>` the build ever sees.
//
// Pulls in every D3a shim class (see foundation-usage.md for the full inventory + what's
// real vs. stubbed).
#ifndef EDEN_TRAMPOLINE_FOUNDATION_H
#define EDEN_TRAMPOLINE_FOUNDATION_H

// The real <Foundation/Foundation.h> transitively drags in the C standard library, and engine
// files rely on that: Classes/hashmap.mm and Classes/Frustum.mm call malloc/calloc/free having
// included nothing but the prefix header. Reproduce that here rather than editing those files
// (this port does not touch engine sources). Found by the third real build — these two files
// were the ONLY remaining non-GL compile failures at that point.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Platform primitives Emscripten's libc lacks but iOS provides (arc4random, MAX/MIN) —
// see ../../platform_shims.h. Engine files receive these via the prefix header on device, so
// they must arrive the same way here.
#include "../../platform_shims.h"

#include "../../NSObject.h"
#include "../../NSAutoreleasePool.h"
#include "../../NSString.h"
#include "../../NSData.h"
#include "../../NSNumber.h"
#include "../../NSArray.h"
#include "../../NSDate.h"
#include "../../NSFileHandle.h"
#include "../../NSFileManager.h"
#include "../../NSThread.h"
#include "../../NSBundle.h"
#include "../../NSUserDefaults.h"
#include "../../NSURLConnection.h"
#include "../../NSErrorException.h"
#include "../../NSTimer.h"
#include "../../NSOperation.h"
#include "../../NSLogSupport.h"

#endif
