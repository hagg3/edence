# Player, Input & Camera

## Purpose
Touch handling, the block-pick raycast, player physics/collision, and the camera.

## Important files
- `Classes/Input.mm/.h` — raw touch bookkeeping (5-slot `itouch` array).
- `Classes/Player.mm` (2096 lines) — input interpretation, physics, block editing,
  portals, damage. The single biggest gameplay file.
- `Classes/Util.mm` — `findWorldCoords` raycast, SAT polyhedra collision
  (`collidePolyhedra`, `makeBox/makeRamp/makeSide`), math helpers.
- `Classes/Camera.mm` — view matrix.
- `Classes/Joystick.mm` — virtual stick used by the HUD.

## Input layer (`Input.mm`)
`EAGLView` forwards `touchesBegan/Moved/Ended/Cancelled` to the `Input` singleton,
which maintains `touches[5]` slots keyed by `UITouch*`:
current/previous/first positions (`mx/my`, `pmx/pmy`, `fx/fy`), `down` state
(`M_DOWN/M_RELEASE/M_NONE`), `moved`, `movecam` (was this touch dragging the camera),
per-touch block preview state, and hold time `etime`. Consumers (Hud buttons, Player,
Menu) poll this array every frame — there is no event dispatch. `clearAll()` resets on
world load. `keyTyped` feeds the custom GL keyboard (`VKeyboard`).

Coordinates arrive in screen points; note the axis swap when they reach the raycast
(`findWorldCoords` swaps mx/my and scales by `SCALE_*` on "iPad"/Retina).

## Block picking — `findWorldCoords(mx, my, mode)` (`Util.mm:566`)
1. Rebuilds the camera matrix, `gluUnProject`s the touch at depth 0 and 1 → ray.
2. Marches the ray in 1/8-block steps up to 15 blocks.
3. Each step first tests creatures (`PointTestModels`) — a hit stores the creature
   index in the global `fwc_result` and returns.
4. For terrain: precise polyhedron test against the block's actual shape
   (ramps/sides/liquid levels get their real geometry, not a full cube).
5. `FC_PLACE` returns the last *empty* cell before the hit (stored via `offsetdir`
   logic); `FC_DESTROY` returns the hit cell.
Globals `fwc_result` (creature hit index) and `fpoint` (exact hit point) carry side
results — callers read them immediately after the call.

## Player (`Player.mm`)

### Update pipeline (`preupdate` → `processInput` → `update` → `move` → collisions)
- **`processInput`** (`:155`): walks the touch slots. Touches on HUD controls were
  already consumed by `Hud::update` (which sets `inuse`). Remaining logic:
  - Short tap (not moved, released quickly) in BUILD/MINE/PAINT/BURN mode →
    raycast → `terrain->buildBlock/destroyBlock/paintBlock/burnBlock` (with a
    collision pre-check so you can't build inside yourself: `Player::test` collides
    the candidate block's polyhedron against the player's box).
  - Drag → camera look (`yaw += dx·YAW_SPEED`, `pitch += dy·PITCH_SPEED`,
    optionally inverted; pitch clamped).
  - "Jump and build" assist (`jumpandbuild`) places a block underneath after a jump
    when building below your feet. (There is no long-press-repeat for mine/paint —
    a prior version of this doc claimed one; verified against the code during the
    web port's PC-controls audit, 2026-07, and no such mechanism exists. The edit
    fires only on `M_RELEASE`, one block per down/up pair. The web port adds a real
    hold-to-repeat itself, as a port-side feature — see WORKING/PORT-STATUS.md.)
  - **Auto-rejump** (hold jump to bhop): `Player.mm:897-917`'s re-trigger gate is
    `lastjump != TRUE && !jumping` — `lastjump` is assigned from `jumping` at the
    END of the previous frame (`:917`), not from the jump button, so holding jump
    re-fires automatically ~2 frames after landing (`jumping` clears on landing
    collision, `:1466`, then the gate needs one more frame for `lastjump` to catch
    up). This works out of the box on both mobile and the web port's PC controls —
    no separate mechanism was needed. The 2-frame gap costs lateral speed (ground
    friction `×0.9` plus the jump's own `vel.x*=.9` lateral tax, `:908-911`, apply
    during it), so chained hops decay rather than build; the web port's opt-in
    "advanced movement" setting removes that cost (see PORT-STATUS.md) without
    touching this file.
  - Creature interactions: tapping a creature in pick mode grabs it
    (`PickupModel`), tap again places (`PlaceModel`); paint mode colors it
    (`ColorModel`); mine mode hits it (`HitModel`); burn sets it on fire.
