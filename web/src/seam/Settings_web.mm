// Settings_web.mm — the port's settings model (pass 28).
//
// WHAT THIS REPLACES
// `Classes/SettingsMenu.mm` draws a fixed 5-row GL panel of ON/OFF images with hard-coded pixel
// rects (`rect_on[j].origin.x = 300+115` and friends), reachable only from the main menu's Options
// button. It is not extensible — every row is a hand-placed texture and a hard-coded `if` in both
// update() and render() — and there is nowhere to put a slider at all.
//
// So the DATA half of that class is kept and the UI half is replaced:
//   * KEPT, untouched: `SettingsMenu::{load,save,getNewWorldName}` and its `properties[]` array.
//     Those own the engine-visible meaning of every toggle (Resources::playmusic, Player::
//     autojump_option/health_option, CREATURES_ON, ...) and the NSUserDefaults round-trip. This
//     file WRITES `properties[i].value` and then calls the engine's own `save()`, so the engine
//     applies its own settings exactly as it always did.
//   * REPLACED via `--wrap`: `SettingsMenu::update(float)` and `SettingsMenu::render()` become
//     no-ops, so the old GL panel neither draws nor eats touches while the DOM panel is up. Both
//     are called from `Classes/Menu.mm` (a different translation unit from SettingsMenu.mm), which
//     is what makes wasm-ld's --wrap able to see them at all.
// With both wrapped, `Menu::update`/`Menu::render` still take their `if (showsettings) { ...;
// return; }` early-outs — so the main menu stops responding and keeps drawing just its background
// while the panel is open. That is exactly the modal behaviour the old panel had.
//
// The port's OWN preferences (sensitivity, FOV, volumes, block preview, ...) live here too, in one
// table with the engine ones, because a settings screen split across two models would drift. The
// JS side (public/eden-settings.js) renders whatever `eden_settings_schema()` describes and knows
// nothing about which half a row belongs to.
//
// PERSISTENCE is NSUserDefaults for everything — the engine rows through `SettingsMenu::save()`,
// the port rows written here directly. That shim is localStorage-backed as of pass 28, so both
// halves survive a reload with one mechanism (see src/shim/foundation/NSUserDefaults.mm).
#import "../shim/foundation/uikit_stubs.h"
#import "../shim/foundation/NSUserDefaults.h"
#import "../shim/foundation/NSNumber.h"
#import "../shim/foundation/NSString.h"
#import "../../../Classes/World.h"
#import "../../../Classes/Menu.h"
#import "../../../Classes/SettingsMenu.h"
#import "../../../Classes/Resources.h"
#import "../../../Classes/Input.h"
#import "../../../Classes/SimpleAudioEngine.h"
#include <emscripten/emscripten.h>
#include <cstdio>
#include <cstring>
#include <cmath>

// Mirrors the anonymous enum at the top of Classes/SettingsMenu.mm. Those constants are file-local
// there, so the indexes are duplicated — same situation as Player's `usage_id` in Input_web.mm. If
// they ever change, the engine toggles silently address the wrong row; the labels below are the
// canary (they are the engine's own `pnames[]` strings).
enum {
    ENG_CREATURES = 0,
    ENG_AUTOJUMP  = 1,
    ENG_HEALTH    = 2,
    ENG_SOUND     = 3,
    ENG_MUSIC     = 4,
};

// ---------------------------------------------------------------------------------------------
// The schema. Order here IS the display order; `group` drives the section headings in the panel.
// `kind`: 0 = toggle (0/1), 1 = range, 2 = enum (a small label list, value is the 0-based index
// into `options`). `engine` >= 0 means the value lives in SettingsMenu::properties[engine]; -1
// means this file owns it.
// ---------------------------------------------------------------------------------------------
enum { KIND_TOGGLE = 0, KIND_RANGE = 1, KIND_ENUM = 2 };

struct Setting {
    const char* key;      // persistence key AND the JS-side id
    const char* label;
    const char* group;
    int   kind;
    int   engine;         // index into SettingsMenu::properties[], or -1
    float min, max, step;
    float def;
    const char* hint;     // one line of explanation, shown under the control
    const char* options;  // KIND_ENUM only: comma-separated labels, e.g. "Auto,Touch,Keyboard+Mouse"
};

