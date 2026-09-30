# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Two independent SketchUp 2017 Ruby plugins that fix rendering bugs when running under Wine on Linux. Each can be installed with or without the other.

### `wine_sketchup_fix.rb` (v1.1.0)

1. **One-frame render delay** — fixed by attaching observers to model/view/selection/tools/layers/rendering-options events and calling `invalidate.refresh` on each change. Only needed on XWayland/X11; Wine's native Wayland driver does not have this bug.
2. **Missing rubber band selection box** — SketchUp 2017 draws overlays to the OpenGL front buffer, which a compositing display server does not reliably present. Fixed by replacing the native select tool with `RubberBandTool`, which calls `$stdout.flush` immediately before `draw2d`. This is an empirical fix: why it works is not established. The earlier "EGL buffer swap" explanation was disproved (forcing GLX or using the native Wayland driver does not restore the rubber band), so do not reintroduce it.
3. **Component/group edit mode entry** via double-click in `RubberBandTool`.

### `wine_wayland_menu_fix.rb` (v1.0.0)

Under Wine's native Wayland driver, Win32 popup menus are Wayland subsurfaces stacked beneath the OpenGL canvas subsurface, so they are hidden until the canvas is next restacked. A repeating `UI.start_timer` polls for visible popup-menu windows (class atom `0x8000`, `"#32768"`) through Fiddle `User32` calls. When a new menu appears, it refreshes the view for a short burst (`BURST_REFRESHES`), which makes Wine restack the canvas below the menu.

## Development workflow

There is no build, lint, or test toolchain. The plugins run inside SketchUp's embedded Ruby interpreter. To test changes:

1. Copy the `.rb` file(s) to the SketchUp plugins folder (see README for path).
2. Launch SketchUp under Wine and exercise the affected behaviours manually. Test under both the native Wayland driver and XWayland where behaviour depends on the driver.
3. The Ruby Console (`Window → Ruby Console`) can be used for ad-hoc inspection while SketchUp is running.

Releases are tagged per plugin: `vX.Y.Z` for `wine_sketchup_fix.rb` and `menu-fix-vX.Y.Z` for `wine_wayland_menu_fix.rb`. Record changes in `CHANGELOG.md` and bump the version in the file header (and the `VERSION` constant in the menu fix).

## Architecture: `wine_sketchup_fix.rb`

Everything lives inside the `NH::WineSketchupFix` module, apart from the menu commands and `WineFixAppObserver` at the bottom of the file.

**Shared observer set** — All observers (`SharedToolsObserver`, `SharedViewObserver`, `SharedSelectionObserver`, `SharedModelObserver`, `SharedLayersObserver`, `SharedRenderingOptionsObserver`) are managed together under a single `@observers_attached` guard. Observers are only detached when both fixes are disabled. This prevents the two fixes from removing each other's observers, which was the failure mode when they were independent plugins.

**`RubberBandTool` re-push** — `SharedToolsObserver#onActiveToolChanged` detects when the native select tool (ID `21022`) becomes active and re-pushes `RubberBandTool` on top via a `UI.start_timer(0)` deferred call. The timer avoids re-entering the tools stack mid-callback.

**`suppress_reattach`** — When `RubberBandTool` detects a double-click on a group/component, it must hand off to the native select tool to process the edit mode entry. It calls `suppress_reattach`, which temporarily sets `@rubber_band_enabled = false` for 0.3 s, then pops itself. Without the suppression window the `ToolsObserver` timer would immediately re-push `RubberBandTool` before the native tool could enter edit mode.

**`active_path.nil?` guard** — The native select tool uses the same tool ID (`21022`) both at the top level and inside component/group edit contexts. The re-push logic checks `active_path.nil?` to avoid pushing `RubberBandTool` inside an edit context, which would break exiting edit mode.

**`WineFixAppObserver`** — Registered at application level via `Sketchup.add_observer`. Calls `reattach_for_new_model` on `onNewModel`/`onOpenModel` because SketchUp creates a new model object on each open/new event, orphaning any observers attached to the previous model object. `expectsStartupModelNotifications` returns `true` so startup also triggers the attach.

**Driver detection and persistent toggles** — `wayland_driver?` returns true if `DISPLAY` is unset/empty or Wine's `HKCU\Software\Wine\Drivers\Graphics` value is exactly `wayland`. `start` reads saved settings from the `NH_WineSketchupFix` defaults section. On first run the rubber band fix defaults to on and the view refresh fix defaults to on only when not on Wayland. Two `UI::Command` entries under `Plugins` toggle each fix, and `save_settings` persists the choice.

## Architecture: `wine_wayland_menu_fix.rb`

Everything lives in `NH::WineWaylandMenuFix`. It shares nothing with `NH::WineSketchupFix` and must stay independent.

**Modes** — `auto` (active only when Wayland is detected, default), `on`, `off`. Chosen from a `Plugins → Wine Wayland Menu Fix` submenu and persisted under `NH_WineWaylandMenuFix`. There is also a non-persisted debug logging toggle.

**Looser detection** — `detect_wayland` treats `wayland` as the *first* entry of the Graphics value (e.g. `wayland,x11`) as Wayland. This is deliberately less strict than `wayland_driver?` in the main plugin: a false positive only costs a few refreshes when a menu opens, while a false negative leaves menus hidden.

**Fail-safe** — If Fiddle/`user32` cannot be loaded, the add-on logs the error and stays inactive. Any exception in `tick` stops the timer and sets `@failed` so it does not retry.

**Menu identity** — Menus are tracked as `[handle, left, top, right, bottom]` so that a reused menu window shown at a new position (moving between menu-bar dropdowns) counts as a newly opened menu.

**Reload-safe** — The startup section calls `stop` first and the menu is guarded by `file_loaded?`, so the file can be re-`load`ed from the Ruby Console.
