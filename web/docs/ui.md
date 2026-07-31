# UI Architecture (Web Port)

Read [`../../docs/ui.md`](../../docs/ui.md) first — the custom-GL HUD/menu system
(`Hud.mm`/`Menu.mm`) is still compiled and still authoritative for state and side
effects. What's different on web: several *screens* are replaced by DOM overlays that
drive the same engine state via synthetic input, rather than by editing `Classes/`.

**For how those overlays *look*, read [design-system.md](design-system.md)** — tokens,
components, the scale unit, the accessibility contract, and the deviations from the
Figma-derived kit. This file covers what each screen *does*; that one covers how
anything in the DOM is built. Open `public/eden-ui-specimen.html` to see every
component at once without booting the engine.

## Settings panel (`public/eden-settings.js` + `src/seam/Settings_web.mm`)
`SettingsMenu`'s data model (`properties[]`, `load()`, `save()`, `getNewWorldName`)
stays authoritative; only its `update()`/`render()` become no-ops, via
`-Wl,--wrap=_ZN12SettingsMenu6updateEf` / `renderEv` — possible because both are
called from `Menu.mm`, a different translation unit, so the wrap can intercept the
cross-TU call without touching `SettingsMenu.mm` itself.

One C table, `kSettings[]` (`src/seam/Settings_web.mm`), is the single source of
truth for what the DOM panel shows — `eden_settings_schema()` exposes it, and
`public/eden-settings.js` renders it generically. **Add a setting in C, never in
JS.** Currently 22 settings across 6 groups — `Gameplay` (health, autojump,
creatures), `Audio` (music, sound, music volume, effects volume), `Controls` (input
mode, hold-to-act, mouse sensitivity ×2, invert-look), `Video` (FOV, display mode,
render scale, max device-pixel-ratio), `Interface` (crosshair, block preview), and a
dedicated **`Experiments`** group for opt-in/non-stock movement toggles: fly mode,
frame-rate normalize (`fps_normalize`), advanced movement/bhop (`advanced_movement`),
and crouch mode (`crouch`, gates `CROUCH_ENABLED`, see
[player-input-camera.md](player-input-camera.md)). `fly`, `fps_normalize`, and
`advanced_movement` previously lived under `Gameplay`/`Controls`; only their `group`
string moved to `Experiments`, their engine defaults and behavior are unchanged.

**Trap**: `SettingsMenu::load()` hard-codes `player->invertcam = FALSE` and
`hud->use_joystick = TRUE` on **every** load (`Classes/SettingsMenu.mm`) — this is
engine behavior, not a bug to fix. The port's own `eden_apply_port_settings()` must
re-run after every `save()`/`load()` or these two values silently revert.

Keybinds are the **one deliberate exception** to "settings live in the C table":
`window.EdenKeybinds`, a JS-owned `localStorage` blob mapping action → physical key
code, because the C settings model only stores floats. See
[conventions-and-pitfalls.md](conventions-and-pitfalls.md) #7.

`NSUserDefaults` itself is localStorage-backed
(`src/shim/foundation/NSUserDefaults.mm`) — NSNumber/NSString only, namespaced under
`eden.prefs.`, guarded so headless (`node eden.js`, no `localStorage`) degrades to an
in-memory default.

## In-game menu (`public/eden-pausemenu.js`)
Replaces `Hud::renderMenuScreen`'s 4-icon GL screen (Resume/Save/Warp Home/Take
Photo/Settings/Quit) with a DOM overlay. No `--wrap` here — the original screen is
inline inside `Hud::update`/`render`, too intra-TU to intercept piecemeal. Instead the
overlay polls `hud->inmenu` (`eden_hud_in_menu()`) and drives every action as a
synthetic tap on the real button rects (`eden_tap_hud_button_begin/end`, with cases
added for save/warp-home/photo/quit) — same "drive it, don't write flags" pattern as
[player-input-camera.md](player-input-camera.md).