static const Setting kSettings[] = {
  // key                 label                group        kind         engine        min  max  step  def   hint                                                                options
  { "health",            "Health",            "Gameplay",  KIND_TOGGLE, ENG_HEALTH,     0,   1,   1,   1,  "Take damage from falls, fire and creatures.",                     NULL },
  { "autojump",          "Auto-jump",         "Gameplay",  KIND_TOGGLE, ENG_AUTOJUMP,   0,   1,   1,   1,  "Step up single blocks automatically.",                            NULL },
  { "creatures",         "Creatures",         "Gameplay",  KIND_TOGGLE, ENG_CREATURES,  0,   1,   1,   1,  "Spawn and render wildlife. Off is faster.",                       NULL },

  { "music",             "Music",             "Audio",     KIND_TOGGLE, ENG_MUSIC,      0,   1,   1,   1,  NULL,                                                               NULL },
  { "sound",             "Sound effects",     "Audio",     KIND_TOGGLE, ENG_SOUND,      0,   1,   1,   1,  NULL,                                                               NULL },
  { "music_volume",      "Music volume",      "Audio",     KIND_RANGE,  -1,             0,   1, .05f,  1,  NULL,                                                               NULL },
  { "ambience_volume",   "Ambience volume",   "Audio",     KIND_RANGE,  -1,             0,   1, .05f,  1,  NULL,                                                               NULL },
  { "effects_volume",    "Effects volume",    "Audio",     KIND_RANGE,  -1,             0,   1, .05f,  1,  NULL,                                                               NULL },
  { "touch_controls_sound", "Touch controls sound", "Audio", KIND_TOGGLE, -1,           0,   1,   1,   0,  "Joystick and jump-button taps make a sound. Touchscreen only -- never fires for keyboard/mouse. Off by default.", NULL },

  // input_mode: 0=Auto (matchMedia + first-input detection, see eden-st.html), 1=Touch,
  // 2=Keyboard+Mouse. Auto is the default so nothing changes for players who never open Settings.
  { "input_mode",        "Input mode",        "Controls",  KIND_ENUM,   -1,             0,   2,   1,   0,  "Auto-detects touch vs. keyboard/mouse; force one if it guesses wrong.", "Auto,Touch,Keyboard+Mouse" },
  { "hold_to_act",       "Hold to mine/build", "Controls",  KIND_TOGGLE, -1,            0,   1,   1,   1,  "Hold the mouse button to repeat, instead of one block per click.", NULL },
  { "mouse_sensitivity", "Mouse sensitivity", "Controls",  KIND_RANGE,  -1,          .25f,  3, .05f,  1,  "Look speed while the pointer is locked.",                         NULL },
  { "mouse_sensitivity_y", "Mouse sensitivity (Y)", "Controls", KIND_RANGE, -1,      .25f,  3, .05f,  1,  "Vertical look speed, if you want it different from horizontal.",  NULL },
  { "invert_look",       "Invert look",       "Controls",  KIND_TOGGLE, -1,             0,   1,   1,   0,  NULL,                                                               NULL },
  // Row #24 (gamepad). Read only by public/eden-gamepad.js, which is a pure translator over the
  // existing input entry points — there is no C-side gamepad code and these rows deliberately do
  // not touch the engine (engine >= 0). ON by default because the module is inert until a pad is
  // actually connected AND has been interacted with, so it costs a disconnected player nothing.
  { "gamepad",           "Gamepad",           "Controls",  KIND_TOGGLE, -1,             0,   1,   1,   1,  "Use a connected controller (standard mapping). Sticks move and look; triggers mine and build.", NULL },
  { "gamepad_look_sensitivity", "Gamepad look speed", "Controls", KIND_RANGE, -1,     .25f,  3, .05f,  1,  "Right-stick look speed. Composes with mouse sensitivity.",        NULL },
  { "gamepad_deadzone",  "Gamepad deadzone",  "Controls",  KIND_RANGE,  -1,          .05f, .5f, .05f, .15f, "Ignore stick movement smaller than this. Raise it if the camera drifts on its own.", NULL },

  { "fov",               "Field of view",     "Video",     KIND_RANGE,  -1,            60, 110,   1,  80,  "Vertical FOV in degrees. 80 is the original.",                    NULL },
  { "display_mode",      "Display",           "Video",     KIND_ENUM,   -1,             0,   2,   1,   0,  "Fixed size, fit the window, or a fullscreen button.",             "Fixed,Fit window,Fullscreen" },
  // Audit item #6 (§4a/§4c.1-2): the drawable used to be pinned to 1136x640 with devicePixelRatio
  // never read at all, so on any modern display the game was a small buffer upscaled — permanently
  // blurry. These two rows are the knobs on the now-dynamic drawable that public/eden-st.html
  // computes (CSS box x min(devicePixelRatio, dpr_cap) x render_scale). Neither touches the
  // engine's 568x320 POINT space; see eden_set_drawable_size() in the GL shim.
  // Defaults reproduce "as sharp as the display allows, no supersampling": cap 2x, scale 100%.
  { "render_scale",      "Render scale",      "Video",     KIND_ENUM,   -1,             0,   3,   1,   2,  "Internal resolution. Lower is faster and softer; 100% matches the window.", "50%,75%,100%,125%" },
  { "dpr_cap",           "Max pixel ratio",   "Video",     KIND_ENUM,   -1,             0,   2,   1,   2,  "Upper limit on the display's pixel density. Lower it if the frame rate suffers.", "1x,1.5x,2x" },
  // Row #14: an opt-in frame-rate ceiling, mainly for thermal/battery on touch devices (a voxel
  // game at an uncapped rAF is a thermal-throttle machine there — perf-audit §4b). Uncapped is the
  // default for everyone; eden_apply_input_profile() below sets it to 60 the first time a touch
  // profile is detected AND the player has never explicitly touched this row.
  { "fps_cap",           "Frame rate cap",    "Video",     KIND_ENUM,   -1,             0,   3,   1,   0,  "Limit how fast the game renders. Lower saves battery/heat on touch devices.", "Uncapped,30,45,60" },

  { "crosshair",         "Crosshair",         "Interface", KIND_TOGGLE, -1,             0,   1,   1,   1,  "Reticle at screen centre while the mouse is locked.",             NULL },
  { "block_preview",     "Block preview",     "Interface", KIND_TOGGLE, -1,             0,   1,   1,   0,  "Translucent ghost of the block you are about to place. (B)",      NULL },
  // The escape hatch for the rebuilt DOM UI (public/eden-menu.js + public/eden-pausemenu.js). ON =
  // the original 2010 GL menus, which are still compiled and still running underneath — for the
  // MAIN menu "legacy" is literally "stop drawing the overlay" and there is no second code path to
  // keep alive. The IN-GAME menu needs one extra step in the other direction: its GL panel is
  // suppressed by default (eden_hud_draw_menu_screen_hook, installed in Menu_web.mm) because the
  // DOM panel no longer covers the whole canvas, so this flag both re-enables that panel and keeps
  // the DOM one closed. Read by eden_menu_active()/eden_legacy_ui_active() (Menu_web.mm), by
  // public/eden-menu.js's own poll, and by public/eden-pausemenu.js's tick().
  { "legacy_menu",       "Legacy UI",         "Interface", KIND_TOGGLE, -1,             0,   1,   1,   0,  "Use the original 2010 OpenGL menus — both the main menu and the in-game menu — instead of the rebuilt ones.", NULL },

  // Experiments: opt-in, off by default (except fly/fps_normalize, which keep their pre-existing
  // defaults now that they've moved tabs — only their group changed, not their behavior).
  { "fly",               "Fly mode",          "Experiments", KIND_TOGGLE, -1,           0,   1,   1,   0,  "Free flight. Space/Ctrl to rise and fall. (F)",                   NULL },
  { "fps_normalize",     "Frame-rate normalize", "Experiments", KIND_TOGGLE, -1,        0,   1,   1,   1,  "Keep walk speed the same at any refresh rate (PC audit F1).",     NULL },
  { "advanced_movement", "Advanced movement (bhop)", "Experiments", KIND_TOGGLE, -1,     0,   1,   1,   0,  "Opt-in: zero-delay bunny-hop and wheel-jump. Off by default.",    NULL },
  { "crouch",            "Crouch mode",       "Experiments", KIND_TOGGLE, -1,           0,   1,   1,   0,  "Adds a crouch key/button (halves hitbox height for 1-block gaps). Off by default.", NULL },
};
static const int kSettingCount = (int)(sizeof(kSettings) / sizeof(kSettings[0]));

