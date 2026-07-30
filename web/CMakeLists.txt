# web/CMakeLists.txt — Eden: World Builder web port build.
#
# Reads tools/engine-sources.txt (the AUTHORITATIVE 81-file list the Eden.xcodeproj Sources
# phase compiles, per CLAUDE.md: "only files in Eden.xcodeproj are built") and compiles all of
# them EXCEPT the platform seam (excluded below, each with its rationale), plus this port's own
# seam replacements / Foundation+GL shims / entry point.
#
# STATUS (see docs/PORT-STATUS.md for the full log, and web/docs/RESUME-HERE.md for current pass):
# this is long since resolved and playable, not a status to re-derive. emsdk 3.1.74 is installed
# (pass 4, gitignored at web/emsdk/) via `emcmake cmake -B build-st && cmake --build build-st`
# (the actually-runnable single-thread target — see EDEN_THREADED below and RESUME-HERE.md's
# "Running it"). Emscripten ships no Objective-C runtime, so this port hand-writes one against
# the GNU gnustep-1.9 ABI (src/shim/objc/) — settled since pass ~6, see PORT-STATUS.md's
# "Distilled hard-won knowledge" for the ABI measurements, not the objc/runtime.h TODO this
# comment used to point at. See web/cmake/README.md for the exact toolchain invocation + hosting
# requirements.
#
# Per WORKING/web-port-plan.md Phase 0 "Toolchain baseline": CMake (not Xcode-project-file
# reuse), reading the exact Eden.xcodeproj file list, -O2/-O3 + -sALLOW_MEMORY_GROWTH +
# source maps for debug.

cmake_minimum_required(VERSION 3.20)
project(EdenWeb LANGUAGES C CXX)

