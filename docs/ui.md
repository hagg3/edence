# UI Architecture

## Purpose
Every pixel of UI — HUD, menus, world browser, sharing screens, keyboard — is drawn
with OpenGL by the game itself. There is **no UIKit UI** beyond the GL view (and
`UIAlertView`-era code in `Alert.mm`). Text is rendered by rasterizing strings through
`Texture2D`'s string initializer and caching the textures.

## Building blocks
- `Texture2D` (`Classes/Texture2D.mm`) — Apple's classic texture class, extended with
  string rendering and `drawSky`/`drawInRect` helpers. UI text = one texture per
  string (regenerated when the string changes — expensive if done per frame).
- `Button` (struct in `Texture2D.h` area; used via `inbox2/inbox3` in `Util.mm`) —
  rectangle + pressed/animation state.
- `statusbar` (`Classes/statusbar.mm`) — the reusable toast/progress line
  (`setStatus(text, priority)`, `clear()`); instances owned by Hud, Menu, SharedList.
- `VKeyboard` (`Classes/VKeyboard.mm`) — custom GL keyboard for world names and
  search (the app predates reliable transparent UIKit overlays on GL).
- `Alert` (`Classes/Alert.mm`) — modal confirm dialogs (delete world etc.).
- `Joystick` (`Classes/Joystick.mm`) — virtual analog stick, owned by Hud.
- `Graphics::beginHud/endHud`, `prepareMenu/endMenu` — orthographic projection setup.
  All layout code branches on `IS_IPAD`/`IS_WIDESCREEN` with hard-coded coordinates
  in a 480×320 / 568×320 / 1024×768 space.

## HUD (`Classes/Hud.mm`, 2246 lines)

State machine over `mode`:
`MODE_CAMERA(0)`, `MODE_PICK_BLOCK(1)`, `MODE_BUILD(2)`, `MODE_MINE(3)`,
`MODE_BURN(4)`, `MODE_PAINT(5)`, `MODE_PICK_COLOR(6)` (`Hud.h:22-29`).

Responsibilities:
- Mode buttons (build/mine/burn/paint/camera), jump button, joystick or lefty D-pad
  (`leftymode`, `use_joystick`), in-game-menu buttons (save/home/exit/settings).
- **In-game menu** (`renderMenuScreen` / `handlePickMenu`, opened by the corner
  `ICO_OPEN_MENU` icon, gated on `inmenu`). **MODIFIED FROM STOCK** (2026-07-29): the
  `renderMenuScreen()` call in `Hud::render` is now additionally gated on
  `eden_hud_draw_menu_screen_hook` (`Hud.h`), a host hook whose default `NULL` means
  "always draw" — so on iOS this is stock behaviour exactly. The web port installs a hook
  that returns false unless the player opted into the legacy GL UI, because it draws its
  own DOM in-game menu in this panel's place; see [web/docs/ui.md](../web/docs/ui.md).
  Note that only the PANEL is suppressible — the corner open-menu icon always draws, since
  it is what opens the thing.
- **Block picker** (`renderBlockScreen` / `handlePickBlock`): `NUM_DISPLAY_BLOCKS 35`
  tiles; picking a second block for ramps (`pickSecondBlock`). Sets `blocktype`.
- **Color picker** (`renderColorPickScreen` / `handlePickColor`): the 54-color grid +
  "no color"; sets `block_paintcolor`. Also generates `colorTable[256]`
  (`genColorTable`, `Hud.mm:151`) — a **global** consumed by the mesher; the HUD owns
  the game's color palette, an inversion worth knowing about.
- `MODE_CAMERA`: hides UI, screenshot capture (`take_screenshot` →
  glReadPixels → PNG in Documents + MD5 hash → `FileManager::setImageHash`).
- Golden-cube counter, health/damage flash (`flash`, `flashcolor`), underwater tint
  (`underLiquid`), FPS counter, fade-in on load (`fade_out`, `justLoaded`).
- `worldLoaded()` resets per-world UI state.

`Hud::update` consumes touches (marks `inuse`) **before** `Player::processInput` sees
them — the ordering in `World::update` is the arbitration.

## Menu system (`Classes/Menu.mm` + satellites)

`Menu` is active in `GAME_MODE_MENU`; `activate()/deactivate()` load/free its textures
(the retina-scale juggling in `World::exitToMenu` wraps `activate`).

- **World carousel**: `loadWorlds()` lists the Documents directory, reads each file's
  header for the display name (`FileManager::getName`; files returning `error~` are
  skipped), builds a doubly-linked `WorldNode` list with preview textures
  (`<name>.png`), arrows to page, tap to load. Create (with `VKeyboard` name entry;
  flat-vs-default via `a_genFlat`), delete (confirm via `Alert`), rename.
- **`Menu_background`** — the animated menu backdrop.
- **`SettingsMenu`** — sound/music toggles, controls (lefty/joystick), autojump,
  health, creatures on/off; persisted via `NSUserDefaults` (confidence: medium —
  verify keys in `SettingsMenu.mm` before depending on them).
- **`ShareMenu`** — upload flow for the selected world.
- **`SharedList`** (`Classes/SharedList.mm`, 881 lines) — the online world browser:
  paged list (name/downloads/date columns as cached textures), sort tabs
  (newest/popular), search (VKeyboard), preview download + display, download world,
  report-world flag button. Talks to `ShareUtil`
  ([networking.md](networking.md)); `finished_dl/finished_preview_dl/
  finished_list_dl` flags are polled by `Menu::update` to integrate async results.
- `statusbar` instances show progress ("Loading World… 47%", "Converting World…").

## Dead/auxiliary UI code
- `Classes/Toolbar.mm` — compiled but apparently unreferenced by World/Hud/Menu
  (likely a pre-2.0 toolbar). Confidence: medium — grep found no live call sites.
- `Classes/Gamepad.mm` — physical controller support scaffolding, referenced by Hud
  includes; extent of use unverified.
- `settings.xib`, `prototypeViewController.xib` — legacy nibs, not part of the GL UI.

## Common pitfalls
- Layout constants are absolute pixels for specific devices; test all three of
  iPhone / widescreen iPhone / iPad ("iPad" = also Retina iPhones, see the `IS_IPAD`
  pitfall in [conventions-and-pitfalls.md](conventions-and-pitfalls.md)).
- String textures leak easily; the code caches them in structs (`SharedListNode`) and
  frees on list rebuild — follow that pattern.
- The HUD directly mutates gameplay globals (`blocktype`, `goldencubes`,
  `block_paintcolor`) that Terrain reads mid-edit.
- Menu and game share the GL context and `Resources` texture slots; menu textures are
  unloaded during play (memory), so any menu code reachable in-game must not touch
  them.

## Safe vs. risky to modify
- **Safe:** layouts, adding buttons/modes following existing patterns, statusbar
  messages.
- **Caution:** touch-consumption ordering vs. Player, `genColorTable` (changes every
  painted block in every saved world!), texture load/unload pairing across
  menu↔game transitions.