static float g_value[kSettingCount];
static bool  g_loaded = false;
// Row #14: did NSUserDefaults actually have a value for this (port-owned) row at load time? Used
// by eden_apply_input_profile() to tell "the player explicitly chose this" apart from "still
// sitting at the compiled default" — profile-driven defaults must only ever touch the latter,
// mirroring input_mode's own Auto/explicit arbitration (this file's header comment on Phase 2).
static bool  g_hadStored[kSettingCount];

static int eden_setting_index(const char* key) {
    for (int i = 0; i < kSettingCount; ++i)
        if (std::strcmp(kSettings[i].key, key) == 0) return i;
    return -1;
}

// Port-owned values the rest of the port reads. Declared in Input_web.mm / consumed by the
// gluPerspective wrap below.
float eden_look_sensitivity = 1.0f;   // read by eden_apply_look_delta
float eden_fov_degrees      = 80.0f;  // read by __wrap_gluPerspective
// PC controls audit F1/F2 (Movement_web.mm's --wrap of Player::setSpeed). Default ON; a toggle
// exists so stock (frame-time-dependent) feel can be A/B'd without a rebuild.
float eden_fps_normalize    = 1.0f;
// PC controls audit Phase 3/4/6 — plain mutable globals in the same style, read by
// Input_web.mm/eden-st.html.
float eden_mouse_sensitivity_y = 1.0f;   // read by eden_apply_look_delta (Y axis)
float eden_hold_to_act      = 1.0f;      // read by eden-st.html's hold-to-act state machine
float eden_crosshair        = 1.0f;      // read by eden-st.html's crosshair overlay
float eden_advanced_movement = 0.0f;     // read by Movement_web.mm's Phase 6 hook
float eden_display_mode     = 0.0f;      // 0=Fixed/1=Fit/2=Fullscreen-on-demand, read by eden-st.html
// Audit item #6. Stored as the ENUM INDEX (same as every other KIND_ENUM row); the getters below
// translate to the numbers the page actually wants, so the index<->value table lives in exactly
// one place instead of being duplicated in JS.
float eden_render_scale     = 2.0f;      // index into {50%,75%,100%,125%}
float eden_dpr_cap          = 2.0f;      // index into {1x,1.5x,2x}
float eden_fps_cap          = 0.0f;      // index into {Uncapped,30,45,60}; row #14
// Read by eden_menu_active() (Menu_web.mm) and public/eden-menu.js. 0 = the rebuilt DOM menu.
float eden_legacy_menu      = 0.0f;

