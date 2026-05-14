# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