- **Movement**: `Hud`'s joystick sets `walk_force`/`max_walk_speed`
  (`setSpeed`, ×`SPEED_M 4.5`); physics integrates with `GRAVITY 20`,
  `JUMP_SPEED 6.7`, ice = low-friction sliding (`onIce`), trampolines invert vertical
  velocity, ladders/vines set `climbing` (`CLIMB_SPEED 3`), liquids damp motion and
  set `inLiquid` (with flow push from `getFlowDirection`), autojump option hops
  1-block steps.
- **Collision**: player is a box (`boxbase=2/3` block wide, `boxheight=1.85`);
  `vertc`/`horizc`/`checkCollision` test the surrounding blocks' polyhedra using the
  SAT implementation in `Util.mm` (`collidePolyhedra` + `minTranDist` minimum
  translation vector). Ramps are walkable because their true sloped polyhedra
  are tested (`onramp`).
- **Damage/health** (`health_option`): lava contact (`takeDamage(.08)/frame`),
  creature hits, TNT; `life` drives the red `flash`; death → `dead`, respawn at home.
- **Portals** (`move`, `:1997`): standing in a portal block sets `inPortal` once and
  calls `Portal::enterPortal`, which finds the *next portal of the same color* and
  returns its position+exit direction; travel is a `warpToPoint` (save+reload) if the
  destination is outside the resident window.
- **FLY_MODE** (this fork, `:32`): three bools enable flight; fire/pickaxe buttons
  become up/down thrust. Set all three to `false` to restore stock behaviour.
- **Crouch** (web port addition, `CROUCH_HELD` global + `Player::canFit`): holding crouch (keyboard
  or the web port's HUD button) eases `boxheight` from `1.85` down to `0.925` over ~1s
  (`CROUCH_ANIM_TIME`), feet planted, so the player fits through 1-block gaps. Standing back up is
  rate-limited by `canFit()` scanning the slice being added each frame — under a low ceiling the
  animation just freezes at whatever height still fits instead of snapping into the ceiling block
  (the old instant-toggle version could clip the box into terrain and drop the player through the
  world here). The whole feature is gated by a new `bool CROUCH_ENABLED` global (`Player.mm:32`,
  default **`false`**) — `preupdate`'s read site is now
  `CROUCH_ENABLED && (CROUCH_HELD || hud->m_crouch)`, so both the keyboard key and the HUD button are
  inert when it's off. `Hud.mm` additionally wraps the crouch button's hit-test *and* its render call
  in `if (CROUCH_ENABLED)` (`extern BOOL CROUCH_ENABLED`), so the on-screen button is hidden entirely,
  not just non-functional, when disabled. Unlike `FLY_MODE` above, this is a runtime toggle, not a
  compile-time constant — the web port's "Experiments" settings tab flips it via
  `eden_set_crouch_enabled`/`eden_get_crouch_enabled`. See
  [web/docs/player-input-camera.md](../web/docs/player-input-camera.md) for the touch-button/input
  wiring and [web/docs/ui.md](../web/docs/ui.md) for the settings row, both web-only.

### Rendering
`Player::render` draws nothing in first person (third-person `THIRD_PERSON` is
compile-time off); it exists for the held-block preview and debug markers
(`lol`/`lol1`/`lol2` vectors are debug visualization buffers).

## Camera (`Camera.mm`)
Follows the player exactly: `px/py/pz` = player pos + eye height; `update` smooths
nothing (direct copy); `render` applies pitch/yaw rotations then translates by
`-(pos − chunkOffset·16)` and hands the view-projection to `setFrustum` for culling.
`render2` reproduces the matrix for the picking unproject. `reset()` on world load.

## Common pitfalls
- The same touch can be claimed by HUD, camera-look, and block-edit logic; the
  `inuse`/`movecam` flags are the fragile arbitration — test on device with
  multi-touch when changing anything here.
- `findWorldCoords` mutates GL matrix state (loads identity into MODELVIEW) — call it
  only outside the render passes.
- Physics is frame-rate-dependent in places despite `etime` (forces tuned at 60 fps;
  the 1/20 s clamp in `World::update` is the guard).
- `Player::test` uses `hud->blocktype` implicitly — it tests the *candidate* block
  shape, not a generic cube.

## Safe vs. risky to modify
- **Safe:** speed/jump/gravity constants, fly mode, damage values, adding new
  HUD-mode actions in `processInput`'s mode switch.
- **Caution:** the touch-arbitration flags, collision epsilon handling
  (`minTranDist` thresholds), portal warp flow (it re-enters save/load).