// ---------------------------------------------------------------------------------------------
// Phase 2 — input mode: Auto(0) / Touch(1) / Keyboard+Mouse(2). "Auto" defers to whatever the
// page has detected so far (matchMedia at boot, then the first real touch/key/mouse event —
// see eden-st.html); a real touch or key event is unambiguous evidence, matchMedia's
// `pointer:coarse` is just the pre-interaction guess. `g_detectedTouch` is JS-owned state fed in
// through eden_set_detected_touch(); this file only arbitrates it against the user's explicit
// override (`input_mode` != Auto).
// ---------------------------------------------------------------------------------------------
static int  g_inputMode = 0;         // mirrors g_value[idx of "input_mode"], kept as an int too
static bool g_detectedTouch = false;

static void eden_apply_input_profile(void);

extern "C" {
EMSCRIPTEN_KEEPALIVE
int eden_effective_input_is_touch(void) {
    if (g_inputMode == 1) return 1;
    if (g_inputMode == 2) return 0;
    return g_detectedTouch ? 1 : 0;
}

EMSCRIPTEN_KEEPALIVE
void eden_set_detected_touch(int isTouch) {
    g_detectedTouch = (isTouch != 0);
    eden_apply_input_profile();
}

// Lets the DOM UI panels (eden-pausemenu.js, eden-settings.js — plain HTML buttons, no touch
// path through Hud::update) play the same click sounds the engine's own HUD menu icons got wired
// up to in Classes/Hud.mm (pass 39, S_MENU_BUTTON_PRESS/RELEASE). `pressed` nonzero = press,
// zero = release. Resources::getResources is a singleton set up once in World's constructor
// (Classes/World.mm) and outlives every menu/game-mode transition, so this is safe to call from
// either the main menu or in-game.
EMSCRIPTEN_KEEPALIVE
void eden_play_menu_button_sound(int pressed) {
    if (!Resources::getResources) return;
    Resources::getResources->playSound(pressed ? S_MENU_BUTTON_PRESS : S_MENU_BUTTON_RELEASE);
}

// Settings panel's boolean on/off switches ONLY (eden-settings.js's kind===0 rows) — deliberately
// separate from eden_play_menu_button_sound above. menu_button_press/release_01.mp3 (variation 01
// of that sound) is audibly different from variations 02-05 and was pulled out of that sound's
// random-variation pool (Classes/Resources.mm) specifically so it would stop turning up on
// ordinary button clicks; it now lives only here, as its own single-variation sound ID, for the
// one control it was asked to keep: switch toggles.
EMSCRIPTEN_KEEPALIVE
void eden_play_switch_toggle_sound(int on) {
    if (!Resources::getResources) return;
    Resources::getResources->playSound(on ? S_SWITCH_TOGGLE_ON : S_SWITCH_TOGGLE_OFF);
}
} // extern "C"

