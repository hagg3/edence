// DebugState_web.mm — TEMPORARY debug probe for the "menu layout is broken" investigation
// (web/docs/PORT-STATUS.md "Known open issue: menu layout", opened Pass 18).
//
// *** DELETE THIS FILE (and its CMakeLists.txt EDEN_SEAM_SOURCES entry) once the layout bug is
// fixed or the investigation moves on. *** It exists only so a live browser session can read
// Menu.mm's actual runtime rect/flag state directly via JS, instead of inferring state from
// screenshots (Pass 20 hit a false positive doing the latter — see PORT-STATUS.md "Pass 20").
// Same "temporary probe, delete after" pattern as Pass 17/18's throwaway fprintf instrumentation.
//
// Exposed as EMSCRIPTEN_KEEPALIVE `eden_debug_menu_state()`, callable from JS as
// `UTF8ToString(Module._eden_debug_menu_state())` — returns a static buffer (not exported
// dynamically, single string, single frame use — no ownership/free story needed, matches this
// port's other simple debug exports).
#import "../shim/foundation/uikit_stubs.h"
#include "../../../Classes/World.h"
#include "../../../Classes/Globals.h"
#include "../../../Classes/Input.h"
#include "../../../Classes/Constants.h"       // NUM_CREATURES, for the pass-27 model probe
#include "../../../Classes/PVRTModelPOD.h"    // CPVRTModelPOD, ditto
#include "../../../Classes/Resources.h"       // audit row 11 (A5) recolor probe
#include <emscripten/emscripten.h>
#include <cstdio>

// Globals.mm-only (not declared in Globals.h — Pass 16 already ran into this for the same reason).
extern BOOL IS_WIDESCREEN;

