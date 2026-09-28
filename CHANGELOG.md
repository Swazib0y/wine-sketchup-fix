# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Wayland menu fix 1.0.0] - 2026-09-28
### Added
- New independent add-on, wine_wayland_menu_fix.rb. It fixes menus hidden
  behind the canvas under Wine's native Wayland driver: menu-bar dropdowns,
  right-click menus and submenus. It detects each newly opened menu and
  refreshes the canvas, which makes Wine restack the canvas beneath the menu.
- The add-on is active by default only under the Wayland driver. Plugins menu
  modes are Auto, Always on and Off, and the choice is remembered between
  sessions.
- README: root cause and installation for the menu fix.

### Changed
- README: the menu known limitation now also covers right-click menus and
  submenus, which were found to be affected, and points to the menu fix.

## [1.1.0] - 2026-09-17
### Added
- Graphics driver detection at startup. The view refresh fix is now enabled
  automatically only under XWayland or native X11; Wine's native Wayland driver
  resolves the one-frame render delay and the vertex snap indicator offset on
  its own. Detection uses the DISPLAY environment variable and Wine's Graphics
  registry value.
- Plugins menu toggle states are now remembered between sessions via
  Sketchup.read_default / write_default.
- README: setup instructions for Wine's native Wayland driver, including the
  registry value, launch command, desktop launcher with StartupWMClass, and
  diagnostics for checking the active driver and GPU.

### Changed
- Corrected the documented root cause of the missing rubber band. An OpenGL
  call trace shows SketchUp drawing overlays to the front buffer, which a
  compositing display server does not reliably present. The $stdout.flush fix
  is empirical; why it works is not established.
- Removed references to WINE_OPENGL_BACKEND=glx, which is not a Wine
  environment variable and had no effect. The real switch is the UseEGL
  registry value, documented under Diagnostics.

### Fixed
- Nothing in plugin behaviour; this release changes defaults and documentation.

### Notes
- Testing in September 2026 ruled out the EGL backend as the cause of the
  missing rubber band: forcing GLX (UseEGL=N), the native Wayland driver, a
  Wine virtual desktop and Wine 11.17 all still require the fix.
- Known limitations added for the native Wayland driver: menu bar dropdowns
  are drawn behind the viewport, and non-maximised windows can pan by
  themselves near the viewport edges.

---

## [1.0.2] - 2026-04-17
### Fixed
- Clicking outside a component or group to exit edit mode no longer fails after
  orbiting or panning with the middle mouse button. Root cause was the
  ToolsObserver re-pushing RubberBandTool inside component edit contexts because
  the native select tool uses the same tool ID (21022) both at the top level and
  inside edit mode. Fixed by checking `active_path.nil?` before re-pushing.

---

## [1.0.1] - 2026-04-17
### Fixed
- Double-clicking a component or group now correctly enters edit mode. Previously
  our RubberBandTool was intercepting all double-click events and preventing the
  native select tool from handling edit mode entry. Fixed by temporarily
  suppressing the ToolsObserver re-push via `suppress_reattach` and popping our
  tool to hand off to the native select tool.

---

## [1.0.0] - 2026-04-16
### Added
- Initial release
- Rubber band selection box fix for Wine 10.17+ (draw2d EGL buffer swap timing)
- View refresh fix for one-frame render delay
- Window selection (left-to-right drag, green box)
- Crossing selection (right-to-left drag, blue box)
- Single click select and deselect
- Shift-click to add to or remove from selection
- Double-click on face/edge to select entity and connected geometry
- Triple-click to select all connected geometry
- Both fixes share a single observer set to prevent observer conflict issues
- Both fixes individually toggleable via Plugins menu