// Row #14 (perf-audit §4c.3): "profile-driven defaults, not profile-driven code paths." Runs once
// per session, the first time BOTH the settings model is loaded (so g_hadStored[] is meaningful)
// AND the input profile is actually resolved (Auto's g_detectedTouch has a real value, or the
// player forced one). Only ever adjusts a row the player has never explicitly touched (checked via
// g_hadStored — the same "explicit choice wins" rule input_mode itself already followed), and only
// ever the touch-shaped rows called out in the audit: dpr_cap and fps_cap (crosshair/block_preview
// already default to sane values for both profiles — see their schema rows and Section 4b — so
// there is nothing to override for them; render_scale is deliberately left alone since #6 already
// makes 100% scale cheap via the DPR cap, and lowering render quality by default is a felt change
// worth leaving to the player).
extern "C" void eden_settings_set(int i, float v);   // defined further down in this file
static bool g_profileDefaultsApplied = false;
static void eden_apply_profile_defaults(bool isTouch) {
    if (g_profileDefaultsApplied || !g_loaded) return;
    g_profileDefaultsApplied = true;
    if (!isTouch) return;   // desktop keeps every compiled default as-is
    int dpr_i = eden_setting_index("dpr_cap");
    if (dpr_i >= 0 && !g_hadStored[dpr_i]) eden_settings_set(dpr_i, 1.0f);   // 1.5x, not 2x
    int fps_i = eden_setting_index("fps_cap");
    if (fps_i >= 0 && !g_hadStored[fps_i]) eden_settings_set(fps_i, 3.0f);  // 60fps cap
}

static void eden_apply_input_profile(void) {
    if (!World::getWorld || !World::getWorld->hud) return;
    World::getWorld->hud->use_joystick = eden_effective_input_is_touch() ? TRUE : FALSE;
    eden_apply_profile_defaults(eden_effective_input_is_touch() != 0);
}

extern "C" void eden_set_block_preview(int on);
extern "C" void eden_set_fly_mode(int on);
extern "C" void eden_set_crouch_enabled(int on);

static SettingsMenu* eden_engine_settings(void) {
    if (!World::getWorld || !World::getWorld->menu) return NULL;
    return World::getWorld->menu->settings;
}

// ---------------------------------------------------------------------------------------------
// Applying one row. Engine rows are written into `properties[]` and committed with the engine's
// own save() (which re-runs load(), i.e. the engine's own apply step). Port rows act directly.
//
// The re-apply at the bottom is NOT belt-and-braces: `SettingsMenu::load()` unconditionally sets
// `player->invertcam = FALSE` and `hud->use_joystick = TRUE` every time it runs (Classes/
// SettingsMenu.mm:188-189 — hard-coded, not saved preferences). So committing ANY engine toggle
// silently reverts two of the port's own control settings unless they are re-applied afterwards.
// This is the same class of trap pass 23 hit with use_joystick and Joystick::update.
// ---------------------------------------------------------------------------------------------
static void eden_apply_port_settings(void);