extern "C" {

// Pass 23 addition: player/hud state for headlessly verifying the new desktop keyboard/mouse
// controls (web/src/seam/Input_web.mm) — same "TEMPORARY, delete with this file" status as the
// rest of this probe.
EMSCRIPTEN_KEEPALIVE
const char* eden_debug_player_state(void) {
    static char buf[512];
    if (!World::getWorld || !World::getWorld->player || !World::getWorld->hud) {
        snprintf(buf, sizeof(buf), "{\"error\":\"no World/Player/Hud yet\"}");
        return buf;
    }
    Player* p = World::getWorld->player;
    Hud* h = World::getWorld->hud;
    snprintf(buf, sizeof(buf),
        "{"
        "\"pos\":[%.3f,%.3f,%.3f],\"yaw\":%.3f,\"pitch\":%.3f,"
        "\"walk_force\":[%.3f,%.3f,%.3f],\"max_walk_speed\":%.3f,"
        "\"hud_mode\":%d,\"blocktype\":%d"
        "}",
        p->pos.x, p->pos.y, p->pos.z, p->yaw, p->pitch,
        p->walk_force.x, p->walk_force.y, p->walk_force.z, p->max_walk_speed,
        h->mode, h->blocktype);
    return buf;
}

// Pass 27 addition: did the creature PODs actually load, and is anything alive to draw?
// `models[]` and `model_render_count` are plain globals in Classes/Model.mm (not file-static), so
// they can be read from here. This is the headless proof that the GL_OES_matrix_palette emulation
// worked end to end: nNumMesh > 0 means LoadModels() got past its extension gate AND
// ReadFromFile() succeeded for that creature. Same "TEMPORARY, delete with this file" status.
EMSCRIPTEN_KEEPALIVE
const char* eden_debug_model_state(void) {
    static char buf[512];
    extern CPVRTModelPOD models[];
    extern int model_render_count;
    int n = 0;
    n += snprintf(buf + n, sizeof(buf) - n, "{\"nNumMesh\":[");
    for (int i = 0; i < NUM_CREATURES; ++i)
        n += snprintf(buf + n, sizeof(buf) - n, "%s%u", i ? "," : "", models[i].nNumMesh);
    n += snprintf(buf + n, sizeof(buf) - n, "],\"nNumFrame\":[");
    for (int i = 0; i < NUM_CREATURES; ++i)
        n += snprintf(buf + n, sizeof(buf) - n, "%s%u", i ? "," : "", models[i].nNumFrame);
    snprintf(buf + n, sizeof(buf) - n, "],\"render_count\":%d}", model_render_count);
    return buf;
}

// Pass 27 addition: the in-game menu's button rects, so a headless drive can tap "exit to menu"
// (the only path that reaches World::exitToMenu -> UnloadModels) through the real touch path.
// Rects are in itouch's bottom-left-origin, Y-up space. TEMPORARY, same as the rest of this file.
EMSCRIPTEN_KEEPALIVE
const char* eden_debug_hud_rects(void) {
    static char buf[256];
    if (!World::getWorld || !World::getWorld->hud) { snprintf(buf, sizeof(buf), "{}"); return buf; }
    Hud* h = World::getWorld->hud;
    snprintf(buf, sizeof(buf), "{\"rexit\":[%.2f,%.2f,%.2f,%.2f],\"rhome\":[%.2f,%.2f,%.2f,%.2f]}",
             h->rexit.origin.x, h->rexit.origin.y, h->rexit.size.width, h->rexit.size.height,
             h->rhome.origin.x, h->rhome.origin.y, h->rhome.size.width, h->rhome.size.height);
    return buf;
}

EMSCRIPTEN_KEEPALIVE
const char* eden_debug_menu_state(void) {
    static char buf[3072];
    if (!World::getWorld || !World::getWorld->menu) {
        snprintf(buf, sizeof(buf), "{\"error\":\"no World/Menu yet\"}");
        return buf;
    }
    Menu* m = World::getWorld->menu;
    int worldCount = 0;
    for (WorldNode* n = m->world_list; n != NULL; n = n->next) worldCount++;
    const char* selName = (m->selected_world && m->selected_world->display_name)
        ? [m->selected_world->display_name UTF8String] : "";

    itouch* touches = Input::getInput()->getTouches();
    char touchBuf[1280];
    int tn = 0;
    tn += snprintf(touchBuf + tn, sizeof(touchBuf) - tn, "[");
    for (int i = 0; i < MAX_TOUCHES; i++) {
        tn += snprintf(touchBuf + tn, sizeof(touchBuf) - tn,
            "%s{\"mx\":%d,\"my\":%d,\"inuse\":%d,\"down\":%d,\"moved\":%d,"
            // pass 27: previewtype/preview/etime are what Player::render gates the translucent
            // ghost block on — the only way to see the block-preview toggle working headlessly.
            "\"previewtype\":%d,\"preview\":[%d,%d,%d],\"etime\":%.3f}",
            i ? "," : "", touches[i].mx, touches[i].my, touches[i].inuse,
            touches[i].down, touches[i].moved, touches[i].previewtype,
            touches[i].preview.x, touches[i].preview.y, touches[i].preview.z,
            touches[i].etime);
    }
    snprintf(touchBuf + tn, sizeof(touchBuf) - tn, "]");

    snprintf(buf, sizeof(buf),
        "{"
        "\"SCREEN_WIDTH\":%.3f,\"SCREEN_HEIGHT\":%.3f,"
        "\"SCALE_WIDTH\":%.3f,\"SCALE_HEIGHT\":%.3f,"
        "\"IS_IPAD\":%d,\"IS_RETINA\":%d,\"IS_WIDESCREEN\":%d,\"SUPPORTS_RETINA\":%d,"
        "\"showsettings\":%d,\"showlistscreen\":%d,\"is_sharing\":%d,\"loading\":%d,"
        "\"loading_world_list\":%d,"
        "\"delete_mode\":%d,\"selected_world_ptr\":\"%p\",\"selected_world_name\":\"%s\","
        "\"world_count\":%d,"
        "\"rect_options\":[%.2f,%.2f,%.2f,%.2f],"
        "\"rect_create\":[%.2f,%.2f,%.2f,%.2f],"
        "\"rect_delete\":[%.2f,%.2f,%.2f,%.2f],"
        "\"rect_share\":[%.2f,%.2f,%.2f,%.2f],"
        "\"rect_loadshared\":[%.2f,%.2f,%.2f,%.2f],"
        "\"left_arrow\":[%.2f,%.2f,%.2f,%.2f],"
        "\"right_arrow\":[%.2f,%.2f,%.2f,%.2f],"
        "\"selected_world_rect\":[%.2f,%.2f,%.2f,%.2f],"
        "\"doneLoading\":%d,\"game_mode\":%d,"
        "\"touches\":%s"
        "}",
        SCREEN_WIDTH, SCREEN_HEIGHT,
        SCALE_WIDTH, SCALE_HEIGHT,
        (int)IS_IPAD, (int)IS_RETINA, (int)IS_WIDESCREEN, (int)SUPPORTS_RETINA,
        (int)m->showsettings, (int)m->showlistscreen, m->is_sharing, m->loading,
        m->loading_world_list,
        (int)m->delete_mode, (void*)m->selected_world, selName,
        worldCount,
        m->rect_options.origin.x, m->rect_options.origin.y,
        m->rect_options.size.width, m->rect_options.size.height,
        m->rect_create.origin.x, m->rect_create.origin.y,
        m->rect_create.size.width, m->rect_create.size.height,
        m->rect_delete.origin.x, m->rect_delete.origin.y,
        m->rect_delete.size.width, m->rect_delete.size.height,
        m->rect_share.origin.x, m->rect_share.origin.y,
        m->rect_share.size.width, m->rect_share.size.height,
        m->rect_loadshared.origin.x, m->rect_loadshared.origin.y,
        m->rect_loadshared.size.width, m->rect_loadshared.size.height,
        m->left_arrow.origin.x, m->left_arrow.origin.y,
        m->left_arrow.size.width, m->left_arrow.size.height,
        m->right_arrow.origin.x, m->right_arrow.origin.y,
        m->right_arrow.size.width, m->right_arrow.size.height,
        m->selected_world ? m->selected_world->rect.origin.x : -1,
        m->selected_world ? m->selected_world->rect.origin.y : -1,
        m->selected_world ? m->selected_world->rect.size.width : -1,
        m->selected_world ? m->selected_world->rect.size.height : -1,
        World::getWorld->doneLoading, World::getWorld->game_mode,
        touchBuf);
    return buf;
}

// TEMPORARY (pass 23, delete with the rest of this probe): reports the raw engine heap pointers.
// Hunting a low-memory zero-fill that clobbers emscripten's stack cookie the instant a world
// loads: Terrain::clearBlocks / updateLightingBegin memset lightarray unconditionally, so a
// failed malloc would splatter ~16 MB of zeros starting at address 0.
EMSCRIPTEN_KEEPALIVE
extern "C" const char *eden_debug_alloc_state(void) {
    extern block8 *blockarray;
    extern Vector8 *lightarray;
    static char buf[256];
    snprintf(buf, sizeof(buf),
             "{\"blockarray\":%u,\"lightarray\":%u,\"lightarray_bytes\":%u}",
             (unsigned)(uintptr_t)blockarray, (unsigned)(uintptr_t)lightarray,
             (unsigned)(sizeof(Vector8) * T_SIZE * T_SIZE * T_HEIGHT));
    return buf;
}

// Audit row 11 (A5) regression probe. The recolor pipeline is entirely invisible from the outside
// — its failure mode is a Texture2D whose GL `name` stayed 0, which draws as nothing and reports
// no error — so there is no way to assert it from a headless harness without asking the engine
// directly. Reports, for one paint colour, whether each input image survived load and whether the
// recolored texture actually got a GL name. `stored_*` being 0 means initFromPath's storeImage
// block didn't fire (asset missing, or the positional classification drifted); `paint_tex` being 0
// with both inputs present means ManipulateImagePixelData returned null.
//
// Colour 0 is deliberately rejected: Resources::getPaintTex short-circuits it to the plain
// ICO_PAINT atlas texture and never reaches the recolor at all, so probing it would pass whether
// or not the pipeline works. tools/headless-recolor-test.js drives this.
EMSCRIPTEN_KEEPALIVE
extern "C" const char *eden_debug_recolor_state(int color) {
    static char buf[512];
    extern int realStoredSkinCounter;
    extern int storedMaskCounter;
    extern UIImage *storedPaint;
    extern UIImage *storedPaintMask;
    extern UIImage *storedDoor;
    extern UIImage *storedDoorMask;
    if (!Resources::getResources || color <= 0) {
        snprintf(buf, sizeof(buf), "{\"error\":\"no Resources, or color<=0 (see comment)\"}");
        return buf;
    }
    CGImageRef paintCG = [storedPaint CGImage];
    CGImageRef maskCG = [storedPaintMask CGImage];
    Texture2D *paintTex = Resources::getResources->getPaintTex(color);
    int doorTex = Resources::getResources->getDoorTex(color);

    // The creature half of the same pipeline. These two 5x2 tables are filled POSITIONALLY (the
    // Nth texture load since Resources::loadResources zeroed the counter), which is the part most
    // likely to drift silently if anyone reorders a texture load — a wrong count here means
    // creatures get each other's skins, with nothing else to notice it by.
    extern UIImage *storedSkins[5][2];
    extern UIImage *storedMasks[5][2];
    int skinsFilled = 0, masksFilled = 0;
    for (int m = 0; m < 5; m++) {
        for (int s = 0; s < 2; s++) {
            if (storedSkins[m][s] != nil) skinsFilled++;
            if (storedMasks[m][s] != nil) masksFilled++;
        }
    }

    snprintf(buf, sizeof(buf),
             "{\"color\":%d,\"stored_paint\":%d,\"stored_paint_mask\":%d,"
             "\"stored_door\":%d,\"stored_door_mask\":%d,"
             "\"paint_w\":%d,\"paint_h\":%d,\"mask_w\":%d,\"mask_h\":%d,"
             "\"paint_tex\":%u,\"door_tex\":%d,"
             "\"skins_filled\":%d,\"masks_filled\":%d,\"skin_counter\":%d,\"mask_counter\":%d}",
             color, storedPaint != nil, storedPaintMask != nil,
             storedDoor != nil, storedDoorMask != nil,
             paintCG ? paintCG->width : -1, paintCG ? paintCG->height : -1,
             maskCG ? maskCG->width : -1, maskCG ? maskCG->height : -1,
             paintTex ? (unsigned)paintTex->name : 0u, doorTex,
             skinsFilled, masksFilled, realStoredSkinCounter, storedMaskCounter);
    return buf;
}

} // extern "C"