set(EDEN_PARENT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(EDEN_CLASSES_DIR "${EDEN_PARENT_DIR}/Classes")

# ---------------------------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------------------------

# D1 (web-port-plan.md): run the engine in a Web Worker with real pthreads + OffscreenCanvas +
# WASMFS/OPFS sync-access, gated behind COOP/COEP headers (see web/cmake/README.md). The
# single-threaded fallback (default) is the plan's documented escape hatch if OffscreenCanvas/
# COOP-COEP prove unworkable on a target browser: single-threaded build on the main thread, OPFS
# via WASMFS's async access, load runs synchronously with a progress yield. Kept as a build flag
# (not a source fork) specifically so this stays cheap to flip — per the plan: "Keep the code
# thread-agnostic so this stays a build flag, not a rewrite."
#
# Audit row A1 (project-audit-2026-07-30.md): this option defaulted ON despite there being no
# working host page for it — worker-bootstrap.js is a 38-line sketch, index.html is scaffolding,
# and the OffscreenCanvas handshake in eden_main.cpp is still TODO D1. Every build anyone actually
# runs (build-st, build-rel) passes -DEDEN_THREADED=OFF explicitly; a fresh clone running the
# obvious `cmake ..`/`emcmake cmake -B build` got a target that links but cannot be played. The ON
# path is real, in-development work (audit row C1, Opus 5 xhigh, 3-6 weeks) — it is not what a
# first-time builder should get by omitting a flag they don't know exists yet. Default is now OFF;
# pass -DEDEN_THREADED=ON explicitly to build the in-development threaded target.
option(EDEN_THREADED "Build with pthreads + OffscreenCanvas + PROXY_TO_PTHREAD (D1, IN DEVELOPMENT — no working host page yet, see audit row C1). Default OFF = single-thread build, the only one with a runnable host page today." OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Perf audit item Q7/C8: the scripted-drive test harness (eden_debug_tick, DebugState_web.mm's
# eden_debug_menu_state()/eden_debug_player_state()/etc., the [eden-p1]/[eden-gl-dbg] fprintf
# probes, and the per-draw glGetError() call gl_es1_shim.cpp does for the first 5 frames) is
# load-bearing for headless `node eden.js` regression checks (see docs/RESUME-HERE.md "Running
# it") but has no business shipping in a build meant to be played — glGetError() is a pipeline
# stall and the prints are pure noise. Default it to whatever CMAKE_BUILD_TYPE was BEFORE this
# point (Debug for build-st, Release for build-rel unless overridden), so both existing build
# trees keep their current behavior with no cache change required; override explicitly with
# -DEDEN_DIAGNOSTICS=ON/OFF for anything else (e.g. a diagnostics-enabled Release build).
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(EDEN_DIAGNOSTICS_DEFAULT ON)
else()
  set(EDEN_DIAGNOSTICS_DEFAULT OFF)
endif()
option(EDEN_DIAGNOSTICS "Compile the scripted-drive debug probes (eden_debug_tick, DebugState_web.mm, [eden-p1]/[eden-gl-dbg] prints, per-draw glGetError). Default ON for Debug, OFF otherwise." ${EDEN_DIAGNOSTICS_DEFAULT})

# ---------------------------------------------------------------------------------------------
# Authoritative engine source list
# ---------------------------------------------------------------------------------------------
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/tools/engine-sources.txt" EDEN_ENGINE_SOURCES_REL)

# --- Platform seam: files to EXCLUDE from the 81 and replace with src/seam/ / src/entry/
# equivalents instead (per web-port-plan.md principle #2 and docs/PORT-STATUS.md's seam
# classification). Each exclusion is commented with WHY, not just what.
set(EDEN_SEAM_EXCLUDE
  # --- Surface + loop + touches: replaced by src/seam/EAGLView_web.mm,
  # EdenViewController_web.{h,cpp}, EdenAppDelegate_web.{h,cpp}, src/entry/eden_main.cpp.
  # No CAEAGLLayer/UIApplicationMain/CADisplayLink equivalent exists on web; Stage P2/D1 owns
  # the real canvas/worker loop instead.
  "Classes/EAGLView.mm"
  "Classes/EdenViewController.mm"
  "Classes/EdenAppDelegate.mm"
  "main.m"

  # --- Raster: Texture2D.mm decodes images via UIImage/CoreGraphics and rasterizes strings via
  # UIFont — no web equivalent exists. REPLACED (pass 11) by src/seam/Texture2D_web.mm, following
  # the SAME "reuse the original .h, replace only the .mm" pattern documented in
  # src/seam/EAGLView_web.mm's header comment (Texture2D.h is included by 8+ other engine headers
  # per a grep done in pass 2 — kept as-is, only Texture2D.mm is excluded here). The replacement
  # decodes PNGs via stb_image instead of UIImage/CGBitmapContext (see Texture2D_web.mm's header
  # comment for what was ported verbatim vs. deliberately deferred to P2b).
  "Classes/Texture2D.mm"

  # --- File I/O: NSFileHandle/NSFileManager-based append-only .eden format I/O (per
  # docs/eden-file-format.md, docs/save-load.md). STAGE P4 (pass 22): FileManager.mm and
  # FileManagerHelper.mm are NO LONGER EXCLUDED — the REAL engine files are compiled as-is,
  # because the Foundation file-I/O surface they use (NSFileHandle/NSFileManager/NSBundle/
  # NSData/NSSearchPathForDirectoriesInDomains) is already fully shimmed over stdio+OPFS
  # (src/shim/foundation/), so reusing the original tested RLE-column / directory / creature
  # logic is far lower-risk than reimplementing it. Their save path writes to /documents (WASMFS,
  # OPFS-backed in the threaded build); default-world terrain streams from the bundled Eden.eden
  # (preloaded to /bundle/Eden.eden below, resolved via NSBundle). The only link cost was a few
  # CoreGraphics symbols in the DEAD-in-this-build loadGenFromDisk() (JUST_TERRAIN_GEN only) —
  # stubbed in src/shim/foundation/uikit_stubs.{h,mm}. FileArchive.mm stays excluded: both files
  # reference it only in commented-out compress/decompress code (grep-verified), so no link dep.
  "Classes/FileArchive.mm"

  # --- Audio: CocosDenshion/OpenAL façade. TODO P5: SimpleAudioEngine_web.mm over Emscripten's
  # OpenAL-over-WebAudio (first attempt) or a small hand-written Web Audio shim if gaps appear.
  # NOT YET REPLACED this pass.
  "Classes/SimpleAudioEngine.mm"

  # --- Networking: NSURLConnection-based world sharing (docs/networking.md). TODO P6: fetch/
  # XMLHttpRequest-based replacements; audit finding H4 (shared-list parser bounds check) lands
  # here per the plan. NOT YET REPLACED this pass — feature-flagged off is an acceptable P6
  # outcome per the plan ("Feature-flag Shared Worlds off if the endpoint can't be reached").
  "Classes/FileDownload.mm"
  "Classes/FileUpload.mm"
  "Classes/SharedList.mm"
  "Classes/ShareUtil.mm"
  "Classes/ShareMenu.mm"
  "Classes/Alert.mm"

  # --- Strip entirely (CLAUDE.md L12 / plan Stage P7): rating-prompt nag + analytics remnants.
  # No web replacement — the one caller (Classes/EdenAppDelegate.mm) is itself excluded above,
  # and grep confirms no other file references Appirater (see foundation-usage.md).
  "Classes/Appirater.mm"

  # --- Crypto/CF file hashing: md5.c is 100 lines of Apple plumbing (CFReadStreamCreateWithFile,
  # CFURLCreateWithFileSystemPath, CFStringCreateWithCString) wrapped around CommonCrypto's
  # CC_MD5_*. Replaced by src/shim/foundation/md5_web.mm, which re-expresses the SAME function
  # (Classes/md5.h is untouched and still declares it) over stdio plus a real RFC-1321 MD5 —
  # shimming CFReadStream for one call site would have been the larger change. See that file's
  # header comment for why the digest has to be genuine rather than stubbed.
  "Classes/md5.c"

  # --- JUDGMENT CALL made THIS pass (see docs/PORT-STATUS.md "Decisions" for the rationale in
  # full): VKeyboard.mm was listed in the original seam classification as "verify during P1",
  # not excluded. A grep this pass found it calls a real UIView method
  # (`[G_EAGL_VIEW insertSubview:atIndex:]`, Classes/VKeyboard.mm:85) to overlay a native
  # UITextField for world-renaming text entry — there is no such native-overlay concept on web
  # without a real DOM, so it's reclassified here as excluded/seam-replaced. TODO P3: a real
  # HTML <input> positioned over the canvas (postMessage'd from src/entry, see
  # public/worker-bootstrap.js sketch) is the natural web equivalent, matching the ORIGINAL's
  # own "real native text field over the GL view" approach in spirit. NOT YET REPLACED this
  # pass — no VKeyboard_web stub exists yet (out of this pass's scope, tracked as a P3 TODO).
  "Classes/VKeyboard.mm"
)
# statusbar.mm and Gamepad.mm were ALSO checked this pass (grepped for UIView/addSubview/
# insertSubview/UITextField coupling) and found clean — real GL-drawn UI + input polling only,
# no native-overlay dependency. They stay classified as ordinary ENGINE files (compiled as-is,
# not excluded) per the original "verify during P1" note; verification = done, result = keep.

set(EDEN_ENGINE_SOURCES "")
foreach(rel IN LISTS EDEN_ENGINE_SOURCES_REL)
  if(rel MATCHES "^MISSING:")
    message(FATAL_ERROR "engine-sources.txt has an unresolved entry: ${rel} — regenerate with tools/gen-source-list.sh")
  endif()
  if(NOT rel IN_LIST EDEN_SEAM_EXCLUDE)
    list(APPEND EDEN_ENGINE_SOURCES "${EDEN_PARENT_DIR}/${rel}")
  endif()
endforeach()

list(LENGTH EDEN_ENGINE_SOURCES_REL EDEN_TOTAL_COUNT)
list(LENGTH EDEN_ENGINE_SOURCES EDEN_KEPT_COUNT)
message(STATUS "Eden web: ${EDEN_KEPT_COUNT} of ${EDEN_TOTAL_COUNT} engine sources kept (rest are seam-excluded, see EDEN_SEAM_EXCLUDE above)")

# ---------------------------------------------------------------------------------------------
# This port's own sources
# ---------------------------------------------------------------------------------------------
set(EDEN_SHIM_FOUNDATION_SOURCES
  src/shim/foundation/NSObject.mm
  src/shim/foundation/NSAutoreleasePool.mm
  src/shim/foundation/NSString.mm
  src/shim/foundation/NSData.mm
  src/shim/foundation/NSNumber.mm
  src/shim/foundation/NSArray.mm
  src/shim/foundation/NSDate.mm
  src/shim/foundation/NSFileHandle.mm
  src/shim/foundation/NSFileManager.mm
  src/shim/foundation/NSThread.mm
  src/shim/foundation/NSBundle.mm
  src/shim/foundation/NSUserDefaults.mm
  src/shim/foundation/NSErrorException.mm
  src/shim/foundation/NSTimer.mm
  src/shim/foundation/NSOperation.mm
  src/shim/foundation/NSLogSupport.mm
  src/shim/foundation/uikit_stubs.mm
  src/shim/foundation/CoreFoundation.mm
  src/shim/foundation/md5_web.mm
  # NSURLConnection.h has no .mm — P6, header-only stub this pass (see foundation-usage.md).
)

# The Objective-C runtime itself (web-port-plan.md blocker #1, option (c)). Emscripten ships no
# libobjc, so without this NOTHING that clang emits for a .mm file links: class registration
# (__objc_exec_class) and message dispatch (objc_msg_lookup_sender/objc_slot_lookup_super) are
# both undefined otherwise. Plain C++ on purpose — it implements the ABI rather than using it, so
# it must NOT be added to EDEN_MM_SOURCES below. Read src/shim/objc/objc_abi.h before touching it:
# every struct layout there was measured off real emcc codegen, not recalled.
set(EDEN_SHIM_OBJC_SOURCES
  src/shim/objc/objc_runtime.cpp
)

# Stage P5 placeholder: failing AudioToolbox stubs so the P1 headless link can happen without a
# CAF/WAV decoder. See the file's header comment for why FAILING (not no-op-success) is the safe
# choice here.
set(EDEN_SHIM_AUDIO_SOURCES
  src/shim/audio/audiotoolbox_stub.cpp
)

# Plain-C++ platform primitives (arc4random) — not .mm, see src/shim/foundation/platform_shims.h.
set(EDEN_SHIM_PLATFORM_SOURCES
  src/shim/foundation/platform_shims.cpp
)

set(EDEN_SHIM_GL_SOURCES
  src/shim/gl/gl_es1_shim.cpp
)

set(EDEN_SEAM_SOURCES
  src/seam/EAGLView_web.mm
  src/seam/EdenViewController_web.cpp
  src/seam/EdenAppDelegate_web.cpp
  src/seam/main_web.cpp
  src/seam/seam_link_stubs.mm
  src/seam/Texture2D_web.mm
  src/seam/Input_web.mm
  src/seam/pvrt_matrix_palette.cpp  # --wrap: installs the shim's GL_OES_matrix_palette entry points. See file header.
  src/seam/Movement_web.mm  # PC controls audit F1/F2 --wrap of Player::setSpeed (frame-rate-normalized walk speed). See file header.
  src/seam/Settings_web.mm  # settings model + --wrap of the old GL settings panel and gluPerspective. See file header.
  src/seam/Storage_web.mm  # local-storage panel data source (world list/size/mtime, delete). See file header.
  src/seam/Menu_web.mm  # C accessors the DOM main menu (public/eden-menu.js) drives Menu.mm through. NOT a replacement — see file header.
  src/seam/LoadFailure_web.mm  # C4: corrupt/truncated-save signal for FileManager.mm's loadWorld() + .bak restore. See file header.
  src/seam/SimpleAudioEngine_web.mm  # P5 audio (Web Audio + streaming music). See file header.
  # P4 landed by un-excluding the REAL FileManager.mm/FileManagerHelper.mm (see EDEN_SEAM_EXCLUDE
  # above) rather than writing FileManager_web.mm — no seam replacement needed here.
  # TODO P5/P6: SimpleAudioEngine_web.mm,
  # FileDownload_web.mm/FileUpload_web.mm/SharedList_web.mm/ShareUtil_web.mm/ShareMenu_web.mm/
  # Alert_web.mm, VKeyboard_web.mm — add each here as its stage lands (see EDEN_SEAM_EXCLUDE
  # comments above for what each replaces).
)

# Q7/C8: DebugState_web.mm (eden_debug_menu_state/player_state/hud_rects/alloc_state/…) is only
# ever called manually from a scripted `node`/console drive (grep-verified: nothing in public/*.js
# or eden-st.html references any eden_debug_* export), so it is safe to leave out of the binary
# entirely rather than just gating its prints.
if(EDEN_DIAGNOSTICS)
  list(APPEND EDEN_SEAM_SOURCES src/seam/DebugState_web.mm)
  # Audit row F5 — the dev console (teleport/spawn/world-stats) is deliberately gated the same
  # way: a shipped build should not let a player teleport or spawn creatures at will.
  list(APPEND EDEN_SEAM_SOURCES src/seam/DevConsole_web.mm)
endif()

# ---- case-mismatched #import shims -----------------------------------------------------------
# macOS's default filesystem is case-INsensitive, so Classes/*.mm quoting the wrong case for a
# sibling header (e.g. Camera.h: `#import "Glu.h"` when the real file is `glu.h`) has always
# silently resolved on the Xcode/simulator build. Linux (every CI runner) is case-sensitive and
# fails with "file not found" — grep-verified this is every such mismatch in Classes/ today.
# Never edit Classes/*.h to fix the quoted name (see the no-Classes-edits rule above); instead
# create the missing case-variant as a relative symlink, same trick as the audio/Eden.eden
# symlinks below. Harmless no-op on macOS (the target already resolved); required on Linux.
foreach(pair IN ITEMS "Glu.h=glu.h" "input.h=Input.h" "terrain.h=Terrain.h" "Vkeyboard.h=VKeyboard.h" "GLobals.h=Globals.h")
  string(REPLACE "=" ";" pair "${pair}")
  list(GET pair 0 wrong_case)
  list(GET pair 1 real_file)
  if(NOT EXISTS "${EDEN_CLASSES_DIR}/${wrong_case}")
    file(CREATE_LINK "${real_file}" "${EDEN_CLASSES_DIR}/${wrong_case}" SYMBOLIC)
  endif()
endforeach()

# ---- P5 audio assets -------------------------------------------------------------------------
# ~45 MB of .caf/.mp3/.wav under ../media. Deliberately NOT --preload-file'd: that would bake all
# of it into eden.data, more than doubling the initial download, and none of it is needed before
# the first sound plays. It is served over HTTP and fetched on demand instead (see
# src/seam/SimpleAudioEngine_web.mm). Two pieces of glue are generated here:
#   * public/audio -> ../media symlink, so the dev server can reach the assets from the page's
#     own origin (python3 -m http.server follows symlinks).
#   * public/audio-manifest.json, mapping the BARE filenames the engine passes ("explosion.caf",
#     "Eden_title.mp3") to their media/ subdirectory. The iOS app bundle is flat, so the engine
#     never had to name a directory; on the web the media/ tree keeps its structure.
file(CREATE_LINK "${EDEN_PARENT_DIR}/media" "${CMAKE_CURRENT_SOURCE_DIR}/public/audio" SYMBOLIC)

# ---- lazy Eden.eden fetch (pass 30) ---------------------------------------------------------
# The pre-generated default world (~52 MB, repo-root Eden.eden) used to be --preload-file'd into
# eden.data, meaning first paint was gated on downloading it even though it is only ever read
# lazily by the engine itself (fmh_readColumnFromDefault streams individual 32 KB column records
# on demand as the player walks into ungenerated terrain — see docs/world-and-terrain.md). Instead
# symlink it into public/ (same trick as the audio symlink above) so it's reachable over HTTP from
# the page's own origin, and populate it into /bundle/Eden.eden via a --pre-js Module.preRun run
# dependency (src/seam/js/eden_default_world.pre.js) that does a fetch() in the browser or
# fs.readFileSync under `node eden.js`. NOT `FS.createLazyFile` — that throws outside a Web Worker
# on this emsdk version ("Cannot do synchronous binary XHRs outside webworkers in modern
# browsers"), so this is "fetched separately, concurrently with the small asset package," not a
# true byte-range-lazy read; see the .pre.js file's own header and perf-audit item §5b.1 for why
# a real range-fetch needs either the threaded build or a custom FS node. This paragraph itself
# used to describe the abandoned FS.createLazyFile approach — corrected per perf-audit Q9.
file(CREATE_LINK "${EDEN_PARENT_DIR}/Eden.eden" "${CMAKE_CURRENT_SOURCE_DIR}/public/Eden.eden" SYMBOLIC)
file(GLOB_RECURSE EDEN_AUDIO_FILES
     RELATIVE "${EDEN_PARENT_DIR}/media"
     "${EDEN_PARENT_DIR}/media/*.caf" "${EDEN_PARENT_DIR}/media/*.mp3"
     "${EDEN_PARENT_DIR}/media/*.wav")
list(SORT EDEN_AUDIO_FILES)  # deterministic winner when a basename appears in two directories
set(EDEN_AUDIO_MANIFEST "{")
set(EDEN_AUDIO_SEEN "")
foreach(rel IN LISTS EDEN_AUDIO_FILES)
  get_filename_component(base "${rel}" NAME)
  if(NOT base IN_LIST EDEN_AUDIO_SEEN)
    list(APPEND EDEN_AUDIO_SEEN "${base}")
    string(APPEND EDEN_AUDIO_MANIFEST "\"${base}\":\"${rel}\",")
  endif()
endforeach()
string(REGEX REPLACE ",$" "" EDEN_AUDIO_MANIFEST "${EDEN_AUDIO_MANIFEST}")
string(APPEND EDEN_AUDIO_MANIFEST "}")
file(WRITE "${CMAKE_CURRENT_SOURCE_DIR}/public/audio-manifest.json" "${EDEN_AUDIO_MANIFEST}")
list(LENGTH EDEN_AUDIO_SEEN EDEN_AUDIO_COUNT)
message(STATUS "eden: audio manifest lists ${EDEN_AUDIO_COUNT} sound files")

set(EDEN_ENTRY_SOURCES
  src/entry/eden_main.cpp
)

set(EDEN_ALL_SOURCES
  ${EDEN_ENGINE_SOURCES}
  ${EDEN_SHIM_FOUNDATION_SOURCES}
  ${EDEN_SHIM_OBJC_SOURCES}
  ${EDEN_SHIM_AUDIO_SOURCES}
  ${EDEN_SHIM_PLATFORM_SOURCES}
  ${EDEN_SHIM_GL_SOURCES}
  ${EDEN_SEAM_SOURCES}
  ${EDEN_ENTRY_SOURCES}
)

add_executable(eden ${EDEN_ALL_SOURCES})

# ST-build-only synchronous pthread_create shim (src/seam/pthread_sync_web.c). The engine's sole
# thread is the world-load thread (Classes/World.mm, pthread_create → loadWorldThread, which sets
# doneLoading=2). In the non-pthread build Emscripten's stub pthread_create never runs the routine,
# so loadWorld() hangs forever at doneLoading==1 — the "clicking to load a world freezes" bug. This
# override runs the routine synchronously. It MUST NOT link into the threaded build (it would
# collide with real pthreads) and MUST stay plain C — NOT in EDEN_MM_SOURCES, so it never gets the
# -x objective-c++ / prefix-header treatment applied to .mm sources below.
if(NOT EDEN_THREADED)
  target_sources(eden PRIVATE src/seam/pthread_sync_web.c)
endif()

# ---------------------------------------------------------------------------------------------
# Include paths
# ---------------------------------------------------------------------------------------------
# ORDER MATTERS for the two framework/ dirs: they provide fake `<Foundation/Foundation.h>`,
# `<UIKit/UIKit.h>`, `<OpenGLES/ES1/gl.h>`, `<OpenGLES/ES1/glext.h>`, `<OpenGLES/EAGL.h>`, and
# `<Availability.h>` — angle-bracket includes only (see gl_es1_shim.h's framework/OpenGLES/
# ES1/gl.h for why quoted "X.h" includes can't be redirected this way; that's why the seam .mm
# files reach into ../../../Classes/*.h with explicit relative paths instead of relying on -I).
target_include_directories(eden PRIVATE
  src/shim/foundation/framework
  src/shim/gl/framework
  src/shim/foundation
  src/shim/gl
  src/shim/vendor            # stb_image.h/stb_truetype.h — P2 Texture2D_web.mm's PNG decoder.
  "${EDEN_CLASSES_DIR}"      # lets Classes/*.mm's quoted #import "X.h" resolve sibling headers
                              # (same-directory lookup already covers most of this; explicit
                              # for clarity and as a safety net)
  "${EDEN_PARENT_DIR}"        # a few Classes/*.mm files quote-include ROOT-level headers, e.g.
                              # Classes/Terrain.mm: `#import "Lighting.h"` where Lighting.h
                              # lives at the repo root, not in Classes/ — grep-verified this pass.
)

# ---------------------------------------------------------------------------------------------
# Objective-C++ compilation (D3a) — .mm files only
# ---------------------------------------------------------------------------------------------
# CMake does not auto-detect .mm as a language without enabling OBJCXX, which has spotty
# support in custom (non-Apple-Clang) toolchain files like Emscripten's — so every .mm source is
# forced to compile as CXX and the ObjC-specific flags are layered on as COMPILE_OPTIONS.
#
# *** BUT `LANGUAGE CXX` ALONE IS NOT ENOUGH — it does NOT enable the Objective-C frontend. ***
# (An earlier revision of this comment claimed "clang dispatches on content, not the CMake
# LANGUAGE property". That is wrong, and it cost ~900 of the 992 errors in the fourth real
# build.) Driven as `em++ file.mm`, clang compiles the file as plain C++: `__OBJC__` is never
# defined and every `@interface` in the Foundation shim fails to parse with "expected external
# declaration". It also silently breaks the ENGINE, because the unmodified ../Eden_Prefix.pch
# wraps its Foundation/UIKit imports in `#ifdef __OBJC__` — so .mm files were getting no
# Foundation at all (that's why Classes/hashmap.mm reported malloc/calloc/NULL undeclared).
# `-x objective-c++` is what actually selects the frontend; it must come BEFORE the source file,
# which COMPILE_OPTIONS guarantees.
set(EDEN_MM_SOURCES ${EDEN_SHIM_FOUNDATION_SOURCES} ${EDEN_SEAM_SOURCES})
foreach(src IN LISTS EDEN_ENGINE_SOURCES)
  if(src MATCHES "\\.mm$")
    list(APPEND EDEN_MM_SOURCES ${src})
  endif()
endforeach()
set_source_files_properties(${EDEN_MM_SOURCES} PROPERTIES LANGUAGE CXX)

# D3(a): "target clang's GNU objc runtime (-fobjc-runtime=gnustep-2.0 ...) and provide a small
# hand-written Foundation shim". `-fno-objc-arc`: CLAUDE.md convention #6 — this engine is
# manual retain/release throughout, predates ARC; do not enable it.
#
# `-fconstant-string-class=NSConstantString`: the engine uses `@"literal"` syntax 743 times
# across non-seam Classes/*.mm, and clang lowers each to a STATICALLY EMITTED instance of the
# class named here, with an ivar layout it hard-codes as `{Class isa; const char *cString;
# unsigned length;}`. src/shim/foundation/NSString.h implements exactly that class as part of a
# GNUstep-style class cluster (zero-ivar NSObject + zero-ivar abstract NSString + this class +
# a concrete std::string-backed EdenConcreteString), which is what makes the layout safe.
# Read NSString.h's header comment and web-port-plan.md's "D3 refinement" section before
# changing ANY of these three flags — they are a matched set, not independent knobs.
#
# STILL UNPROVEN until a real link runs (P0.1): (1) whether the gnustep-2.0 v2 ABI expects a
# wider/flagged layout than the classic three-word one assumed above, and (2) whether this
# target honors -fconstant-string-class at all or hard-requires the name `NXConstantString`
# (if the latter: rename the class in NSString.h/.mm and alias NSConstantString to it).
# *** P0.1 SPIKE RESULT (2026-07-19, first real emcc run) — gnustep-2.0 DOES NOT WORK. ***
# `-fobjc-runtime=gnustep-2.0` fails at compile time with "GNUstep Objective-C runtime version 2
# incompatible with target binary format" (46 occurrences, the single dominant error in the first
# build). The v2 ABI requires ELF/COFF section features wasm doesn't provide. Measured
# alternatives, all compiled against a one-class test .mm under emcc 3.1.74:
#     gnustep-2.0  FAILS (binary format)   gnustep-1.9  COMPILES  <-- chosen
#     gnustep-1.8  COMPILES                gcc          COMPILES
#     objfw        COMPILES
# gnustep-1.9 is the newest ABI that works, so it's the least-regression choice.
#
# ALSO CONFIRMED BY THAT SPIKE: `-fconstant-string-class=NSConstantString` IS honored under
# gnustep-1.9, and the three-word `{isa, const char *, unsigned}` layout NSString.h implements
# compiles clean against a real `@"..."` literal. That closes open question (2) from NSString.h's
# header comment — the cluster design is compile-validated, not just reasoned.
set(EDEN_OBJCXX_FLAGS
  -x objective-c++          # selects the ObjC frontend — see the LANGUAGE CXX note above
  -fobjc-runtime=gnustep-1.9
  -fno-objc-arc
  -fconstant-string-class=NSConstantString
)
set_source_files_properties(${EDEN_MM_SOURCES} PROPERTIES COMPILE_OPTIONS "${EDEN_OBJCXX_FLAGS}")

# ---------------------------------------------------------------------------------------------
# Preprocessor definitions carried over from the Xcode target
# ---------------------------------------------------------------------------------------------
# *** THESE ARE NOT THIS PORT'S INVENTION — they are settings the shipped build already had, and
# missing them silently changes which code the vendored PVRT SDK compiles. *** Found by grepping
# Eden.xcodeproj/project.pbxproj, which sets:
#     GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS = ( TARGET_OS_IPHONE, BUILD_OGLES, );
#
#  * BUILD_OGLES gates `#include "PVRTFixedPointAPI.h"` in Classes/PVRTFixedPoint.h, which is the
#    ONLY path by which Classes/PVRTContext.h — and therefore PVRTglesExt.h, and therefore the
#    class CPVRTglesExt — reaches Classes/Model.mm. Without it, Model.mm fails with "unknown type
#    name 'CPVRTglesExt'" and the include chain gives no hint why (the chain is
#    Model.mm → PVRTModelPOD.h → PVRTVector.h → PVRTFixedPoint.h → [gated] → PVRTFixedPointAPI.h
#    → PVRTContext.h → PVRTglesExt.h).
#  * TARGET_OS_IPHONE selects the iOS branch in several PVRT headers and in Classes/Sound.m's
#    AudioFileOpenURL call. It is normally defined by Apple's <TargetConditionals.h>; on this
#    target nothing defines it, so the project's own explicit definition is what has to be
#    reproduced. Note this does NOT make __APPLE__ true — the PVRT headers test
#    `#if defined(__APPLE__)` FIRST and fall to their generic-GLES branch here, which is why
#    framework/GLES/glext.h and EGL_NOT_PRESENT below exist.
#
# EGL_NOT_PRESENT is this port's own addition rather than Xcode's, and it is the honest value:
# there is no EGL on the web. It makes PVRTContext.h skip `#include <GLES/egl.h>` and makes
# PVRTglesExt.h define `PVRGetProcAddress(x)` as NULL, so every GL-extension function pointer is
# null — correct, since WebGL has none of the OES extensions PVRT looks for. See
# src/shim/gl/framework/OpenGLES/ES1/glext.h for the one consequence worth carrying forward
# (GL_OES_matrix_palette is absent, so creature models do not load until skinning is ported).
target_compile_definitions(eden PRIVATE
  TARGET_OS_IPHONE
  BUILD_OGLES
  EGL_NOT_PRESENT
  $<$<BOOL:${EDEN_DIAGNOSTICS}>:EDEN_DIAGNOSTICS=1>
)

# Pass 4 found ~90 -Wc++11-narrowing errors in unmodified engine constant tables (e.g. values
# like 4294967196 — small negatives stored as unsigned — narrowed into smaller integer types).
# Legal in the original C++98-era Xcode build; this port does not edit engine sources, so silence
# the warning-as-error instead. Applied target-wide rather than per-file; the project declares
# only C/CXX (line 19 above — .mm files are forced to LANGUAGE CXX at line ~225, there is no
# separate OBJCXX language here), and this port's own shim/seam/entry code shouldn't be writing
# narrowing initializers in the first place, so the broad C++ scope is harmless.
target_compile_options(eden PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:-Wno-c++11-narrowing>
  # Same class of problem, same resolution: Classes/TerrainGenerator.mm's Perlin noise code uses
  # `register int i, j;`, legal C++98 and REMOVED in C++17, which is the standard emcc defaults
  # to. Downgrading the whole build to -std=c++98 to accommodate one keyword would change
  # overload resolution and library behavior across 60+ engine files; suppressing the diagnostic
  # changes nothing but the diagnostic (`register` has been a no-op hint to compilers for
  # decades). Per CLAUDE.md this port does not edit engine sources to satisfy the toolchain.
  $<$<COMPILE_LANGUAGE:CXX>:-Wno-register>
)

# Force-include the UNMODIFIED parent-tree prefix header for ENGINE sources only (not this
# port's own shim/seam/entry files, which manage their own includes explicitly) — reproduces
# Xcode's GCC_PRECOMPILE_PREFIX_HEADER behavior exactly, including the NSLog/printg macros'
# __OPTIMIZE__-gated behavior (see src/shim/foundation/NSLogSupport.h) and the `#import
# <Availability.h>` this needs a trampoline for (src/shim/foundation/framework/Availability.h).
# Per CLAUDE.md, ../Eden_Prefix.pch is read here, never edited.
set(EDEN_ENGINE_MM_SOURCES "")
foreach(src IN LISTS EDEN_ENGINE_SOURCES)
  if(src MATCHES "\\.mm$" OR src MATCHES "\\.m$")
    list(APPEND EDEN_ENGINE_MM_SOURCES ${src})
  endif()
endforeach()
set_source_files_properties(${EDEN_ENGINE_MM_SOURCES} PROPERTIES
  COMPILE_OPTIONS "${EDEN_OBJCXX_FLAGS};-include;${EDEN_PARENT_DIR}/Eden_Prefix.pch"
)

# ---------------------------------------------------------------------------------------------
# Emscripten flags
# ---------------------------------------------------------------------------------------------
if(EMSCRIPTEN)
  target_compile_options(eden PRIVATE
    # Q1 (dazzling-munching-bengio.md perf audit, C1): the build actually served to players was
    # `build-st/`, configured Debug (`-O0 -g -gsource-map`) — every engine hot loop (mesher
    # rebuild2(), Terrain::update, the ObjC dispatch cache, the shim's per-draw mat4_multiply) ran
    # UNOPTIMISED, and no Release build had ever been configured, built, or measured. `-fno-strict-
    # aliasing` per the audit's own risk note: this is 2010-era C/C++ (type punning in the on-disk
    # struct paths, `-Wno-c++11-narrowing` tables, the mesher's counting/fill passes) that has been
    # getting away with UB since -O0 never exploited it. Landing `-O2` (not `-O3`) first is the
    # audit's explicitly recommended lower-risk step — bump to -O3/-Oz only after a real A/B
    # (`node eden.js` P1 tick + a live-Chrome playtest) confirms no regression.
    #
    # Project audit 2026-07-30, row B1 — -flto (both compile- and link-side; the pair must match,
    # see EDEN_LINK_FLAGS below). Pass 53 tried this, hit a hard `Aborted()` partway through menu
    # asset load under `node eden.js`, and reverted it with the root cause unchased. Pass 56 found
    # it, and it was NOT an LTO bug: `NSUserDefaults`' `std::unordered_map` ivar was never
    # constructed, because the hand-written ObjC runtime's class_createInstance() is a bare
    # `calloc` with no `.cxx_construct` support. A zeroed unordered_map has max_load_factor 0.0,
    # so the first insert asks for `ceil(1 / 0.0)` buckets; LTO's cross-TU inlining is simply what
    # let the compiler constant-fold that and commit to libc++'s throw path (= abort, exceptions
    # being off) where plain -O2 had been limping. Latent UB in every build, LTO or not — fixed at
    # source in src/shim/foundation/NSUserDefaults.mm (which carries the full write-up, plus the
    # same-shaped leak found in NSAutoreleasePool.mm). With that fixed, all four headless suites
    # pass against an LTO build. If a future flag ever "breaks" this port again, that file is the
    # precedent: suspect our own latent UB before suspecting the optimiser.
    $<$<CONFIG:Release>:-O2;-fno-strict-aliasing;-flto>
    $<$<CONFIG:Debug>:-O0;-g;-gsource-map>
    # zlib is a PORT, not a shim: Classes/FileArchive/the RLE Eden.eden path include <zlib.h>, and
    # emsdk ships zlib itself, so this is the one "missing header" in the pass-4 list that needed
    # a flag rather than a trampoline. It has to appear on the COMPILE side too (not just link)
    # for the header to be found at all.
    -sUSE_ZLIB=1
  )
  set(EDEN_LINK_FLAGS
    -Wl,--error-limit=0
    -sALLOW_MEMORY_GROWTH=1
    # The engine's STATIC data alone is ~62 MB, so the default 16 MB initial heap cannot even be
    # linked ("initial memory too small, 64928208 bytes needed"). ALLOW_MEMORY_GROWTH does not
    # help — that grows the heap at runtime, whereas this is the size the module starts at, which
    # must already cover static data + stack.
    #
    # WHY SO LARGE, and why this is expected rather than alarming: docs/world-and-terrain.md's
    # resident window is an 18x18-chunk column array, 288x288x64 blocks at 2 bytes each = ~10.6 MB
    # for `blockarray` alone, plus the parallel lighting/colour arrays and the mesher's
    # per-face-direction vertex buckets — all statically allocated C globals (CLAUDE.md: "hot data
    # are C globals"). This is a 2010 iPhone-era fixed budget, not a leak.
    #
    # 96 MB leaves headroom above the measured 62 MB for the malloc heap without being so large
    # that the initial download/instantiate suffers. Revisit once a world actually loads (P4).
    -sINITIAL_MEMORY=100663296
    # P4: the wasm STACK is separate from INITIAL_MEMORY and defaults to only 64 KB. Terrain::render
    # declares `vertexObject objVertices[300*6*6]` (10800 * 36 B ≈ 380 KB) as a plain LOCAL, plus the
    # mesher's own large frames — the iOS build had a multi-MB thread stack, so these never mattered.
    # On the default 64 KB wasm stack the first in-world Terrain::render() frame overflows and traps
    # as "memory access out of bounds" (measured: OOB in Terrain::render right after game_mode->1).
    # 8 MB matches the iOS main-thread stack budget with headroom for the deepest engine frame.
    -sSTACK_SIZE=8388608
    # Creature skinning (pass 27). GL_OES_matrix_palette does not exist in WebGL, so the shim
    # emulates it (src/shim/gl/gl_es1_shim.cpp GROUP 8) and advertises it in glGetString — but the
    # four extension ENTRY POINTS still resolve to NULL inside Classes/PVRTglesExt.cpp, whose
    # PVRGetProcAddress macro is a literal NULL on any non-__APPLE__ target. This wrap is where
    # they get filled in; see src/seam/pvrt_matrix_palette.cpp for why nothing else can.
    # (It REPLACES the old `--wrap=_Z12RenderModelsv` no-op guard, which existed only because
    # RenderModels() null-dereferenced PODs that LoadModels() had refused to load. With the
    # extension emulated they load, so RenderModels() runs for real again.)
    "SHELL:-Wl,--wrap=_ZN12CPVRTglesExt14LoadExtensionsEv"
    # PC controls audit F1/F2 (see /Users/sam/.claude/plans/please-run-an-audit-lovely-dongarra.md
    # and src/seam/Movement_web.mm's header). Player::setSpeed(Vector,float) is called from two
    # separate TUs (Input_web.mm's keyboard path, Classes/Joystick.mm's real touch joystick), so
    # --wrap sees it from both. Mangled name confirmed via
    # `llvm-nm build-st/CMakeFiles/eden.dir/.../Classes/Player.mm.o | grep setSpeed`, not guessed.
    "SHELL:-Wl,--wrap=_ZN6Player8setSpeedE6Vectorf"
    # PC controls audit Phase 6 (opt-in "advanced movement" — zero-delay bhop). Player::preupdate
    # is called from Classes/World.mm:499 (cross-TU), so --wrap sees every engine tick exactly
    # once. See src/seam/Movement_web.mm's header. Mangled name confirmed via llvm-nm, not guessed.
    "SHELL:-Wl,--wrap=_ZN6Player9preupdateEf"
    # Settings (pass 28). The old GL settings panel is neutralised rather than seam-replaced:
    # SettingsMenu::{load,save,getNewWorldName} and properties[] are kept and driven by the DOM
    # panel, while update()/render() (both called from Classes/Menu.mm, a different TU) become
    # no-ops. gluPerspective is wrapped to make the hard-coded 80-degree FOV in
    # Classes/Graphics.mm:370 a setting. See src/seam/Settings_web.mm.
    "SHELL:-Wl,--wrap=_ZN12SettingsMenu6updateEf"
    "SHELL:-Wl,--wrap=_ZN12SettingsMenu6renderEv"
    "SHELL:-Wl,--wrap=gluPerspective"
    # World-save persistence (pass 29). /documents is plain MEMFS otherwise — session-scoped, gone
    # on reload, the #1 gap per docs/PORT-STATUS.md. Links Emscripten's IDBFS backend; the actual
    # mount (with {autoPersist:true}, so any write/unlink/rename under /documents queues an async
    # IndexedDB sync with no engine-side hook needed — see library_idbfs.js) plus the initial
    # populate-before-main() happens JS-side in public/eden-storage.js via Module.preRun, because
    # that populate is inherently async and main() must not run (and Menu::loadWorlds must not list
    # Documents) until it has finished. Safe to link into both build flavours: node's headless
    # `eden.js` has no indexedDB, so eden-storage.js's mount is guarded and no-ops there (falls
    # back to the previous in-memory-only behaviour, same as NSUserDefaults' localStorage guard).
    -lidbfs.js
    # Lazy Eden.eden fetch (pass 30) — populates /bundle/Eden.eden via fetch()/node fs before
    # main() runs, instead of --preload-file'ing the ~52MB default world into eden.data. See the
    # file's own header for why this can't be a true deferred-until-first-use fetch. Compiled in
    # (not a public/*.js <script>) so it also runs under headless `node eden.js`.
    "SHELL:--pre-js ${CMAKE_CURRENT_SOURCE_DIR}/src/seam/js/eden_default_world.pre.js"
    -sWASM=1
    -sUSE_ZLIB=1
    # P2: the shim creates a WebGL2 context (src/shim/gl/gl_es1_shim.cpp GROUP 2c). Without
    # this, emscripten_webgl_create_context caps at majorVersion 1 and the create() call fails
    # at run time rather than at link time — a browser-only failure the node build cannot catch.
    -sMAX_WEBGL_VERSION=2
    -sMIN_WEBGL_VERSION=2
    # P2 (Texture2D_web.mm): preload the UI/HUD/block-atlas art into the virtual FS at
    # /bundle/media, preserving subdirectories (--preload-file does NOT flatten) — NSBundle.mm
    # flattens on lookup instead by indexing every basename once (see its header comment).
    # Deliberately excludes media/{models,music,new_sound,sound,screens} (~47 MB): audio is P5's
    # (HTTP-fetched, see the audio-manifest step above), screens/ is unused marketing art, and
    # models/ is preloaded FLAT to /bundle further down (the bundle layout the engine expects).
    # Revisit the excluded set as stages land — this is asset-packaging config, not a
    # source-of-truth list; nothing else in the port depends on exactly these 6 subdirs.
    #
    # Each is wrapped in "SHELL:" — WITHOUT it, CMake's target_link_options deduplicates
    # byte-identical list ELEMENTS across the whole option list, and every one of these entries
    # starts with the same literal token "--preload-file". That collapsed all but the first
    # occurrence (discovered via a real build: emcc reported the 2nd+ src@dst path as a stray
    # "input file", because its own --preload-file flag had been silently removed). SHELL:
    # marks the flag+value pair as one atomic, non-splittable, non-dedupable unit.
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/textures@/bundle/media/textures"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/menu@/bundle/media/menu"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/menu_text@/bundle/media/menu_text"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/ui@/bundle/media/ui"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/icons@/bundle/media/icons"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/ipad_menu@/bundle/media/ipad_menu"
    # A handful of used textures sit directly in media/ (not a subdir) — sky, particles, portal
    # swirl. Individually named rather than preloading all of media/ root (numbers_text.psd,
    # .DS_Store are not assets the engine reads).
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/sky_box.png@/bundle/media/sky_box.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/sky_box_bw.png@/bundle/media/sky_box_bw.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/smoke_tex.png@/bundle/media/smoke_tex.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/smoke.png@/bundle/media/smoke.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/Flame_256.png@/bundle/media/Flame_256.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/Flame_512.png@/bundle/media/Flame_512.png"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/portal_twirl.png@/bundle/media/portal_twirl.png"
    # Creature skins (pass 27): Moof_Default.png / *_Blink / *_Rage plus the MASKS/ variants that
    # Resources::getSkin recolours from. Same basename-index lookup as every other texture, so
    # this one goes under /bundle/media like the rest. WITHOUT it the models draw as pure black
    # silhouettes and nothing errors: Model.mm binds `getTex(SKIN_MOOF)->name`, which is 0 when
    # the PNG never loaded, and sampling an unbound texture unit yields (0,0,0,1). Measured, not
    # guessed — the shim's [eden-skin] probe reported boundTex=0 with every other uniform healthy.
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models@/bundle/media/models"
    # Creature models (pass 27). Classes/World.mm:389 calls LoadModels([[NSBundle mainBundle]
    # resourcePath] + "/"), and CPVRTResourceFile fopen()s <readPath><basename> — so these must
    # land at /bundle/<Name>.pod, FLAT, not under /bundle/media/models. That is also what Xcode's
    # Copy-Bundle-Resources phase does on device (it flattens the whole media/ tree), so naming
    # each file individually here reproduces the real bundle layout rather than inventing one.
    # ~1.6 MB total, hence preloaded rather than lazily fetched. (The .pod files are therefore
    # packaged twice — once here, once inside the media/models preload above, which is there for
    # the skin PNGs. Trading 1.5 MB for two one-line rules beats a per-file PNG list.)
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Moof.pod@/bundle/Moof.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Batty.pod@/bundle/Batty.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Green.pod@/bundle/Green.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Nergle.pod@/bundle/Nergle.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Stumpy.pod@/bundle/Stumpy.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Charger.pod@/bundle/Charger.pod"
    "SHELL:--preload-file ${EDEN_PARENT_DIR}/media/models/Stalker.pod@/bundle/Stalker.pod"
    # P4: the pre-generated default world (repo-root Eden.eden, ~52MB RLE reference map). The
    # engine streams default-world terrain from it on first world-create (gen_default path in
    # FileManager::loadWorld -> FileManagerHelper::fmh_readColumnFromDefault), resolved via
    # NSBundle -pathForResource:@"Eden.eden". NSBundle.mm indexes /bundle/media by basename AND
    # stats /bundle/<name> as a fallback for this file.
    #
    # Pass 30: lazily fetched instead of --preload-file'd — see the "lazy Eden.eden fetch" comment
    # by the public/audio symlink above and src/seam/js/eden_default_world.pre.js. /bundle itself
    # must still exist as a preloaded directory (from the media preloads above) for the .pre.js
    # run dependency to write the fetched file into; nothing needs to preload Eden.eden's bytes.
  )
  if(EDEN_THREADED)
    # D1: real pthreads (fixes C3's world-load-thread races per the plan's reframing — see
    # docs/PORT-STATUS.md) + OffscreenCanvas rendering from the worker + a stack-switching-safe
    # unwind-info format for that combination.
    list(APPEND EDEN_LINK_FLAGS
      -pthread
      -sPROXY_TO_PTHREAD=1
      -sOFFSCREENCANVAS_SUPPORT=1
      -sUSE_OFFSET_CONVERTER=1
    )
    target_compile_options(eden PRIVATE -pthread)
  else()
    # Single-thread fallback (plan D1 fallback note): main thread only, OPFS via WASMFS's async
    # access path, load runs synchronously with a progress yield (TODO P4 to actually implement
    # the yield — this flag alone doesn't provide it).
    message(STATUS "Eden web: EDEN_THREADED=OFF — single-thread fallback build (see web-port-plan.md D1 fallback note)")
  endif()

  # Q1 (dazzling-munching-bengio.md perf audit, C1): Release-only link flags. Kept separate from
  # EDEN_LINK_FLAGS (rather than $<CONFIG:Release> generator expressions mixed into that list)
  # because several of these are SHELL:-wrapped multi-token flags where generator-expression
  # quoting has historically been fragile in this file (see the --preload-file SHELL: comment
  # above for the same class of footgun) — a flat CONFIG-gated list is easier to audit.
  # `-sENVIRONMENT=web` was TRIED and REVERTED this pass: it makes the generated eden.js force
  # `ENVIRONMENT_IS_WEB=true` unconditionally, which breaks `node eden.js` — this port's own
  # documented fast headless regression gate (web/CLAUDE.md "Build & run") — because the node-only
  # branches (fetchRemotePackage falling back to `fs.readFileSync`, etc.) are compiled out and the
  # web-only `fetch`/`window` path runs under node instead and throws. Measured, not guessed: the
  # node run threw exactly there. Keeping the default (auto-detect) environment costs a few hundred
  # bytes of detection code and preserves the only automated correctness check this build has.
  # NOT included here: --closure 1 and -sINCOMING_MODULE_JS_API trimming (both from the audit's
  # Q1 step 2) — closure minification needs the public/*.js <-> Module surface audited for
  # bracket-vs-dot property access first (untested risk, no browser-based CI here to catch a
  # silently-renamed property), and STACK_SIZE is deliberately left at the Debug-era 8 MB (audit
  # step 4) rather than guessed smaller — both are follow-ups once this build has been profiled.
  target_link_options(eden PRIVATE
    ${EDEN_LINK_FLAGS}
    $<$<CONFIG:Release>:-sASSERTIONS=0>
    # Project audit 2026-07-30, row B1 — the rest of the Release flag sweep the prior audit's Q1
    # step 2 left undone. Measured as one pass: fresh Release+diagnostics builds at every point in
    # the bisect (single flag alone, and all four together) all pass the P1 headless gate and all
    # three other headless suites (menu-flow, lazy-world, gamepad) clean. -flto is the fifth flag,
    # landed pass 56 once the abort pass 53 blamed on it turned out to be our own uninitialised
    # C++ ivar — see the compile-options comment above. It MUST appear on both sides: -flto here
    # without -flto on the compile side means there is no bitcode to link-time-optimise, and the
    # reverse silently produces objects the linker treats as ordinary ones.
    #   -sMALLOC=emmalloc (smaller/faster than dlmalloc for this port's allocation profile —
    #     mostly fixed-size engine structs and short-lived shim objects, not the varied-size
    #     workload dlmalloc is tuned for)
    #   -sGL_TRACK_ERRORS=0 / -sGL_ASSERTIONS=0 (removes Emscripten's own per-GL-call bookkeeping
    #     in the GL glue it generates around this port's hand-written shim — directly on the
    #     shim's hot draw-call path; safe in Release since this port's OWN glGetError probe in
    #     gl_es1_shim.cpp, used by the first-5-frames diagnostic and EDEN_DIAGNOSTICS builds, is
    #     independent of Emscripten's glue-level tracking)
    #   -sTEXTDECODER=2 (use TextDecoder for UTF-8 where available, smaller JS glue)
    #   --emit-symbol-map (so a Release build — which has no -g/DWARF, see above — still has a
    #     name<->mangled-symbol map on disk for reading a stack trace after the fact)
    $<$<CONFIG:Release>:-flto>
    $<$<CONFIG:Release>:-sMALLOC=emmalloc>
    $<$<CONFIG:Release>:-sGL_TRACK_ERRORS=0>
    $<$<CONFIG:Release>:-sGL_ASSERTIONS=0>
    $<$<CONFIG:Release>:-sTEXTDECODER=2>
    $<$<CONFIG:Release>:--emit-symbol-map>
  )
  # --pre-js files are consumed at LINK time and CMake cannot see that from the flag string, so
  # without this an edit to eden_default_world.pre.js rebuilds NOTHING ("Built target eden") and
  # the stale JS keeps running — silently, which cost pass 46 a confusing debugging round.
  set_property(TARGET eden APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/seam/js/eden_default_world.pre.js")
  target_compile_definitions(eden PRIVATE $<$<BOOL:${EDEN_THREADED}>:EDEN_THREADED=1>)
else()
  message(WARNING "Eden web: not configured via emcmake/Emscripten toolchain — this target is only meaningful under emsdk (see web/cmake/README.md). Configuring anyway so source-list/flag correctness can be inspected without a working compiler.")
endif()
