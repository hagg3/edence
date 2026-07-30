# Resources & Audio (Web Port)

Read [`../../docs/resources-and-audio.md`](../../docs/resources-and-audio.md) first —
the `Resources` manager, texture atlas layout, and asset catalog are unchanged. This
file covers the two engine files that had no web equivalent and were seam-replaced,
plus the asset-packaging split.

## Audio: `src/seam/SimpleAudioEngine_web.mm`
Replaces `Classes/SimpleAudioEngine.mm` (the CocosDenshion/OpenAL façade — no OpenAL
on web). Effects go through **Web Audio**; music is a streaming `<audio>` element.
Sound assets need hand-written **IMA4/LPCM `.caf` decoders** since there's no
CoreAudio to lean on. `setEffectsVolume`/`getEffectsVolume` (previously entirely
unimplemented — the real file defining them was excluded) route all effect voices
through one shared `GainNode`; music volume is a separate `<audio>.volume` path.
Per-sound distance attenuation is **not** implemented — the relevant `playEffect`
overload is dead/commented code in `Resources.mm`, and implementing it would require
an engine-side change, which is off-limits.

**Headless-safety rule, found the hard way**: `Resources()` — and therefore the audio
engine — constructs unconditionally in `World::World()` at app startup, so any
audio-init JS that references `window`/`document` unconditionally will throw
`ReferenceError` under `node eden.js` (no DOM) and abort before the tick loop even
starts. This regressed once and silently broke the headless fast-iteration loop for
several passes before being caught. Guard any such reference with
`typeof window !== 'undefined'`, not just interaction-gated code paths.

## Textures: `src/seam/Texture2D_web.mm`
Replaces `Classes/Texture2D.mm` (`UIImage`/`CoreGraphics` decode — no web
equivalent), following the "reuse the original `.h`, replace only the `.mm`" pattern
forced because `Texture2D.h` is quote-included by 8+ other engine headers. Decodes
PNGs via **stb_image** (`src/shim/vendor/stb_image.h`, see
[third-party.md](third-party.md)) instead of `CGBitmapContext`. An early
"X-mirror" bug suspected in this path was tracked down and proven to be a V-flip
elsewhere, not a flaw in the decode — this file carries no flip logic; don't
re-investigate that theory without a fresh measurement.

**`ManipulateImagePixelData()` (`Texture2D_web.mm:800`) is a stub that always returns
null** — pixel-level recolor (CGImage tinting) was explicitly deferred to "P2b
(creature skin/mask recolor pipeline)" and never implemented. `Resources::getPaintTex`/
`getPaintedTex` (`Classes/Resources.mm:572`) call it for any non-default paint color,
build a `Texture2D` from the resulting null image, and get a broken GL handle — this is
why the paint HUD icon reads as invisible except while the paint tool is active (found
pass 49; root-caused, not fixed — see `../../WORKING/RESUME-HERE.md`'s pass-49 section).
Likely breaks painted-block preview rendering the same way. Fixing it for real means
porting the original CGImage-level pixel tinting to stb_image-backed buffers —
feature-sized, not a one-line patch.

## Asset packaging split
- **Textures/UI/HUD art** (`media/textures`, `menu`, `menu_text`, `ui`, `icons`,
  `ipad_menu`, plus a few individually named root-level PNGs like `sky_box.png`) —
  `--preload-file`'d into `/bundle/media/...`, preserving subdirectories.
- **Audio** (~45 MB of `.caf`/`.mp3`/`.wav` under `../media`) — deliberately **not**
  preloaded (would double the initial download). Served over plain HTTP via a
  `public/audio -> ../media` symlink, plus a generated
  `public/audio-manifest.json` mapping bare filenames (the iOS bundle is flat) to
  their real `media/` subdirectory.
- **`media/{models,music,new_sound,sound,screens}`** are excluded from the texture
  preload set — audio is HTTP-fetched separately (above), `screens/` is unused
  marketing art, and `models/` (creature PODs + skins) is preloaded flat separately
  — see [entities-and-creatures.md](entities-and-creatures.md).

## Memory note
Decoded textures are RGBA8 with mipmaps; no compressed texture formats are used — a
plausible future memory win, not implemented.
