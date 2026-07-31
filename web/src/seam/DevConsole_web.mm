// DevConsole_web.mm — project-audit-2026-07-30 row F5 ("dev console: teleport, spawn, world
// stats"), requested from play rather than analysis (audit rows 31/33). Gated behind
// EDEN_DIAGNOSTICS (same CMakeLists.txt list as DebugState_web.mm) so it never ships in a build
// meant to be played — teleporting/spawning at will has no place outside a debugging session.
//
// Plain C exports, same "static buffer, single frame use" convention as DebugState_web.mm's
// probes — no _malloc/_free needed (Settings_web.mm's eden_settings_schema() established this
// pattern first). The console UI itself lives in public/eden-console.js, toggled by backtick;
// it feature-detects these exports (`typeof Module._eden_console_teleport === 'function'`)
// rather than checking a build flag from JS, so it silently doesn't appear on an
// EDEN_DIAGNOSTICS=OFF build without either side needing to know the other's config.
#import "../shim/foundation/uikit_stubs.h"
#include "../../../Classes/World.h"
#include "../../../Classes/Constants.h"
#include "../../../Classes/Model.h"
#include <emscripten/emscripten.h>
#include <cstdio>

extern "C" {

// tp x y z — Vector convention (y UP, per CLAUDE.md #1 "Vector.y is up"), NOT Terrain's (x,z,y)
// argument order — this writes Player::pos directly, so it takes exactly what that field expects.
// No bounds/collision check: a console teleport is allowed to put the player somewhere the normal
// game never would (e.g. outside the resident toroidal window), same as it would in any game with
// a noclip-style teleport.
EMSCRIPTEN_KEEPALIVE
int eden_console_teleport(float x, float y, float z) {
    if (!World::getWorld || !World::getWorld->player) return 0;
    Player* p = World::getWorld->player;
    p->pos.x = x;
    p->pos.y = y;
    p->pos.z = z;
    p->vel.x = p->vel.y = p->vel.z = 0;  // a stale velocity would immediately walk the player off
    return 1;
}

// spawn <type> — places a creature of the given TYPE_* / M_* model index at the player's current
// position via Model.mm's SpawnCreatureAt (Classes/ edit, same commit as this file — see
// web/docs/entities-and-creatures.md), which reuses the ambient spawner's own slot-scavenging and
// field setup rather than duplicating it here.
EMSCRIPTEN_KEEPALIVE
int eden_console_spawn(int type) {
    if (!World::getWorld || !World::getWorld->player) return 0;
    return SpawnCreatureAt(type, World::getWorld->player->pos) ? 1 : 0;
}

// setblock x z y type — Terrain's own (x,z,y) argument order (CLAUDE.md #1), NOT Vector's.
// Calls Terrain::updateChunks, the same dirty-marking entry point Player::processInput's
// buildBlock eventually reaches (CLAUDE.md's "Trace a block edit"), skipping only buildBlock's
// own HUD-coupled side effects (golden-cube inventory, liquid sources, ramp/door orientation
// inference) that a console-driven edit has no HUD state to draw from. This is what makes a
// block edit possible from a script with no camera/raycast — added alongside the other three
// console commands to give tools/headless-save-roundtrip-test.js (audit row I6) something
// deterministic to edit before it saves, since a pristine unedited world has NO block data of
// its own to round-trip (unmodified terrain streams from the bundled Eden.eden by seed, per
// docs/eden-file-format.md — only touched columns are ever appended to a save file).
EMSCRIPTEN_KEEPALIVE
int eden_console_setblock(int x, int z, int y, int type) {
    if (!World::getWorld || !World::getWorld->terrain) return 0;
    World::getWorld->terrain->updateChunks(x, z, y, type);
    return 1;
}

// stats — read-only snapshot for the console's "stats" command. Static buffer, JSON, same
// convention as DebugState_web.mm's probes and Settings_web.mm's schema export.
EMSCRIPTEN_KEEPALIVE
const char* eden_console_world_stats(void) {
    static char buf[512];
    if (!World::getWorld || !World::getWorld->player || !World::getWorld->fm) {
        snprintf(buf, sizeof(buf), "{\"error\":\"no World yet\"}");
        return buf;
    }
    Player* p = World::getWorld->player;
    FileManager* fm = World::getWorld->fm;
    snprintf(buf, sizeof(buf),
        "{"
        "\"pos\":[%.2f,%.2f,%.2f],\"chunk_offset\":[%d,%d],"
        "\"active_creatures\":%d,\"game_mode\":%d"
        "}",
        p->pos.x, p->pos.y, p->pos.z, fm->chunkOffsetX, fm->chunkOffsetZ,
        CountActiveCreatures(), World::getWorld->game_mode);
    return buf;
}

} // extern "C"
