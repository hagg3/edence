# Resources & Audio

## Purpose
`Resources` is the asset manager: texture atlases, UI textures, creature skins, and
the entire audio layer (sound effects, ambience, music, creature voices).

## Important files
- `Classes/Resources.mm/.h` (1590 lines) — the manager, `Resources::getResources`
  singleton.
- `Classes/Texture2D.mm` — texture loading (PNG/PVR paths) + string rasterization.
- Audio stack: `Classes/SimpleAudioEngine.mm` (C++ wrapper) over
  `SimpleAudioEngine_objc` / `CocosDenshion` / `CDAudioManager` (OpenAL) — the
  CocosDenshion library, vendored.
- Sound assets: the hundreds of `.caf`/`.m4a` files referenced in the Xcode project
  (block break/build per material ×4 variants, footsteps, creature voice sets per
  species×emotion×5, ambience loops, UI clicks, music `Eden_1..6.m4a`).

## Textures
- `atlas` — the opaque block atlas: a vertical strip of 32 tiles; the mesher stores
  a tile index and the texture matrix scales v by 1/32 ([rendering.md](rendering.md)).
  `getBlockTexShort(texId)` returns the tile origin/height.
- `atlas2` — the transparent/animated atlas (water/lava frames, glass, leaves…);
  rows are animation frames advanced by the render pass.
- `textures` / `menutextures` vectors — indexed by `ICO_*` enums (sky boxes, swirl,
  flower sheet, spheremap, HUD icons…). Game vs. menu sets are loaded/unloaded on
  world enter/exit (`loadGameAssets`/`unloadGameAssets`,
  `loadMenuTextures`/`unloadMenuTextures`) to fit early-device memory.
- `getDoorTex(color)`, `getPaintTex`, `getPaintedTex(type,color)`,
  `getSkin(model,color,state)` — lazily-built colored variants.

## Audio
- `playSound(soundId)` — `NUM_SOUNDS 64` effect groups (`enum SOUND_TYPES`,
  `Resources.h`), each with random variants, preloaded via
  `[SimpleAudioEngine preloadEffect:]`. `S_MENU_BUTTON_PRESS`/`_RELEASE`,
  `S_SKY_CHANGE_DARK_TO_LIGHT`/`_LIGHT_TO_DARK`/`S_SKY_PAINTING`,
  `S_WARP_HOME_ACTIVATED`/`_LOCATION_SET`, `S_WORLD_SAVED`, `S_EXIT_WORLD` (53-61)
  were appended to wire up `media/new_sound/*.mp3` files that shipped in the repo
  but were never referenced from any call site — call sites: `Hud.mm`'s HUD
  menu-icon press/release (`rcam`/`rhome`/`rsave`/`rexit`/`rmenu`), its
  `handlePickMenu` Save button and `delayedaction` 5/6 (exit-to-menu / warp-home)
  branches, `asetHome()`, and `TerrainGen2.mm`'s `paintSky()` (direction inferred
  from whether `final_skycolor` was/becomes `colorTable[54]`, the night/black
  entry). `S_SWITCH_TOGGLE_ON`/`_OFF` (62-63, single-variation each) were added
  later, sourced from `menu_button_press_01.mp3`/`menu_button_release_01.mp3` —
  those two files were pulled OUT of `S_MENU_BUTTON_PRESS`/`_RELEASE`'s random-
  variation pool (now 4 variations, `_02` through `_05`) because variation 01
  audibly stands out from the rest; it's reserved for the web port's settings-
  panel boolean switches (`eden_play_switch_toggle_sound`, `Settings_web.mm`) and
  no longer turns up on an ordinary button click. Appending/reorganizing sound
  IDs freely is fine — unlike block types/`colorTable`, sound IDs aren't part of
  any on-disk struct, so the format-freeze rule doesn't apply to them.
- Burn loop management: `startedBurn(length)/endBurnId/endBurn` reference-count the
  fire loop so 50 burning blocks don't play 50 loops.
- `soundEvent(action[, location])` — positional triggers (distance attenuation).
- `voSound(action, creatureType, location)` — creature voice lines
  (`VO_*` actions × 7 species × 5 variants).
- Ambience: `NUM_AMBIENT 17` environment loops (`AMBIENT_UNDERWATER`, `_CAVE`,
  `_GRASSLANDS`, `_PYRAMID`, `_NIGHT`…) — `update(etime)` crossfades based on player
  surroundings (underwater/height/biome region/night).
- Music: `playMenuTune/stopMenuTune` — title screen rotates randomly (no immediate
  repeat) through `NUM_TITLE_SONGS 2` tracks (`titleSongFiles`: `Eden_title.mp3`,
  `Eden_title_2011.mp3`),
  cued non-looping and advanced to the next random track by a per-frame
  `GAME_MODE_MENU` poll of `isBackgroundMusicPlaying()` in `update(etime)`; in-game
  music tracks (`NUM_SONGS 6`, `songFiles`) rotate the same way via the same engine
  but on a `TIME_BETWEEN_SONGS` cadence instead of track-end.
- User toggles `playmusic`/`playsound` come from the settings menu.

## Lifecycle
Constructed first thing in `World::World()` (before Terrain, because loading screens
need textures/sounds). Menu assets live while in menu; game assets while playing;
both swapped in `World::loadWorld`/`exitToMenu`.

## Common pitfalls
- Texture loads must happen with the GL context current (main thread).
- The `ICO_*` indices are positional — adding a texture mid-list shifts everything
  after it; append only.
- Preloading all sounds at startup is why first launch is slow in the simulator.
- `Sound.h/.m` (a distinct, older wrapper) coexists with CocosDenshion; `Resources`
  is the only sanctioned entry point — don't call the engines directly.

## Safe vs. risky to modify
- **Safe:** adding sounds/textures via the existing tables, tuning ambience rules.
- **Caution:** atlas layout (coupled to `blockTypeFaces` and the 1/32 texture-matrix
  scale), load/unload pairing (double-frees on the menu↔game boundary are a classic
  crash here).
