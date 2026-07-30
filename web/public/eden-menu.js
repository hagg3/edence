// eden-menu.js — the rebuilt main menu: Main Menu, Load World, New World.
//
// These are the three Figma mockup screens (Emod-Menu, Emod-Menu-LoadWorld, Emod-Menu-CreateWorld)
// rebuilt in the DOM on the Eden: Community Edition design system.
//
// HOW IT RELATES TO THE ENGINE'S OWN MENU. Classes/Menu.mm is untouched and still running: it owns
// the world list, the selection, the load state machine, the status bars, the alerts. This is an
// OPAQUE FULL-VIEWPORT OVERLAY on top of it that reads that state and triggers the same
// transitions, through the accessors in web/src/seam/Menu_web.mm — read that file's header for why
// this is an overlay rather than a --wrap (short version: the world-load ladder lives inside
// Menu::render(), so wrapping render away would break loading a world).
//
// Two consequences worth knowing:
//   * Turning this off is a one-line escape hatch — the "Legacy menu" setting just stops the
//     overlay from showing, revealing the original GL menu underneath, fully functional. There is
//     no second implementation to keep working.
//   * The overlay eats all pointer input before it reaches the canvas, so Menu::update's own touch
//     handling never fires while this is up. That is what stops the two menus fighting.
//
// BACKGROUND ART: not shipped with this file. The parallax layers and the wordmark are the
// engine's own textures, read out of the preloaded wasm filesystem as blob URLs by
// eden-assets.js — the same PNGs Menu_background.mm draws, so the rebuilt menu cannot drift from
// the original's art. The three home-tile icons are placeholders taken from the engine's existing
// create/load/share button art, to be replaced with purpose-drawn tiles later.
//
// PLACEHOLDERS: the mockups specify controls the port cannot do yet — Get Worlds (the online world
// browser, which needs the edengame.net client), per-world Share and Info, and the New Dawn 256z
// height format (blocked by the frozen T_HEIGHT, see ../CLAUDE.md's format freeze). Those are
// rendered, focusable, and honest about doing nothing (see eden-ui.css's `.is-placeholder`), rather
// than omitted — the screen should show what it will be.
(function () {
  'use strict';

  // Matches the shared-world upload validator (tools/eden2/UploadMap2.java): only letters, digits,
  // spaces and apostrophes survive a world name round-trip through that service.
  var WORLD_NAME_DISALLOWED = /[^A-Za-z0-9' ]/g;

  var S = {
    open: false,
    screen: 'menu',      // 'menu' | 'load' | 'new'
    root: null,
    releaseFocus: null,
    loadingEl: null,
    newWorldType: 1,     // 1 = flat, 0 = normal. Index 0 of the generator rail.
    heightFormat: 0,     // 0 = Legacy 64z (the only one the engine can do)
    selected: -1,
  };

  function M() { return window.Module; }
  function ready() {
    return window.__edenModuleReady && M() && typeof M()._eden_menu_active === 'function';
  }

  function utf8(ptr) {
    var H = M().HEAPU8, end = ptr;
    while (H[end]) end++;
    return new TextDecoder().decode(H.subarray(ptr, end));
  }

  // ---------------------------------------------------------------------------------------------
  // Engine accessors (all index-based — see Menu_web.mm's header)
  // ---------------------------------------------------------------------------------------------
  function worldCount() { return M()._eden_menu_world_count(); }
  function worldName(i) { return utf8(M()._eden_menu_world_name(i)); }
  function worldFile(i) { return utf8(M()._eden_menu_world_file(i)); }

  /**
   * The engine's world list, joined with the filesystem metadata the Storage tab already reads.
   *
   * The engine list is authoritative for WHICH worlds exist and their display names; it just has
   * no size or mtime. eden_storage_list_worlds() has both. Joining on the filename avoids a second
   * stat() implementation in Menu_web.mm and guarantees the two lists can never disagree about
   * what exists.
   */
  function worlds() {
    var out = [];
    var meta = {};
    if (window.EdenStorage) {
      window.EdenStorage.listWorlds().forEach(function (w) {
        // Storage rows key on the same on-disk filename Menu's WorldNode carries.
        if (w.file) meta[w.file] = w;
      });
    }
    for (var i = 0; i < worldCount(); i++) {
      var file = worldFile(i);
      out.push({ index: i, name: worldName(i), file: file, meta: meta[file] || null });
    }
    return out;
  }

  function subtitleFor(w) {
    var ES = window.EdenStorage;
    // "06/08/2025 — 18:49   64z" in the mockup. Every world this engine writes is 64z (the height
    // format is frozen — see this file's header), so the suffix is honest, not decorative.
    if (!w.meta || !ES) return '64z';
    return ES.formatDate(w.meta.mtime) + '   64z';
  }

  // ---------------------------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------------------------
  function go(screen) {
    S.screen = screen;
    render();
  }

  function playSelected() {
    if (M()._eden_menu_play()) render();   // re-render into the loading state
  }

  /** Main Menu — three home tiles over the parallax background, Settings beneath. */
  function renderMainMenu(root) {
    var UI = window.EdenUI;
    var A = window.EdenAssets;

    var logo = A.img(A.NAMES.logo, 'Eden', 'eden-menu__logo');
    root.appendChild(logo);

    var tiles = UI.el('div', 'eden-menu__tiles');
    tiles.appendChild(UI.button({
      size: 'lg', label: 'New World',
      art: A.img(A.NAMES.tileNewWorld, ''),
      onClick: function () { go('new'); },
    }));
    tiles.appendChild(UI.button({
      size: 'lg', label: 'Load World',
      art: A.img(A.NAMES.tileLoadWorld, ''),
      onClick: function () { go('load'); },
    }));
    tiles.appendChild(UI.button({
      size: 'lg', label: 'Get Worlds',
      art: A.img(A.NAMES.tileGetWorlds, ''),
      placeholder: true,
      placeholderNote: 'Online world browser is not available in this build',
    }));
    root.appendChild(tiles);

    var footer = UI.el('div', 'eden-menu__footer');
    footer.appendChild(UI.button({
      size: 'md', iconImg: A.NAMES.iconSettings, label: 'Settings',
      onClick: function () {
        // Route through the ENGINE's showsettings flag rather than calling EdenSettings.open()
        // directly, so the settings panel closes back through eden_settings_menu_close() and the
        // engine's own state machine stays in step — exactly what the GL Options button did.
        M()._eden_menu_open_settings();
      },
    }));
    root.appendChild(footer);
  }

  /** Load World — the mockup's world list with per-row actions. */
  function renderLoadWorld(root) {
    var UI = window.EdenUI;
    var list = worlds();
    if (S.selected < 0 || S.selected >= list.length) {
      S.selected = M()._eden_menu_selected_index();
      if (S.selected < 0 && list.length) S.selected = 0;
    }

    var win = UI.window({
      title: 'Load World',
      onBack: function () { go('menu'); },
    });

    win.actions.appendChild(UI.button({
      size: 'sm', label: 'Delete', onClick: function () { confirmDelete(win); },
    }));
    win.actions.appendChild(UI.button({
      size: 'sm', label: 'Share', placeholder: true,
      placeholderNote: 'World sharing needs the online service, which is not available in this build',
    }));
    win.actions.appendChild(UI.button({
      size: 'sm', tone: 'positive', icon: 'play', label: 'Play',
      onClick: function () {
        if (S.selected < 0) return;
        M()._eden_menu_select(S.selected);
        playSelected();
      },
    }));

    var pad = UI.el('div', 'eden-content__pad');
    // A single-select list, so it gets listbox semantics rather than being a pile of buttons.
    pad.setAttribute('role', 'listbox');
    pad.setAttribute('aria-label', 'Saved worlds');
    win.content.appendChild(pad);

    if (!list.length) {
      pad.appendChild(UI.section({
        title: 'No worlds yet',
        desc: 'Create one from the New World screen and it will appear here.',
      }));
    }

    list.forEach(function (w) {
      var info = UI.button({
        size: 'square', label: 'i', ariaLabel: 'World info',
        placeholder: true, placeholderNote: 'World details are not available yet',
      });
      var load = UI.button({
        size: 'sm', label: 'Load',
        onClick: function (e) {
          e.stopPropagation();
          M()._eden_menu_select(w.index);
          playSelected();
        },
      });
      var row = UI.listRow({
        title: w.name,
        sub: subtitleFor(w),
        selectable: true,
        selected: w.index === S.selected,
        actions: [info, load],
        onClick: function () {
          S.selected = w.index;
          M()._eden_menu_select(w.index);
          render();
        },
      });
      row.setAttribute('role', 'option');
      pad.appendChild(row);
    });

    root.appendChild(centered(win.root));
  }

  /**
   * Delete confirmation.
   *
   * The engine's own delete goes through showAlertDeleteConfirm(), which the port implements as a
   * deliberate no-op (seam_link_stubs.mm: not confirming a destructive prompt is the safe default
   * when you have no dialog) — so the GL menu's Delete button has never actually deleted anything
   * on web. This asks for confirmation in the DOM and then calls eden_menu_delete_at, making this
   * the port's first working delete.
   */
  function confirmDelete(win) {
    var UI = window.EdenUI;
    if (S.selected < 0) return;
    var name = worldName(S.selected);
    var target = S.selected;

    var scrim = UI.scrim({
      onDismiss: function () { scrim.remove(); if (release) release(); },
    });
    scrim.style.zIndex = 'var(--eden-z-alert)';
    var dlg = UI.window({ title: 'Delete world?', variant: 'dialog', scrollbar: false, role: 'alertdialog' });
    var stack = UI.el('div', 'eden-stack');
    stack.appendChild(UI.el('p', 'eden-stack__text',
      '"' + name + '" will be permanently deleted from this browser. This cannot be undone.'));
    stack.appendChild(UI.button({
      size: 'md', tone: 'danger', icon: 'trash-2', label: 'Delete',
      onClick: function () {
        M()._eden_menu_delete_at(target);
        S.selected = -1;
        scrim.remove();
        if (release) release();
        render();
      },
    }));
    stack.appendChild(UI.button({
      size: 'md', label: 'Cancel',
      onClick: function () { scrim.remove(); if (release) release(); },
    }));
    dlg.content.appendChild(stack);
    scrim.appendChild(dlg.root);
    S.root.appendChild(scrim);
    UI.bindButtonSounds(scrim);
    var release = UI.trapFocus(scrim);
  }

  /** New World — name field, generator-type rail, height format. */
  function renderNewWorld(root) {
    var UI = window.EdenUI;
    var TYPES = [
      { icon: 'square', label: 'Flat', flat: 1, title: 'New Flat World' },
      { icon: 'mountain', label: 'Normal', flat: 0, title: 'New Normal World' },
      // The engine has exactly two generators (FileManager::genflat). Biome is in the mockup as a
      // future third; it is shown so the screen matches the design, but as a genuinely disabled
      // control (greyed, no hover, no press, out of the tab order) rather than a `placeholder`,
      // because there is nothing here to explain yet — it is simply switched off.
      { icon: 'trees', label: 'Biome', disabled: true },
    ];
    var active = TYPES.filter(function (t) { return t.flat === S.newWorldType; })[0] || TYPES[0];

    var win = UI.window({
      title: active.title,
      rail: true,
      railLabel: 'World type',
      onBack: function () { go('menu'); },
    });

    var nameInput = UI.el('input', 'eden-field');
    nameInput.type = 'text';
    nameInput.placeholder = 'Enter text...';
    nameInput.maxLength = 60;      // the C-side name buffer is 128 bytes; 60 chars is safe in UTF-8
    nameInput.id = 'eden-new-world-name';
    // The shared-world service only accepts A-Z/0-9/space/' (tools/eden2/UploadMap2.java strips
    // anything else on upload) — filter live so a name never silently gets mangled later.
    nameInput.addEventListener('input', function () {
      var filtered = nameInput.value.replace(WORLD_NAME_DISALLOWED, '');
      if (filtered !== nameInput.value) {
        var pos = nameInput.selectionStart - (nameInput.value.length - filtered.length);
        nameInput.value = filtered;
        nameInput.setSelectionRange(pos, pos);
      }
    });

    function create() {
      // Park the generator choice so showAlertWorldType() consumes it instead of raising a modal
      // the player has already answered on this screen (see Menu_web.mm's world-type section).
      M()._eden_menu_set_pending_world_type(S.newWorldType);
      writeNameBuffer(nameInput.value.trim());
      var idx = M()._eden_menu_create_world();
      if (idx < 0) return;
      S.selected = idx;
      playSelected();
    }

    win.actions.appendChild(UI.button({
      size: 'sm', tone: 'positive', icon: 'play', label: 'Play', onClick: create,
    }));

    TYPES.forEach(function (t) {
      var tab = UI.button({
        size: 'tab', icon: t.icon, ariaLabel: t.label, title: t.label,
        disabled: t.disabled,
        onClick: t.disabled ? null : function () { S.newWorldType = t.flat; render(); },
      });
      tab.setAttribute('role', 'tab');
      tab.setAttribute('aria-selected', (!t.disabled && t.flat === S.newWorldType) ? 'true' : 'false');
      win.rail.appendChild(tab);
    });
    UI.syncRailTabIndex(win.rail);
    UI.railKeyNav(win.rail, function (i) {
      if (TYPES[i].disabled) return;
      S.newWorldType = TYPES[i].flat;
      render();
    });

    var pad = UI.el('div', 'eden-content__pad');
    win.content.appendChild(pad);

    var nameSection = UI.section({ title: 'World name' });
    // The visible pixel-font heading IS the field's label; wiring them together means a screen
    // reader announces "World name, edit text" instead of an unlabelled box.
    nameSection.querySelector('.eden-section__title').id = 'eden-new-world-name-label';
    nameInput.setAttribute('aria-labelledby', 'eden-new-world-name-label');
    pad.appendChild(nameSection);
    var fieldWrap = UI.el('div', 'eden-section__body');
    fieldWrap.appendChild(nameInput);
    pad.appendChild(fieldWrap);
    // Enter in the name field is "create", which is what anyone who just typed a name will press.
    nameInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); create(); }
    });

    pad.appendChild(UI.section({
      title: 'Height format',
      desc: 'New Dawn worlds have a much greater height limit but lack support for older ' +
        'versions and create a larger file size.',
    }));
    var seg = UI.el('div', 'eden-seg eden-section__body');
    seg.setAttribute('role', 'radiogroup');
    seg.setAttribute('aria-label', 'Height format');
    var legacy = UI.button({
      size: 'md', label: 'Legacy 64z',
      onClick: function () { S.heightFormat = 0; render(); },
    });
    legacy.setAttribute('role', 'radio');
    legacy.setAttribute('aria-checked', 'true');
    legacy.classList.add('is-active');
    var newDawn = UI.button({
      size: 'md', label: 'New Dawn 256z',
      placeholder: true,
      placeholderNote: 'The 256-block height format is not implemented in this build',
    });
    newDawn.setAttribute('role', 'radio');
    newDawn.setAttribute('aria-checked', 'false');
    seg.appendChild(legacy);
    seg.appendChild(newDawn);
    pad.appendChild(seg);

    root.appendChild(centered(win.root));
  }

  /**
   * Copy a JS string into the C-owned name buffer.
   *
   * This is the port's only string-INTO-wasm path. It writes UTF-8 bytes straight into HEAPU8 at a
   * pointer C owns, rather than adding _malloc/_free to the export list for one field — see
   * web/docs/ui.md "Passing data across the JS/wasm boundary".
   */
  function writeNameBuffer(text) {
    var ptr = M()._eden_menu_name_buffer();
    var cap = M()._eden_menu_name_buffer_size();
    // Belt-and-suspenders: the live input filter should already have stripped these, but never let
    // an unfiltered name (e.g. a future caller) reach the save file only to get mangled on upload.
    var bytes = new TextEncoder().encode((text || '').replace(WORLD_NAME_DISALLOWED, ''));
    var n = Math.min(bytes.length, cap - 1);
    // Never split a multi-byte sequence: back off to the last byte that starts a code point.
    while (n > 0 && (bytes[n] & 0xC0) === 0x80) n--;
    M().HEAPU8.set(bytes.subarray(0, n), ptr);
    M().HEAPU8[ptr + n] = 0;
  }

  /** Loading state. The engine is mid-load; nothing here is interactive. */
  function renderLoading(root) {
    var UI = window.EdenUI;
    var win = UI.window({ title: 'Loading world', variant: 'dialog', scrollbar: false });
    var stack = UI.el('div', 'eden-stack');
    var pct = UI.el('p', 'eden-stack__text', 'Generating terrain…');
    // The percentage updates every frame from tick(); announce it politely rather than not at all,
    // but don't spam — `aria-live="polite"` on a value that changes this fast is announced by
    // screen readers at their own pace, not per update.
    pct.setAttribute('role', 'status');
    pct.setAttribute('aria-live', 'polite');
    stack.appendChild(pct);
    var bar = UI.el('div', 'eden-progress');
    var fill = UI.el('div', 'eden-progress__fill');
    bar.appendChild(fill);
    bar.setAttribute('role', 'progressbar');
    bar.setAttribute('aria-valuemin', '0');
    bar.setAttribute('aria-valuemax', '100');
    stack.appendChild(bar);
    win.content.appendChild(stack);
    root.appendChild(centered(win.root));
    S.loadingEl = { pct: pct, fill: fill, bar: bar };
  }

  function centered(node) {
    var wrap = window.EdenUI.el('div', 'eden-menu__center');
    wrap.appendChild(node);
    return wrap;
  }

  // ---------------------------------------------------------------------------------------------
  // Shell
  // ---------------------------------------------------------------------------------------------
  function buildBackground(root) {
    var UI = window.EdenUI;
    var A = window.EdenAssets;
    // Back to front, mirroring Menu_background::render's own layer order.
    var sky = UI.el('div', 'eden-menu__layer eden-menu__layer--sky');
    A.applyBackground(sky, A.NAMES.skyMagenta);
    var pin = UI.el('div', 'eden-menu__layer eden-menu__layer--pinwheel');
    A.applyBackground(pin, A.NAMES.pinwheel);
    pin.style.backgroundSize = '100% 100%';
    var mountains = UI.el('div', 'eden-menu__layer eden-menu__layer--strip eden-menu__layer--mountains');
    A.applyBackground(mountains, A.NAMES.mountains);
    var trees = UI.el('div', 'eden-menu__layer eden-menu__layer--strip eden-menu__layer--trees');
    A.applyBackground(trees, A.NAMES.treesLeft);
    var ground = UI.el('div', 'eden-menu__layer eden-menu__layer--strip eden-menu__layer--ground');
    A.applyBackground(ground, A.NAMES.ground);
    root.appendChild(sky);
    root.appendChild(pin);
    root.appendChild(mountains);
    root.appendChild(trees);
    root.appendChild(ground);
  }

  function render() {
    if (!S.root) return;
    if (S.releaseFocus) { S.releaseFocus(); S.releaseFocus = null; }
    S.loadingEl = null;

    // Keep the background layers (they animate; rebuilding them would restart every animation and
    // re-decode the art) and replace only the foreground.
    var fg = S.root.querySelector('.eden-menu__fg');
    if (fg) fg.remove();
    fg = window.EdenUI.el('div', 'eden-menu__fg');
    S.root.appendChild(fg);

    if (M()._eden_menu_loading()) {
      renderLoading(fg);
      return;   // no focus trap: nothing in the loading state is interactive
    }
    if (S.screen === 'load') renderLoadWorld(fg);
    else if (S.screen === 'new') renderNewWorld(fg);
    else renderMainMenu(fg);

    S.releaseFocus = window.EdenUI.trapFocus(fg);
  }

  function show() {
    if (S.root) return;
    window.EdenUI.ensureCSS();
    var root = window.EdenUI.el('div', 'eden-menu');
    root.setAttribute('role', 'dialog');
    root.setAttribute('aria-modal', 'true');
    root.setAttribute('aria-label', 'Eden main menu');
    buildBackground(root);
    document.body.appendChild(root);
    S.root = root;
    window.EdenUI.bindButtonSounds(root);
    // Escape backs out one screen, which is what the Back button does — a menu that traps you on a
    // sub-screen unless you find the right button is a bad menu.
    root.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;
      if (S.screen !== 'menu') { e.stopPropagation(); go('menu'); }
    });
    render();
  }

  function hide() {
    if (!S.root) return;
    if (S.releaseFocus) { S.releaseFocus(); S.releaseFocus = null; }
    S.root.remove();
    S.root = null;
    S.loadingEl = null;
  }

  // ---------------------------------------------------------------------------------------------
  // Engine polling — same pattern as EdenPauseMenu.tick(), driven from eden-st.html's rAF loop.
  // ---------------------------------------------------------------------------------------------
  var wasLoading = false;

  function tick() {
    if (!ready()) return;
    var active = M()._eden_menu_active() !== 0;
    if (active && !S.open) { S.open = true; S.screen = 'menu'; show(); }
    if (!active && S.open) { S.open = false; hide(); }
    if (!S.open) return;

    // A load starting or finishing changes which screen is showing; everything else is
    // user-driven, so this is the only thing the poll has to watch.
    var loading = M()._eden_menu_loading() !== 0;
    if (loading !== wasLoading) { wasLoading = loading; render(); }

    if (loading && S.loadingEl) {
      var pct = M()._eden_menu_load_percent();
      S.loadingEl.fill.style.width = pct + '%';
      S.loadingEl.bar.setAttribute('aria-valuenow', String(pct));
      S.loadingEl.pct.textContent = 'Generating terrain… ' + pct + '%';
    }
  }

  window.EdenMenu = {
    tick: tick,
    isOpen: function () { return S.open; },
  };
})();
