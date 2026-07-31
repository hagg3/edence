// DisplayProfile_web.mm — implementation of the profile + derived display metrics.
// See DisplayProfile_web.h for what a "profile" is, what "unpinned" means, and why both audit rows
// (D1 and D4) land in one file.
//
// WHY THIS IS SEAM CODE AND NOT ENGINE CODE. The split the audit draws is: platform DETECTION stays
// in the seam, layout GENERALISATION goes in the engine. So the two engine-side changes this file
// depends on — `Hud::layoutForScreen()` / `Menu::layoutForScreen()` (rect math lifted out of the
// constructors so it can run more than once) and `Input::screenMetricsChanged()` — live in
// `Classes/`, and everything about *what the numbers should be on a browser* lives here.
//
// THE SIDE-EFFECT RULE (this port's most-bitten class, PORT-STATUS "a seam replacement owes the
// SIDE EFFECTS of what it replaced"): the globals written by eden_display_apply() below are the
// complete set the original `Classes/EAGLView.mm -initWithCoder:` wrote — SCREEN_WIDTH,
// SCREEN_HEIGHT, IS_WIDESCREEN, P_ASPECT_RATIO, IS_IPAD, IS_RETINA, SUPPORTS_RETINA, SCALE_WIDTH,
// SCALE_HEIGHT, G_EAGL_VIEW — minus G_EAGL_VIEW, which EAGLView_web.mm still owns because it is the
// view pointer, not a metric.
#import "DisplayProfile_web.h"

// Before the engine headers: Globals.h declares `const GLubyte blockColor[]` without including a GL
// header of its own, so it only compiles behind something that has already defined the GL types.
#include "gl_es1_shim.h"
#import "../../../Classes/Globals.h"
#import "../../../Classes/Constants.h"
#import "../../../Classes/World.h"
#import "../../../Classes/Hud.h"
#import "../../../Classes/Menu.h"
#import "../../../Classes/Input.h"
#include <emscripten/emscripten.h>
#include <cstdio>
#include <cmath>

// Declared in Classes/Globals.mm but NOT in Globals.h — the original EAGLView.mm:34 externs it
// locally, so this file does the same (same reasoning as EAGLView_web.mm's copy).
extern bool IS_WIDESCREEN;

// Owned by Settings_web.mm, in the plain-mutable-global style every other port-owned setting there
// uses. Both are stored as the ENUM INDEX of their kSettings[] row, and index 0 is "Auto" for both,
// which is what makes the profile a live default rather than a one-shot write: leaving them on Auto
// means changing the input mode re-resolves them. Their compiled defaults are Auto, so this file
// behaves correctly during the frames before eden_settings_init() has run.
extern float eden_ui_scale;
extern float eden_display_layout;

// ---------------------------------------------------------------------------------------------
// The profile table (audit D4). Two rows of DEFAULTS. Adding a third profile is adding a row.
// ---------------------------------------------------------------------------------------------
//
// DESKTOP defaults, and why each one:
//   ui_scale 125%     — halves the on-screen size of every HUD element versus the pinned profile
//                       (a 512-point-tall layout space instead of 320) without going all the way to
//                       100%, which is legible on a 27" display but small on a 13" laptop window.
//                       The row exists precisely because that is a taste call.
//   layout  Adaptive  — the whole point of D1 on a resizable window: no letterboxing, and a wider
//                       window shows more world.
//   fps/dpr/scale     — unchanged from the compiled defaults; desktop has no thermal budget to
//                       protect and "as sharp as the display allows" is the right default there.
//
// TOUCH defaults are deliberately EXACTLY what this port shipped before this row landed —
// ui_scale 200% + Classic aspect reproduces 568x320 to the point, and fps_cap 60 / dpr_cap 1.5x are
// the values the pre-existing eden_apply_profile_defaults() already wrote. That is the audit's own
// mitigation ("keep the pinned profile as the default until the new path is verified on a real
// phone") expressed as data rather than as a flag: the unexercised path is opt-in on touch, and a
// touch player who changes nothing gets a bit-identical layout to the one that shipped.
static const EdenProfile kProfiles[2] = {
    // name       ui_scale  layout  fps_cap  dpr_cap  render_scale  touch_chrome
    {  "desktop",        2,      2,       0,       2,            2,            0 },
    {  "touch",          4,      1,       3,       1,            2,            1 },
};

// Option-list indexes, spelled out so the arithmetic below never contains a bare literal that has
// to be cross-referenced against Settings_web.mm's schema strings.
enum { UI_SCALE_AUTO = 0 };
static const int kUiScalePct[] = { 0 /*Auto*/, 100, 125, 150, 200 };
enum { LAYOUT_AUTO = 0, LAYOUT_CLASSIC = 1, LAYOUT_ADAPTIVE = 2 };

// The point space at ui_scale 100%. 640 rather than 320 so that 200% — the profile the engine was
// written for — lands exactly on the stock 320-point height with no rounding.
static const float kBasePointHeight = 640.0f;

