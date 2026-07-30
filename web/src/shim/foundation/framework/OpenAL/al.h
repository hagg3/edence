// <OpenAL/al.h> — trampoline to Emscripten's OpenAL. Apple puts OpenAL under <OpenAL/…>;
// everyone else (including emsdk, which ships a real Web-Audio-backed implementation at
// system/include/AL/) uses <AL/…>. Same trick as framework/OpenGLES/ES1/gl.h.
//
// This is a REAL implementation, not a stub — web-port-plan.md Stage P5's "first attempt is a
// link-and-see: point CocosDenshion at Emscripten OpenAL". This header is what makes that
// attempt possible; whether the engine's usage is actually covered is P5's question.
#ifndef EDEN_SHIM_OPENAL_AL_H
#define EDEN_SHIM_OPENAL_AL_H
#include <AL/al.h>
#endif