**It is titled "Menu", not "Paused"** — opening it does not pause anything. `hud->inmenu`
only gates input and swaps what `Hud::render` draws; `World::update` keeps running
underneath, so creatures move, fire spreads and the sun keeps travelling while it is up.

**Exactly one in-game menu is ever on screen, and `legacy_menu` picks which.** This used to
be true by accident: the DOM panel was a full-canvas opaque overlay, so the GL panel
rendering underneath was simply never visible. Once the panel shrank to fit (below) the
four GL icons showed through the scrim behind it, so it is now explicit and symmetric:

- `legacy_menu` **off** (default) — `Hud::renderMenuScreen` is suppressed via
  `eden_hud_draw_menu_screen_hook`, a hook added to `Classes/Hud.h` whose default `NULL`
  keeps stock behaviour, installed from a static ctor in `Menu_web.mm`. The DOM panel shows.
- `legacy_menu` **on** — the hook returns true, the GL panel draws, and
  `eden-pausemenu.js`'s `tick()` keeps the DOM panel closed (it reads the same flag through
  a new `eden_legacy_ui_active()` export). Checked every tick, so toggling the setting takes
  effect immediately, including closing a panel that is already up.

Why a hook and not a `--wrap`: the `renderMenuScreen()` call is **intra-TU** (both it and
`Hud::render` live in `Hud.mm`), so the compiler resolves it directly and the linker never
sees a symbol to wrap. Why a hook and not a plain `bool` on `Hud`: then there is no flag for
anyone to keep in sync — the answer is recomputed at the one moment it is needed.

Layout: a shrink-to-fit dialog (`.eden-window--fit`) whose width is set by its content
rather than the 460u dialog default, with left-aligned icon+label rows
(`.eden-stack--left`) laid out in **two columns** (`.eden-stack--grid`) — six full-width
rows made a tall thin panel whose labels hugged the left of a lot of dead width. There is
no title-bar close button — Resume is the first row, the scrim dismisses, and Escape
resumes; a fourth affordance for the same action was noise, and it was the one thing
forcing the title bar wider than the content. Resume keeps the vector `play` glyph;
Save/Warp Home/Take Photo/Settings/Quit carry the engine's own `media/ui` icon art via
`button({ iconImg })` (see design-system.md "Iconography").

The old `max-height:480px` reflow (pass 42, a 2x2 grid to rescue six stacked rows on a
phone-landscape viewport) is **gone** — there is no six-row stack any more, and it was also
catching the prose+buttons confirm dialogs, which never wanted two columns. A
`max-width:420px` query drops the grid back to one column, since two ~180px columns don't
fit a portrait phone. The settings panel still tightens its rhythm and hit targets at
`max-height:480px`, keyed on viewport *height* — the input stays touch, only the rhythm
changes. **That query used to `display:none` the settings rows'
description lines**; it no longer does. Dropping them was wrong in practice — several
settings are only intelligible from the hint, and a phone is exactly where you cannot
hover a tooltip to recover it. They now just shrink (with a 12px floor, since `--u` has
already bottomed out at 1 by this breakpoint) and the content box scrolls, which is the
cheaper failure. Live-verified at 1000x383 CSS px with a real resized window.

## Loading/progress overlay (`public/eden-loading.js`)
Perf-audit row 11 ("minute-plus black screen on mobile"). A DOM overlay (title, a
progress bar, byte-count sublabel) shown from the moment `eden-st.html`'s inline
script starts running — before `Module` even exists — until `moduleReady` is true
*and* a few dozen rAF frames have passed (reuses the existing `watchFrames` first-frame
heuristic, but now gates on `moduleReady` too — see the comment at its call site;
`watchFrames(120)` alone fires on a fixed rAF-frame count from page load, independent
of whether the engine has actually finished booting, which would hide the overlay
early on a slow/cold load). Doesn't wrap `window.fetch` (rejected — too easy to
subtly break Emscripten's own wasm/data fetches for a page that only needs progress on
two specific large assets); instead:
- `eden.data` (the small UI/HUD/atlas asset package): polls Emscripten's own
  `Module.dataFileDownloads['eden.data']`, which its stock generated loader already
  populates byte-for-byte — no project code needed on that side.