// Guard rails on the derived numbers. The aspect clamp is what keeps a portrait phone or a 32:9
// monitor from producing a layout the engine's absolutely-sized rects cannot fill sensibly; the
// page letterboxes to eden_display_aspect_x1000() when the clamp bites, so the picture stays
// undistorted either way. The width/height clamps are belt-and-braces against a garbage viewport
// (a 0-height box during a fullscreen transition, say) reaching the projection math.
static const float kMinAspect = 1.20f;
static const float kMaxAspect = 2.40f;
static const int   kMinPointW = 320,  kMaxPointW = 1600;
static const int   kMinPointH = 240,  kMaxPointH = 800;

// THE DENSITY FLOOR — one engine point may never be smaller than one CSS pixel.
//
// `ui_scale` alone gives a FIXED point space, which means the UI is a fixed FRACTION of the canvas:
// shrink the window and every HUD icon shrinks with it. That is right on a desktop monitor (the
// game gets bigger, the HUD grows with it) and wrong the moment the window gets small — resize a
// desktop browser to phone proportions and the 45-point mode buttons come out at 35 CSS px and
// keep going. Reported from live play 2026-07-31, and it is not a touch-profile problem: nothing
// about resizing a mouse-driven window flips `pointer: coarse`, so the desktop profile's 512-point
// space is still in force and still correct — it just needs a floor.
//
// One CSS pixel per point is not an arbitrary floor: it is EXACTLY the density the engine's
// absolutely-sized art was drawn for. On the iPhone 5 the viewport was 568x320 CSS pixels and the
// point space was 568x320 — UIKit points ARE CSS pixels. So this says "never render the HUD denser
// than the device it was designed on", which is also what makes a phone-shaped window degrade into
// something close to the classic layout instead of a miniature of the desktop one.
static const float kMinCssPxPerPoint = 1.0f;

// The page's real box, in CSS pixels. 0 until the page reports one; until then the classic aspect
// is used, which is also what the headless build (`node eden.js`, no DOM) runs on forever.
static int g_cssW = 0;
static int g_cssH = 0;

// Last-applied point space, so a no-op refresh does not re-run the engine's layout.
static int g_pointW = 0;
static int g_pointH = 0;

// Settings_web.mm owns the input-mode arbitration; the profile follows it rather than detecting
// anything a second time.
extern "C" int eden_effective_input_is_touch(void);

// ---------------------------------------------------------------------------------------------

extern "C" int eden_active_profile(void) {
    return eden_effective_input_is_touch() ? EDEN_PROFILE_TOUCH : EDEN_PROFILE_DESKTOP;
}

extern "C" const EdenProfile* eden_profile_get(int id) {
    if (id != EDEN_PROFILE_TOUCH) id = EDEN_PROFILE_DESKTOP;
    return &kProfiles[id];
}

extern "C" const EdenProfile* eden_profile_active(void) {
    return eden_profile_get(eden_active_profile());
}

static int eden_resolved_ui_scale_pct(void) {
    int idx = (int)lroundf(eden_ui_scale);
    if (idx == UI_SCALE_AUTO) idx = eden_profile_active()->ui_scale;
    if (idx < 1 || idx >= (int)(sizeof(kUiScalePct) / sizeof(kUiScalePct[0])))
        idx = kProfiles[EDEN_PROFILE_TOUCH].ui_scale;   // stock 200% is the safe fallback
    return kUiScalePct[idx];
}

static int eden_resolved_layout(void) {
    int idx = (int)lroundf(eden_display_layout);
    if (idx == LAYOUT_AUTO) idx = eden_profile_active()->display_layout;
    return (idx == LAYOUT_ADAPTIVE) ? LAYOUT_ADAPTIVE : LAYOUT_CLASSIC;
}

// Rounds to an EVEN integer: every 2D pass projects through `glOrthof(0, SCREEN_WIDTH*2, ...)`
// (Graphics.mm's IS_IPAD && IS_RETINA branch), and an odd point dimension there puts the ortho
// edge on a half-pixel of the retina-doubled space for no benefit.
static int eden_round_even(float v) {
    int n = (int)(v / 2.0f + 0.5f) * 2;
    return n;
}

static int eden_clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

