# GL ES 1.1 → WebGL2 Shim

The single largest body of web-specific knowledge in this port. `src/shim/gl/
gl_es1_shim.{h,cpp}` implements only the ~45 GL ES 1.1 fixed-function calls the
engine actually makes — a thin, purpose-built shim, not a general ES1-over-WebGL2
emulator. Read [`../../docs/rendering.md`](../../docs/rendering.md) first for the
draw passes, vertex formats, and meshing this shim sits underneath — none of that
changes; this file is about how fixed-function calls get turned into WebGL2 draws.

## Matrix stacks
Must seed to identity in their constructor. A pass-14 bug left static matrices
zero-initialized, which silently zeroed `u_texmat` and blacked out the entire menu
with no GL error — the kind of failure that only shows up as "nothing renders,"
not a GL error you can catch.

## Two GLSL programs, not one
GLSL ES 1.00 forbids indexing a uniform array by an attribute value, which is exactly
what matrix-palette (creature) skinning needs. Rather than branch in the shared
fixed-function-equivalent shader, skinning is a **second** GLSL ES 3.00 program
(`kSkinVertexShader`). Both programs share attribute slot numbers via one
`eden_gl_setup_attributes()` so switching programs doesn't require rebinding vertex
state.

- The palette matrix maps object space straight to eye space, because `Model.mm`
  reads back `GL_MODELVIEW_MATRIX` already including a `glScalef` — so the skin
  shader multiplies by `u_proj`, not a combined `u_mvp`.
- `glVertexAttribPointer` defaults any unsupplied vector components to `(_, 0, 0, 1)`.
  A 4-wide bone-weight loop over a POD model with only 2–3 real influences reads a
  phantom `1.0` weight from the unset 4th slot — handled via an explicit
  `u_boneCount` uniform rather than relying on the default.

## Draw-state cache
A dirty-tracking cache shadows: the bound program, all 17 uniforms (cached per
program object), the 7 attribute specs, `glActiveTexture`, and buffer bindings —
issuing a real GL call only on an actual delta. Measured 34.4 → 4.5–5.9 setup calls
per draw (7.4–7.6× fewer). Two invariants if you touch this code:
- The cache write must happen **outside** any `force ||` short-circuit in the
  set-state helpers, or a forced-but-identical set desyncs the cache from reality.
- `eden_gl_shim_invalidate_gl_objects()` must reset every cache after any GL object
  deletion — a recycled name (see below) must never be trusted as "same object."

`GL_ARRAY_BUFFER`/`GL_ELEMENT_ARRAY_BUFFER` bindings are the one piece of draw state
the *engine itself* also writes directly, so they're tracked against
`g_bound_*_buffer` mirror variables rather than folded into a VAO. VAOs were
considered and rejected: `TerrainChunk.mm` binds its EBO outside of any draw call,
which would corrupt a non-default VAO's element-array binding as a side effect.

`glDeleteBuffers` must invalidate any attribute cache entry naming the deleted
buffer — GL detaches deleted buffers from all binding points, and `glGenBuffers`
recycles names, so a stale cache entry can silently point at a *different*, newer
buffer with the same name. `TerrainChunk.mm` deletes and regenerates per-chunk VBOs
every streaming boundary (several call sites), making this a live hazard, not a
theoretical one.

## Context loss
`emscripten_webgl_get_current_context()` keeps returning a handle even after context
loss, so a naive "do we have a context" guard never trips. The shim tracks its own
handle plus a `g_context_lost` flag instead. The `webglcontextlost` DOM event handler
must call `preventDefault()`/return `EM_TRUE`, or `webglcontextrestored` never fires
and the page is stuck.

## Drawable size vs. logical screen size
The drawable (canvas backing store) is dynamic; the engine's notion of screen size is
not. `eden_set_drawable_size()` scales the CSS box × `min(devicePixelRatio, cap)` ×
a render-scale setting into the actual backing-store/viewport size, but
`SCREEN_WIDTH`/`SCREEN_HEIGHT` (the globals the engine reads) stay pinned to their
original values. The backing store is clamped to 4096px/axis (risk of exceeding
`GL_MAX_RENDERBUFFER_SIZE` otherwise).

**This is the root cause of the mobile touch-offset bug** fixed in the recent "web:
fix mobile touch offset in mine/build raycast" / "fix jumps added crosshair back"
commits: `Util.mm`'s `findWorldCoords` raycast reads back whatever `GL_VIEWPORT`
currently reports and assumes it matches a fixed pixel scale. Once the drawable
became dynamically sized, that no longer matched the assumed 1136×640. Fix:
`eden_gl_glGetIntegerv(GL_VIEWPORT, …)` answers a **pinned** `{0, 0, 1136, 640}` for
picking purposes regardless of the real drawable size — the real size is tracked
separately but deliberately not surfaced to this one call site.

## Creature (matrix-palette) skinning emulation
- `glGetString(GL_EXTENSIONS)` is *answered*, not forwarded to the real driver: the
  shim prepends `GL_OES_matrix_palette` because `Model.mm:1660` gates POD-model
  loading on seeing that string.
- Entry points are installed via `-Wl,--wrap=_ZN12CPVRTglesExt14LoadExtensionsEv`
  (`src/seam/pvrt_matrix_palette.cpp`), a wrap rather than a whole-file seam because
  only that one function needed different behaviour.
- POD assets are preloaded flat to `/bundle/*.pod` at the bundle root, matching the
  original Xcode project's Copy-Bundle-Resources layout — skin PNGs for the same
  models live alongside them under `media/models/`; both paths must be preloaded or
  creatures render as unbound-texture black silhouettes with no GL error.
- `GL_LIGHT0` ambient/diffuse (`glLightfv`) is tracked and applied **only** on this
  skinned path — general lighting for doors/the golden cube is still unimplemented in
  the shim, a deliberately narrow gate rather than a general ES1-lighting emulation.
  See [lighting-liquids-effects.md](lighting-liquids-effects.md).

## Point sprites (fire/smoke particles) need their own texturing gate
`u_useTexture` was gated on `g_texture2d_enabled && g_arrays[ATTR_TEXCOORD].enabled` — correct
for ordinary textured triangles, wrong for `GL_POINTS`. ES1 point sprites get their UV from
`GL_COORD_REPLACE_OES` (this shim's `gl_PointCoord`), not the texcoord client array, and
`SpecialEffects::render()` (`Classes/SpecialEffects.mm`) deliberately
`glDisableClientState(GL_TEXTURE_COORD_ARRAY)`s before drawing the fire/smoke `GL_POINTS` for
exactly that reason. The old gate read that as "not texturing," dropped `u_useTexture` to 0, and
the point sprites silently fell back to a flat vertex-colored square — reported as "fire looks
like plain colored squares instead of a smoke/ember sprite." Fix: the gate now also passes when
`mode == GL_POINTS && g_point_sprite_enabled`, mirroring the shader's own `mix(v_texcoord,
gl_PointCoord, u_pointSprite)` UV selection. Both `glDrawArrays`/`glDrawElements` pass their real
`mode` into `eden_gl_apply_uniforms(mode)` already, so no call-site change was needed.

## Debugging note
See [conventions-and-pitfalls.md](conventions-and-pitfalls.md) #6 — Chrome-extension
GL introspection tools don't see the real draw-time state; add an `fprintf` in the
shim and rebuild instead.
