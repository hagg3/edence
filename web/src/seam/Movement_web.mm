// Movement_web.mm — Phase 1 of the PC controls audit (see
// /Users/sam/.claude/plans/please-run-an-audit-lovely-dongarra.md, finding F1/F2).
//
// ROOT CAUSE (F1): Classes/Player.mm:940-958 damps velocity with a PER-FRAME multiplier
// (vel *= .90 on ground, etc.), not one scaled by etime. Acceleration IS etime-scaled
// (vel += accel*etime, accel = MOVE_SPEED*walk_force), so steady-state ground speed is
// v = 9*a*dt — proportional to frame time. Below ~56 fps Player::update's own substep
// (Classes/Player.mm:755-767) self-regulates to the iOS-era ~5.6 u/s; above that (this port
// runs ~75-144 Hz in Chrome) there is no compensation and top speed falls as low as -61%.
//
// FIX: `--wrap` Player::setSpeed (mangled name confirmed via
// `llvm-nm build-st/CMakeFiles/eden.dir/.../Classes/Player.mm.o`, NOT guessed — see
// web/docs/STATUS.md's "measure, never extrapolate" rule) and scale the walk_dir
// magnitude passed through by `k = clamp(DT_REF/dt_smoothed, 1, 4)`. Both callers of
// setSpeed — the keyboard path (Input_web.mm's eden_set_move_input) and the real touch
// joystick (Classes/Joystick.mm:70/83) — funnel through this one wrap, so both are fixed by
// one piece of code, and Player.mm itself is never touched.
//
// `max_walk_speed` (the ceiling, `walk_speed*SPEED_M*1.3`) is deliberately left alone — only
// the ACCELERATION term (walk_dir's magnitude) is scaled. That preserves the exponential
// "bouncy" ramp-up feel (only `a` changes, not the .90 damping) and leaves gravity/the jump
// arc untouched (they are already etime-scaled and don't go through setSpeed at all).
//
// F2 (Shift-sprint is a no-op): both callers pass a UNIT-length dir vector plus `walk_speed`
// as a separate ceiling-only parameter, so walk_force's magnitude (and therefore
// acceleration) never actually reflects `walk_speed` — only the clamp does. Since natural
// steady-state (after the fix above) sits at ~5.25, below every ceiling that matters, Shift
// changes nothing. Fixed by ALSO folding `walk_speed` into the scaled magnitude (target
// v = 5.25 * walk_speed), leaving the ceiling at walk_speed*5.85 so it never binds.
#import "../shim/foundation/uikit_stubs.h"
#import "../shim/foundation/NSArray.h"
#import "../shim/foundation/NSAutoreleasePool.h"
#import "../../../Classes/World.h"
#include <emscripten/emscripten.h>
#include <algorithm>
#include <cmath>

namespace {

constexpr double kDtRef = 1.0 / 60.0;   // the frame rate the engine's feel was tuned at
constexpr float  kMinK = 1.0f;          // never SLOW the player down — below ~56fps the
                                         // engine's own substep already regulates (F1 table)
constexpr float  kMaxK = 4.0f;          // cap so a stutter/240Hz panel can't spike accel

double g_lastTickTime = 0.0;
bool   g_haveLastTick = false;
double g_dtEMA = kDtRef;                // smoothed frame interval; seeded at the reference

} // namespace

// Port-owned setting (Settings_web.mm's kSettings[] "fps_normalize" row), default ON. Defined in
// Settings_web.mm exactly like eden_look_sensitivity/eden_fov_degrees; this file just reads it.
extern "C" float eden_fps_normalize;

extern "C" {

// Polled once per rAF frame from public/eden-st.html's existing trackCursorNeed loop, alongside
// eden_ui_tick()/EdenSettings.tick() — NOT derived from World::update's own etime (that's the
// raw, jittery, uncompensated delta this whole fix exists to counteract; see
// EdenViewController_web.cpp:57-59). A simple EMA smooths out a single dropped frame from
// spiking `k` for one tick.
EMSCRIPTEN_KEEPALIVE
void eden_movement_tick(void) {
    double now = emscripten_get_now() / 1000.0;
    if (g_haveLastTick) {
        double dt = now - g_lastTickTime;
        // Guard against a backgrounded-tab wakeup (huge dt) or a zero/negative reading —
        // neither is a real frame interval, and folding either into the EMA would corrupt it
        // for many frames afterward.
        if (dt > 0.0 && dt < 0.5) {
            const double alpha = 0.15;
            g_dtEMA = g_dtEMA * (1.0 - alpha) + dt * alpha;
        }
    }
    g_lastTickTime = now;
    g_haveLastTick = true;
}

EMSCRIPTEN_KEEPALIVE
float eden_movement_debug_k(void) {
    double k = kDtRef / g_dtEMA;
    return (float)std::clamp(k, (double)kMinK, (double)kMaxK);
}

} // extern "C"