// The one place the metrics are written. Everything else in this file funnels here.
static void eden_display_apply(void) {
    const int   pct    = eden_resolved_ui_scale_pct();
    const int   layout = eden_resolved_layout();

    float aspect = (float)IPHONE5_WIDTH / (float)IPHONE_HEIGHT;   // 1.775 — the classic profile
    if (layout == LAYOUT_ADAPTIVE && g_cssW > 0 && g_cssH > 0)
        aspect = (float)g_cssW / (float)g_cssH;
    if (aspect < kMinAspect) aspect = kMinAspect;
    if (aspect > kMaxAspect) aspect = kMaxAspect;

    float pointH = kBasePointHeight * 100.0f / (float)pct;
    // Apply the density floor against the box the page will actually letterbox the canvas to, not
    // against the raw viewport: when the aspect clamp bites (a portrait window), the canvas is
    // shorter than the viewport and it is the canvas the UI is drawn into.
    if (g_cssW > 0 && g_cssH > 0) {
        float boxH = (float)g_cssH;
        if ((float)g_cssW / aspect < boxH) boxH = (float)g_cssW / aspect;
        const float maxPointsForBox = boxH / kMinCssPxPerPoint;
        if (pointH > maxPointsForBox) pointH = maxPointsForBox;
    }
    const int h = eden_clampi(eden_round_even(pointH), kMinPointH, kMaxPointH);
    const int w = eden_clampi(eden_round_even((float)h * aspect), kMinPointW, kMaxPointW);

    // Retina/UI-scale flags. Unchanged from what EAGLView_web.mm pinned — see CLAUDE.md #3
    // ("IS_IPAD == true also on retina iPhones", i.e. it means '2x UI scale') and this port's own
    // note that SCALE_WIDTH/SCALE_HEIGHT are DIVISORS in layout math and must never be 0. These are
    // NOT what D1 unpins: they select the @2x asset set and the point->ortho factor, both of which
    // stay correct at any point-space size. `ui_scale` moves the point space, not these.
    IS_IPAD         = TRUE;
    IS_RETINA       = TRUE;
    SUPPORTS_RETINA = TRUE;
    SCALE_WIDTH     = 2.0f;
    SCALE_HEIGHT    = 2.0f;

    SCREEN_WIDTH  = (float)w;
    SCREEN_HEIGHT = (float)h;
    // ALWAYS derived — the stock EAGLView.mm only did this inside `if(IS_WIDESCREEN)` and left the
    // other branch on a 4:3 default that matched no live layout. See the header.
    P_ASPECT_RATIO = SCREEN_WIDTH / SCREEN_HEIGHT;
    // Stock set this by comparing the device's bounds against 568 points. What every one of its
    // ~10 branches in Classes/ actually keys off is "is there more width here than the 480-point
    // layout was drawn for", so that is what it now says. True for every profile this port can
    // produce, which is correct: kMinPointW is already above 480 at the smallest UI scale.
    IS_WIDESCREEN = (SCREEN_WIDTH > (float)IPHONE_WIDTH);

    // Util.mm's findWorldCoords unprojects a POINT-space tap against whatever GL_VIEWPORT reports,
    // after scaling it by SCALE_*. Keep the shim's answer in step or every click lands off-target.
    eden_gl_set_pick_viewport((int)(SCREEN_WIDTH * SCALE_WIDTH),
                              (int)(SCREEN_HEIGHT * SCALE_HEIGHT));

    const bool changed = (w != g_pointW || h != g_pointH);
    g_pointW = w;
    g_pointH = h;
    if (!changed) return;

    std::fprintf(stderr, "[eden-display] profile=%s ui_scale=%d%% layout=%s -> %dx%d points"
                         " (aspect %.3f)\n",
                 eden_profile_active()->name, pct,
                 (layout == LAYOUT_ADAPTIVE) ? "adaptive" : "classic",
                 w, h, (double)P_ASPECT_RATIO);

    // Re-layout whatever already exists. At boot none of it does — the constructors read the
    // globals set above — so this is purely the "metrics changed while running" path.
    Input::getInput()->screenMetricsChanged();
    if (World::getWorld) {
        if (World::getWorld->hud)  World::getWorld->hud->layoutForScreen();
        if (World::getWorld->menu) World::getWorld->menu->layoutForScreen();
    }
}

extern "C" {

EMSCRIPTEN_KEEPALIVE
void eden_display_set_viewport(int css_w, int css_h) {
    if (css_w <= 0 || css_h <= 0) return;
    if (css_w == g_cssW && css_h == g_cssH) return;
    g_cssW = css_w;
    g_cssH = css_h;
    eden_display_apply();
}

EMSCRIPTEN_KEEPALIVE
void eden_display_refresh(void) { eden_display_apply(); }

EMSCRIPTEN_KEEPALIVE
int eden_display_point_width(void)  { return g_pointW > 0 ? g_pointW : IPHONE5_WIDTH; }

EMSCRIPTEN_KEEPALIVE
int eden_display_point_height(void) { return g_pointH > 0 ? g_pointH : IPHONE_HEIGHT; }

EMSCRIPTEN_KEEPALIVE
int eden_display_aspect_x1000(void) {
    if (g_pointH <= 0) return (IPHONE5_WIDTH * 1000) / IPHONE_HEIGHT;
    return (int)(1000.0f * (float)g_pointW / (float)g_pointH + 0.5f);
}

// Does the active profile want the on-screen joystick / jump / crouch chrome? Read by
// Settings_web.mm's eden_apply_input_profile (which owns hud->use_joystick) and exported for the
// page, which hides its own touch-only affordances on the same signal.
EMSCRIPTEN_KEEPALIVE
int eden_profile_touch_chrome(void) { return eden_profile_active()->touch_chrome; }

// The active profile's name, for the debug JSON and for the settings panel's "Auto (desktop)" hint.
EMSCRIPTEN_KEEPALIVE
const char* eden_profile_name(void) { return eden_profile_active()->name; }

} // extern "C"