static void eden_apply_setting(int i, bool commitEngine) {
    if (i < 0 || i >= kSettingCount) return;
    const Setting& s = kSettings[i];
    const float v = g_value[i];

    if (s.engine >= 0) {
        SettingsMenu* sm = eden_engine_settings();
        if (!sm) return;
        sm->properties[s.engine].value = (v != 0.0f) ? 1 : 0;
        if (!commitEngine) return;
        sm->save();                       // engine: writes NSUserDefaults, then load() applies
        // Music has one side effect save()/load() does not do: the menu tune has to be started or
        // stopped right now. Classes/SettingsMenu.mm:150-158 did this inline in its touch handler,
        // which is exactly the piece a wrapped-out update() would otherwise lose.
        if (s.engine == ENG_MUSIC && Resources::getResources) {
            if (v != 0.0f) Resources::getResources->playMenuTune();
            else           Resources::getResources->stopMenuTune();
        }
        eden_apply_port_settings();       // undo load()'s invertcam/use_joystick stomp
        return;
    }

    if (std::strcmp(s.key, "block_preview") == 0) {
        eden_set_block_preview(v != 0.0f ? 1 : 0);
    } else if (std::strcmp(s.key, "fly") == 0) {
        eden_set_fly_mode(v != 0.0f ? 1 : 0);
    } else if (std::strcmp(s.key, "crouch") == 0) {
        eden_set_crouch_enabled(v != 0.0f ? 1 : 0);
    } else if (std::strcmp(s.key, "mouse_sensitivity") == 0) {
        eden_look_sensitivity = v;
    } else if (std::strcmp(s.key, "fov") == 0) {
        eden_fov_degrees = v;
    } else if (std::strcmp(s.key, "fps_normalize") == 0) {
        eden_fps_normalize = v;
    } else if (std::strcmp(s.key, "hold_to_act") == 0) {
        eden_hold_to_act = v;
    } else if (std::strcmp(s.key, "mouse_sensitivity_y") == 0) {
        eden_mouse_sensitivity_y = v;
    } else if (std::strcmp(s.key, "crosshair") == 0) {
        eden_crosshair = v;
    } else if (std::strcmp(s.key, "advanced_movement") == 0) {
        eden_advanced_movement = v;
    } else if (std::strcmp(s.key, "display_mode") == 0) {
        eden_display_mode = v;
    } else if (std::strcmp(s.key, "render_scale") == 0) {
        eden_render_scale = v;
    } else if (std::strcmp(s.key, "dpr_cap") == 0) {
        eden_dpr_cap = v;
    } else if (std::strcmp(s.key, "fps_cap") == 0) {
        eden_fps_cap = v;
    } else if (std::strcmp(s.key, "legacy_menu") == 0) {
        eden_legacy_menu = v;
    } else if (std::strcmp(s.key, "input_mode") == 0) {
        g_inputMode = (int)lroundf(v);
        eden_apply_input_profile();
    } else if (std::strcmp(s.key, "invert_look") == 0) {
        if (World::getWorld && World::getWorld->player)
            World::getWorld->player->invertcam = (v != 0.0f) ? TRUE : FALSE;
    } else if (std::strcmp(s.key, "music_volume") == 0) {
        if (CocosDenshion::SimpleAudioEngine::sharedEngine())
            CocosDenshion::SimpleAudioEngine::sharedEngine()->setBackgroundMusicVolume(v);
    } else if (std::strcmp(s.key, "ambience_volume") == 0) {
        if (CocosDenshion::SimpleAudioEngine::sharedEngine())
            CocosDenshion::SimpleAudioEngine::sharedEngine()->setAmbienceVolume(v);
    } else if (std::strcmp(s.key, "effects_volume") == 0) {
        if (CocosDenshion::SimpleAudioEngine::sharedEngine())
            CocosDenshion::SimpleAudioEngine::sharedEngine()->setEffectsVolume(v);
    } else if (std::strcmp(s.key, "touch_controls_sound") == 0) {
        extern bool touchControlsSoundEnabled;
        touchControlsSoundEnabled = (v != 0.0f);
    }
}

static void eden_apply_port_settings(void) {
    for (int i = 0; i < kSettingCount; ++i)
        if (kSettings[i].engine < 0) eden_apply_setting(i, false);
}

// Port rows persist here; engine rows persist through SettingsMenu::save(). Both end up in
// NSUserDefaults, which is localStorage-backed (pass 28) — one store, one lifetime.
static void eden_persist_setting(int i) {
    if (kSettings[i].engine >= 0) return;   // owned by SettingsMenu::save()
    NSUserDefaults* prefs = [NSUserDefaults standardUserDefaults];
    NSString* key = [NSString stringWithUTF8String:kSettings[i].key];
    // Stored as an int in thousandths so one NSNumber type covers toggles and ranges alike (the
    // NSUserDefaults shim persists NSNumber only — see its header comment).
    [prefs setObject:[NSNumber numberWithInt:(int)lroundf(g_value[i] * 1000.0f)] forKey:key];
    [prefs synchronize];
}

extern "C" {

// Called once the world exists. Seeds every row: engine rows FROM the engine (SettingsMenu's ctor
// has already run its own load()), port rows from NSUserDefaults, then applies the port half.
EMSCRIPTEN_KEEPALIVE
void eden_settings_init(void) {
    if (g_loaded) return;
    SettingsMenu* sm = eden_engine_settings();
    if (!sm) return;                        // too early; caller retries next frame
    g_loaded = true;

    NSUserDefaults* prefs = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < kSettingCount; ++i) {
        if (kSettings[i].engine >= 0) {
            g_value[i] = (float)sm->properties[kSettings[i].engine].value;
            continue;
        }
        g_value[i] = kSettings[i].def;
        NSString* key = [NSString stringWithUTF8String:kSettings[i].key];
        id stored = [prefs objectForKey:key];
        g_hadStored[i] = (stored != nil);
        if (stored) g_value[i] = [(NSNumber*)stored intValue] / 1000.0f;
    }
    // Migration (Phase 2): "touch_joystick" was an independent toggle before input_mode existed
    // (pass 28-30). If a player had explicitly turned it ON and never saw an "input_mode" pref
    // (i.e. this is their first run since the upgrade), honor that as an explicit Touch choice
    // rather than silently reverting them to Auto-detect. Reads the OLD key directly since its
    // row no longer exists in kSettings[].
    {
        int input_mode_i = eden_setting_index("input_mode");
        if (input_mode_i >= 0 &&
            [prefs objectForKey:[NSString stringWithUTF8String:"input_mode"]] == nil) {
            id oldTouch = [prefs objectForKey:[NSString stringWithUTF8String:"touch_joystick"]];
            if (oldTouch && [(NSNumber*)oldTouch intValue] > 0) g_value[input_mode_i] = 1.0f;
        }
    }
    eden_apply_port_settings();
}