// ---------------------------------------------------------------------------------------------
// --wrap=_ZN6Player8setSpeedE6Vectorf (Player::setSpeed(Vector, float)) — see CMakeLists.txt.
// ---------------------------------------------------------------------------------------------
extern "C" {
void __real__ZN6Player8setSpeedE6Vectorf(Player* self, Vector walk_dir, float walk_speed);
void __wrap__ZN6Player8setSpeedE6Vectorf(Player* self, Vector walk_dir, float walk_speed) {
    float k = 1.0f;
    if (eden_fps_normalize != 0.0f) {
        double raw_k = kDtRef / g_dtEMA;
        k = (float)std::clamp(raw_k, (double)kMinK, (double)kMaxK);
    }
    // F2: fold walk_speed into the scaled magnitude too, not just the (untouched) ceiling —
    // see this file's header. A zero-length dir (stop) stays zero regardless.
    const float scale = k * walk_speed;
    walk_dir.x *= scale;
    walk_dir.y *= scale;
    walk_dir.z *= scale;
    __real__ZN6Player8setSpeedE6Vectorf(self, walk_dir, walk_speed);
}
} // extern "C"

// ---------------------------------------------------------------------------------------------
// Phase 6 — "advanced movement", opt-in via the `advanced_movement` setting (default OFF).
// Everything here writes Player's PUBLIC fields (CLAUDE.md F8 in the audit plan) through a
// --wrap of Player::preupdate(float) — cross-TU (called from Classes/World.mm:499), so it sees
// every engine tick exactly once, in the same order World::update always runs it. Mangled name
// confirmed via `llvm-nm build-st/CMakeFiles/eden.dir/.../Classes/Player.mm.o`.
//
// 1. Auto-rejump (F7) is NOT reimplemented here — Classes/Player.mm:897-917's own gate
//    (`lastjump!=TRUE && !jumping`) already re-fires a held jump on both mobile and PC; see
//    docs/player-input-camera.md for the write-up this finding asks for. This wrap only removes
//    the COST of that gate (2).
//
// 2. Zero-delay bunny-hop. The engine's gate re-triggers a held jump only after `lastjump`
//    (a Player.mm file-static, unreachable — same class of gap as `onground`/`onramp`) has
//    lagged `jumping` by one frame, and pays ground friction (vel.x/z *= .9) during that gap —
//    F7 measured this at ~-27% lateral speed per hop, so chained hops decay instead of building.
//    This wrap watches `jumping` across the real preupdate call: if it was TRUE before and the
//    engine just cleared it to FALSE (a landing, this exact frame) and the jump button is still
//    held, it writes `vel.y = JUMP_SPEED` and `jumping = TRUE` directly, before the frame ends —
//    skipping the gate and its friction tax entirely, so speed carries across the chain. Setting
//    `jumping` back to TRUE ourselves also means next frame's real gate check (`!jumping`) is
//    false regardless of the unreachable `lastjump`, so it never double-fires.
//
// 3. Wheel-up/-down as jump (the Source convention) is wired from public/eden-st.html's wheel
//    handler directly into eden_set_jump's synthetic touch — no engine-side piece needed, so it
//    isn't in this file.
//
// 4. Air acceleration (the plan's explicitly-flagged stretch goal) is NOT implemented — highest
//    risk item in the plan ("build it last... abandon it if it destabilises collisions"), and the
//    first three items already deliver the requested feel. Left for a future session; `vel`/
//    `walk_force` being public (F8) is what would make it tractable without touching Classes/.
extern "C" float eden_advanced_movement;

namespace {
constexpr float kJumpSpeed = 6.7f;  // Classes/Player.mm:21 `#define JUMP_SPEED 6.7f` — file-local
                                     // macro, duplicated here same as Input_web.mm's YAW_SPEED/
                                     // kPlayerUsageId; keep in sync if it ever changes there.
} // namespace

extern "C" {
BOOL __real__ZN6Player9preupdateEf(Player* self, float etime);
BOOL __wrap__ZN6Player9preupdateEf(Player* self, float etime) {
    if (eden_advanced_movement == 0.0f || !self) {
        return __real__ZN6Player9preupdateEf(self, etime);
    }
    const BOOL wasJumping = self->jumping;
    const BOOL result = __real__ZN6Player9preupdateEf(self, etime);
    const bool justLanded = (wasJumping == TRUE) && (self->jumping == FALSE);
    const bool jumpHeld = self->world && self->world->hud && self->world->hud->m_jump;
    if (justLanded && jumpHeld) {
        self->vel.y = kJumpSpeed;
        self->jumping = TRUE;
    }
    return result;
}
} // extern "C"