- `Eden.eden` (the ~52 MB default-world map, see [save-load.md](save-load.md) and
  `src/seam/js/eden_default_world.pre.js`): that seam file's browser fetch path now
  streams the response body (`ReadableStream`, falls back to a plain `arrayBuffer()`
  read if unsupported) and reports through `window.EdenLoading.setEdenFileProgress`.

The two byte-tracked spans are weighted by total size and mapped into the middle 90%
of the bar (5% head/tail reserved for wasm compile and post-download `main()`/
`World::World()` startup, neither of which has a useful byte-level signal). Doesn't
touch the existing `#eden-status` diagnostic line (12px monospace, top-left) — that
stays as-is for debugging a stuck/failed boot per RESUME-HERE's "Watch out for"
section. Live-verified (pass 43): the indeterminate "Starting…" state renders on a
real cold load; the determinate byte-progress labels and clean removal on
`markReady()` were verified via direct API calls (a same-origin dev server serves
this project's assets too fast locally to observe a real multi-second download).

## Load-failure recovery dialog (`public/eden-loaderror.js`)
A DOM "this world could not be loaded" panel, same shape as the pause menu (opaque
overlay, no engine state of its own) — polls `eden_load_failed()`
(`web/src/seam/LoadFailure_web.mm`) once a frame and offers Restore-`.bak`-and-reload
or Back-to-menu. See [save-load.md](save-load.md) for the mechanism and pass 42's two
fixes (a failed load previously still crashed the engine a frame or two after this
dialog appeared, and the Restore button previously destroyed the very backup it was
meant to restore) — both now fixed and live-verified end-to-end.

## Alert/dialog seams (`src/seam/seam_link_stubs.mm`)
Real DOM dialogs (`EM_ASM`) replace what used to be auto-answer stubs:
- World-type dialog (Flat/Normal) — falls back to auto-answering "Normal" when
  `document` doesn't exist (headless).
- Warp-home confirm dialog — button order transcribed literally from `Alert.mm`'s
  `-alertView:clickedButtonAtIndex:` delegate semantics, factored through a generic
  `eden_js_alert_dialog()` helper reused for other confirms.

`Alert.mm` itself stays seam-excluded (see [networking.md](networking.md)) — its
delegate *semantics*, not its implementation, are what's preserved.

## Storage tab
Lives in the same settings-panel UI; see [save-load.md](save-load.md) for the
mechanism.

## Passing data across the JS/wasm boundary
This port deliberately has no `_malloc`/`_free` on the wasm export list, so any
JS-side API that would otherwise need to pass a string or buffer *into* wasm is
designed to be **index-based** instead (e.g. storage-tab world deletion by row
index). Keep this pattern for new JS↔wasm settings/storage calls rather than adding
malloc/free exports.

## Port-invented UI (no engine equivalent)
A curated 9-block hotbar strip (backed by the engine's real block-picker data, but a
port-invented curated UI concept — the engine itself only has a scrolling grid) and a
DOM crosshair. See [player-input-camera.md](player-input-camera.md).

## Main menu / Load World / New World (`public/eden-menu.js` + `src/seam/Menu_web.mm`)
The three Figma mockup screens, rebuilt in the DOM as an **opaque full-viewport overlay
on top of the still-running GL menu** — the same "drive it, don't replace it" pattern as
the pause menu, and for a sharper reason: `Menu.mm`'s world-load state machine lives
inside **`Menu::render()`** (the `loading` ladder 1 → 2 → *(worldExists? 4 : alert + 3 →
4)* → `World::loadWorld`), so `--wrap`ping render away would silently break loading a
world. The overlay eats pointer input before it reaches the canvas, which is what stops
the two menus fighting.

`Menu_web.mm` is **not** a seam replacement (`Menu.mm` still compiles and runs); it only
exposes the engine's state and offers the same transitions the GL touch handler
performs: `eden_menu_active/loading/load_percent`, `world_count/name/file`,
`select/play/create_world/delete_at`, `set_pending_world_type`, `open_settings`. All
index-based, per the boundary convention below. The one string that has to travel
*into* wasm — a new world's name — goes through `eden_menu_name_buffer()`, a static
buffer JS writes UTF-8 into, rather than adding `_malloc`/`_free` to the export list.
The name field filters to `A-Za-z0-9' ` live on input (and again defensively before the
buffer write), matching the character set `ShareMenu::keyTyped` has always enforced on
iOS (`isalnum(c)||c==' '||c=='\''`) and that `tools/eden2/UploadMap2.java` enforces
server-side on upload — without it, a locally-created world can carry a name (e.g.
non-Latin scripts) that the shared-world service silently mangles on share.

Two behaviours worth knowing:
- **World names are filtered to `A-Z a-z 0-9 ' ` and space**, live as you type and again at the
  wasm boundary. That is the character set `tools/eden2/UploadMap2.java` accepts; anything else is
  silently stripped on upload, so a name that survives creation but not sharing is worse than one
  the field never let you type.
- **World type is asked up front.** The engine raises its Flat/Normal modal from inside
  the load ladder; the New World screen asks with a generator rail instead and parks the
  answer, which `showAlertWorldType()` (`seam_link_stubs.mm`) consumes. Falls back to the
  real dialog whenever nothing is pending, so it is additive. The rail's two live tabs are
  the engine's only two generators (`FileManager::genflat`) and the window title names the
  one selected — "New Flat World" / "New Normal World" — so the screen always says which
  world it is about to make; the third tab is `disabled`, not a placeholder.
- **Delete actually works now.** The GL path routes through `showAlertDeleteConfirm()`,
  which the port implements as a deliberate no-op (not confirming a destructive prompt is
  the safe default with no dialog), so the engine's own Delete button has never deleted
  anything on web. The DOM screen confirms in the DOM, then calls `a_deleteConfirm()`.

The **`legacy_menu`** setting (Interface group, labelled "Legacy UI") turns the overlay off,
revealing the original 2010 GL menu underneath, fully functional. For the MAIN menu "legacy"
is literally "stop drawing the overlay", so there is no second code path to keep alive. The
in-game menu needs one extra step in the other direction — its GL panel is suppressed by
default and this flag re-enables it; see "In-game menu" above.

**Trap (fixed): global game hotkeys ate keystrokes typed into any DOM text field.**
`eden-st.html`'s `window` `keydown`/`keyup` listeners drive movement/action keys off
`e.code` with no regard for what has focus, so typing into the New World name input
used to also move/jump/toggle-fullscreen/open-Settings/etc. the moment a typed letter
matched a keybinding (`KeyE`/`KeyB`/`KeyL`/`KeyO`/**`Space`**, ...) — `Space` is the
worst of these since it also `preventDefault()`s, so the character never reached the
field at all. Both listeners now bail out via `isTypingTarget(document.activeElement)`
when an `<input>`/`<textarea>`/`contentEditable` element has focus. Any future DOM
text field inherits this for free; no per-field opt-in needed.

## The engine's retina/quality swap is ignored on purpose (audit row 22 / B7)
`World::update()` returns a bool meaning "swap graphics quality"; on iOS
`EdenViewController.mm` answered it by flipping `IS_IPAD`/`IS_RETINA`/`SCALE_WIDTH`/
`SCALE_HEIGHT` and recreating the framebuffer at the new density. **This port
deliberately does neither**, and `EdenViewController_web::drawFrame()` carries the full
reasoning. The short version, because it is the thing to understand before touching any
UI layout here:

> **`IS_IPAD`/`IS_RETINA`/`SCALE_*` are this port's layout coordinate system, not its
> resolution.** `EAGLView_web`'s `establishScreenMetrics` pins a 568×320 point space at
> 2× and the engine lays every HUD and menu element out in it; the real drawable is
> decoupled entirely, via `applyDrawableSize()` (CSS box × `min(devicePixelRatio,
> dpr_cap)` × `render_scale`). Flipping those globals does not make pixels cheaper — it
> halves the UI's own layout math underneath an unchanged surface.

The port already exposes the *intent* ("cheaper pixels") as two real settings,
`render_scale` and `dpr_cap`. The branch used to flip the globals without recreating
anything, which was the worst of both worlds; it is now an explicit no-op that announces
itself once under `EDEN_DIAGNOSTICS` if it ever becomes reachable. It is unreachable
today — `World::update` only requests a swap when `!bestGraphics`, and nothing in this
port ever sets `LOW_MEM_DEVICE`/`LOW_GRAPHICS`, while `IS_WIDESCREEN` (pinned `TRUE` in
the seam) forces `bestGraphics` back on regardless. Revisit only as part of audit row 18
(D1, unpin the display constants) / row 22's successor D4 profiles, where it becomes a
profile field rather than a per-frame branch.

## Known gaps
- **World name display**: `Menu.mm` draws the "EDEN" wordmark, not the selected
  world's name — the actual name is drawn through a `statusbar` (custom-GL text, see
  root [ui.md](../../docs/ui.md)), which has no numeric debug-probe proxy. Moot for the
  DOM menu, which shows names directly; still true of the legacy GL menu.
- **`VKeyboard`** (world renaming / search text entry) has no web replacement yet —
  the original overlays a real `UITextField` via a UIKit method call. Currently
  seam-excluded with no replacement. The New World screen's DOM `<input>` covers world
  *naming* at creation; renaming an existing world still has no path.
- **Mockup features with no implementation** (see design-system.md "Placeholders and
  disabled controls"): Get Worlds (needs the edengame.net client), per-world Share and
  Info, and the New Dawn 256z height format (blocked by the `T_HEIGHT` format freeze) are
  focusable placeholders that explain themselves; the Biome generator tab is a plain
  `disabled` control, since "third world type, switched off" needs no explanation.
- No onboarding/controls-discovery overlay, and "reset settings" doesn't reset the
  JS-owned keybind blob. (Corrupt-save recovery UI now exists — see "Load-failure
  recovery dialog" above and [save-load.md](save-load.md); first paint is now the boot
  progress screen, not a bare status line.)

## `public/*.js` dependency graph (audit row I2)
Twelve files, ~2.5 kLOC, loaded as plain `<script>` tags (no bundler, no `MODULARIZE`) sharing
`window` globals — deliberate, not an oversight: the non-`MODULARIZE` `eden.js` output and the
`vm.runInThisContext`-based headless harnesses (`tools/headless-*.js`) both depend on everything
living in global scope, so a module system would need its own headless-compatible shim before it
earned its keep. Load order in `eden-st.html` is therefore significant and is the actual dependency
order — a file may only assume an earlier `<script>`'s global already exists:

```
eden-icons.js  →  eden-ui.js  →  eden-assets.js  →  eden-loading.js  →  eden-storage.js
   →  eden-settings.js  →  eden-pausemenu.js  →  eden-loaderror.js  →  eden-menu.js
   →  eden-gamepad.js  →  eden-console.js
```

Each file publishes exactly one `window.Eden*` namespace object (assigned once, at the bottom of an
IIFE) and reads only the namespaces of files that loaded before it, plus the wasm boundary
(`Module.*`/`FS.*`) and the engine-owned `window.EdenKeybinds` blob `eden-st.html` itself installs.
`eden-ui.js`/`eden-icons.js`/`eden-assets.js` are the base layer every screen is built from and have
no dependency on each other in that order (icons/assets are pure data; `eden-ui.js` is the factory
library). `eden-gamepad.js` is the one leaf with no `Eden*` dependency at all — it only touches
`navigator.getGamepads()` and the bridge object `eden-st.html` hands it.

| File | Publishes | Reads (`Eden*`) | Reads (wasm/DOM boundary) |
|---|---|---|---|
| `eden-icons.js` | `EdenIcons` | — | — |
| `eden-ui.js` | `EdenUI` | `EdenAssets`, `EdenIcons` | — |
| `eden-assets.js` | `EdenAssets` | — | `Module.FS` |
| `eden-loading.js` | `EdenLoading` | `EdenUI` | `Module.dataFileDownloads` |
| `eden-storage.js` | `EdenStorage` | `EdenLoadError` (only inside a callback fired well after boot — see below) | `Module.preRun`, `FS.mount`/`mkdir`/`readFile`/`writeFile`/`syncfs`, `Module._eden_storage_list_worlds` |
| `eden-settings.js` | `EdenSettings` | `EdenUI`, `EdenStorage`, `EdenConsole` (feature-detect only), `EdenKeybinds` | `Module._eden_settings_schema` |
| `eden-pausemenu.js` | `EdenPauseMenu` | `EdenUI`, `EdenSettings`, `EdenAssets` | — |
| `eden-loaderror.js` | `EdenLoadError` | `EdenUI`, `EdenPauseMenu.tick` (to suspend it while the dialog is up) | `FS.syncfs` |
| `eden-menu.js` | `EdenMenu` | `EdenUI`, `EdenStorage`, `EdenAssets`, `EdenPauseMenu.tick` | — |
| `eden-gamepad.js` | `EdenGamepad` | — | — (Gamepad API + a bridge object passed in by `eden-st.html`) |
| `eden-console.js` | `EdenConsole` | `EdenUI` | — |
| `eden-st.html` | `EdenRenderer`, `EdenKeybinds` | all of the above | `Module`, `FS`, everything else |

**The one forward reference:** `eden-storage.js` (loaded 5th) calls `EdenLoadError.showStorageWarning`
(defined 8th) from inside `checkQuotaAndWarn()`/`flushNow()`'s error callbacks. This is safe *only*
because those callbacks fire asynchronously (a `syncfs` completion, a quota check after boot), by
which point every `<script>` tag on the page has already run — load order guarantees definition
order, not callback-firing order. Anything that instead calls a later file's global **synchronously**
during its own top-level IIFE execution would break. If you add a new cross-file call, check whether
it's reachable from the calling file's own script-execution time (breaks) or only from a later
callback/event (safe).

**What each file requires on `window` beyond `Eden*`:** every screen file also assumes
`document`/`window` exist — none of the eleven `public/*.js` files are reachable from the headless
harnesses (there is no `document` under `node eden.js`), which is exactly why `A8`'s
`Module.__edenFramePost` hook and every headless suite in `tools/` test the *engine* side of a
feature and leave the DOM layer for a live-browser pass. See audit rows G2/B8's "needs a live
browser" notes for the concrete instances this has already blocked.

## Design notes
Every DOM surface shares one visual language — chunky beveled "arcade cabinet"
skeuomorphism, square corners, hard-edged shadows, the Jersey 10 pixel face, one lime
accent — defined in `public/eden-ui.css` and built by `public/eden-ui.js`'s factories.
**[design-system.md](design-system.md) is the reference**; don't re-derive it from the
CSS. Density is handled by the `--u` scale unit (the whole UI rescales with the
viewport) plus a `pointer: coarse` block that raises hit boxes to the 44px floor where
that scale bottoms out.

This replaced the "Dark Glass Chrome" language the settings panel used through pass 43
(dark gradient surfaces, rounded corners, a leaf-green accent, ~200 lines of CSS
injected from `eden-settings.js` as a JS string). Nothing of it remains;
`EdenSettings.injectCSS()` survives only as an alias for `EdenUI.ensureCSS()` so
existing call sites keep working.