// Has eden_settings_init() actually run yet? It needs the World to exist, so it happens some
// frames after module init — later than the page's own boot sizing pass. public/eden-st.html uses
// this as a one-shot edge to re-derive the drawable from the RESTORED render_scale/dpr_cap
// (item #6); without it a persisted non-default value only took effect on the first resize.
EMSCRIPTEN_KEEPALIVE
int eden_settings_loaded(void) { return g_loaded ? 1 : 0; }

// The panel's whole data model, as JSON. One string rather than an accessor per field so the C
// table above stays the single source of truth and the JS never hard-codes a row.
EMSCRIPTEN_KEEPALIVE
const char* eden_settings_schema(void) {
    static char buf[6144];
    int n = 0;
    n += snprintf(buf + n, sizeof(buf) - n, "[");
    for (int i = 0; i < kSettingCount && n < (int)sizeof(buf) - 1; ++i) {
        const Setting& s = kSettings[i];
        n += snprintf(buf + n, sizeof(buf) - n,
            "%s{\"i\":%d,\"key\":\"%s\",\"label\":\"%s\",\"group\":\"%s\",\"kind\":%d,"
            "\"min\":%g,\"max\":%g,\"step\":%g,\"hint\":%s%s%s,\"options\":%s%s%s}",
            i ? "," : "", i, s.key, s.label, s.group, s.kind, s.min, s.max, s.step,
            s.hint ? "\"" : "", s.hint ? s.hint : "null", s.hint ? "\"" : "",
            s.options ? "\"" : "", s.options ? s.options : "null", s.options ? "\"" : "");
    }
    snprintf(buf + n, sizeof(buf) - n, "]");
    return buf;
}

EMSCRIPTEN_KEEPALIVE
float eden_settings_get(int i) {
    if (i < 0 || i >= kSettingCount) return 0.0f;
    return g_value[i];
}

EMSCRIPTEN_KEEPALIVE
void eden_settings_set(int i, float v) {
    if (i < 0 || i >= kSettingCount) return;
    const Setting& s = kSettings[i];
    if (v < s.min) v = s.min;
    if (v > s.max) v = s.max;
    g_value[i] = v;
    g_hadStored[i] = true;   // an explicit change now counts the same as a persisted one (row #14)
    eden_apply_setting(i, true);
    eden_persist_setting(i);
}

// Convenience for the port's own keyboard shortcuts (B, F): keeps the key and the panel in sync
// instead of each writing its own copy of the state. Index-based, NOT key-based, deliberately —
// passing a C string in from JS would need `_malloc`/`_free` added to the export list, and the JS
// side already holds the schema (which carries every key -> index mapping) for free.
EMSCRIPTEN_KEEPALIVE
float eden_settings_toggle(int i) {
    if (i < 0 || i >= kSettingCount) return 0.0f;
    eden_settings_set(i, g_value[i] != 0.0f ? 0.0f : 1.0f);
    return g_value[i];
}

// Is the ENGINE currently in its settings state? `Menu::showsettings` is the main menu's Options
// button (Classes/Menu.mm:534). Polled from JS so the panel opens for the engine's own button
// without the port having to hit-test that button itself.
EMSCRIPTEN_KEEPALIVE
int eden_settings_menu_open(void) {
    if (!World::getWorld || !World::getWorld->menu) return 0;
    return World::getWorld->menu->showsettings ? 1 : 0;
}

EMSCRIPTEN_KEEPALIVE
void eden_settings_menu_close(void) {
    if (!World::getWorld || !World::getWorld->menu) return;
    World::getWorld->menu->showsettings = FALSE;
    SettingsMenu* sm = eden_engine_settings();
    if (sm) { sm->save(); eden_apply_port_settings(); }
    // Menu::update returned early for every frame the panel was up, so any touch that was live
    // when it opened is still sitting in the slot table with a stale `inuse`. Clear the lot rather
    // than let the main menu act on a press that belonged to the panel.
    Input::getInput()->clearAll();
}

// Opens the engine's settings state from the port side (the in-game gear button). Only meaningful
// in the menu; in game the panel is shown by the JS on its own and this is not called.
EMSCRIPTEN_KEEPALIVE
void eden_settings_menu_open_now(void) {
    if (!World::getWorld || !World::getWorld->menu) return;
    World::getWorld->menu->showsettings = TRUE;
}

// Plain getters for the port-owned globals eden-st.html polls every frame (crosshair visibility,
// hold-to-act repeat, fullscreen/fit mode, the Phase 6 opt-in). Cheaper and simpler for a
// polled-every-frame value than round-tripping through the schema's key->index lookup each time —
// that path is for the settings PANEL, which only needs it once per open.
EMSCRIPTEN_KEEPALIVE
int eden_get_hold_to_act(void) { return eden_hold_to_act != 0.0f; }
EMSCRIPTEN_KEEPALIVE
int eden_get_crosshair(void) { return eden_crosshair != 0.0f; }
EMSCRIPTEN_KEEPALIVE
int eden_get_display_mode(void) { return (int)lroundf(eden_display_mode); }
EMSCRIPTEN_KEEPALIVE
int eden_get_advanced_movement(void) { return eden_advanced_movement != 0.0f; }

// Audit item #6. Returned as integer percent / hundredths rather than floats so the page does no
// index->value mapping of its own (the tables below are the only copy). Out-of-range indexes fall
// back to the neutral entry, not to a clamp: a stale persisted index from a future build should
// look like "default", not like "50%".
EMSCRIPTEN_KEEPALIVE
int eden_get_render_scale_pct(void) {
    static const int kPct[] = {50, 75, 100, 125};
    int i = (int)lroundf(eden_render_scale);
    if (i < 0 || i >= (int)(sizeof(kPct) / sizeof(kPct[0]))) return 100;
    return kPct[i];
}
EMSCRIPTEN_KEEPALIVE
int eden_get_dpr_cap_x100(void) {
    static const int kCap[] = {100, 150, 200};
    int i = (int)lroundf(eden_dpr_cap);
    if (i < 0 || i >= (int)(sizeof(kCap) / sizeof(kCap[0]))) return 200;
    return kCap[i];
}

// Row #14. Read every rAF tick by eden_main.cpp's frame gate — plain int, not a bool getter, since
// 0 means "uncapped" and any other value IS the target fps, no separate on/off flag needed.
EMSCRIPTEN_KEEPALIVE
int eden_get_fps_cap(void) {
    static const int kFps[] = {0, 30, 45, 60};
    int i = (int)lroundf(eden_fps_cap);
    if (i < 0 || i >= (int)(sizeof(kFps) / sizeof(kFps[0]))) return 0;
    return kFps[i];
}

// ---------------------------------------------------------------------------------------------
// --wrap: the old GL settings panel. See this file's header for why both halves are neutralised
// rather than the class being seam-replaced wholesale.
// ---------------------------------------------------------------------------------------------
void __real__ZN12SettingsMenu6updateEf(SettingsMenu* self, float etime);
void __wrap__ZN12SettingsMenu6updateEf(SettingsMenu* self, float etime) {
    (void)self; (void)etime;   // the DOM panel owns this input now
}

void __real__ZN12SettingsMenu6renderEv(SettingsMenu* self);
void __wrap__ZN12SettingsMenu6renderEv(SettingsMenu* self) {
    (void)self;                // ...and this pixel area; Menu::render still draws menu_back under it
}

// --wrap: FOV. `Classes/Graphics.mm:370` hard-codes `gluPerspective(80, ...)` and there is no
// engine-side setting for it, but gluPerspective itself lives in Classes/project.c (the vendored
// GLU port) — a different translation unit, so the call is interceptable. Graphics::prepareScene
// is the only live caller (grep: the other two mentions are commented out), so overriding fovy
// unconditionally is safe. Picking follows for free: Util.mm's unproject reads the resulting
// projection matrix back with glGetFloatv rather than assuming 80 degrees.
void __real_gluPerspective(double fovy, double aspect, double zNear, double zFar);
void __wrap_gluPerspective(double fovy, double aspect, double zNear, double zFar) {
    (void)fovy;
    __real_gluPerspective((double)eden_fov_degrees, aspect, zNear, zFar);
}

}  // extern "C"
