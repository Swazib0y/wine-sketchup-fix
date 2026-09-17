# wine-sketchup-fix

A SketchUp 2017 plugin that fixes two rendering issues when running under Wine on Linux:

1. **Missing rubber band selection box** — the drag-to-select rectangle is not visible during mouse drag operations
2. **One-frame render delay** — view state changes (selections, geometry edits, tool switches) are not reflected until the next user interaction

Both issues are caused by Wine's rendering and display behaviour and are not present on native Windows installations.

Which fixes you need depends on the Wine graphics driver in use. Wine's **native Wayland driver** resolves the render delay and a vertex snap indicator offset on its own, leaving only the rubber band to fix. Under **XWayland** or **native X11**, both fixes are needed. The plugin detects this at startup and enables the appropriate fixes automatically.

---

## Root Causes

### Missing rubber band selection box
SketchUp draws its temporary overlays — the rubber band rectangle and inference markers — directly to the OpenGL **front buffer** rather than the back buffer. An OpenGL call trace under Wine 11 shows a repeated `glDrawBuffer(GL_FRONT)` / draw / `glFinish` / `glDrawBuffer(GL_BACK)` cycle. Front buffer drawing is not reliably presented by a compositing display server, so the rectangle never appears.

The fix implements a custom Ruby select tool that replicates SketchUp's native selection behaviour, with a `$stdout.flush` call immediately before `draw2d`. **Why that works has not been established** — it is an empirical fix.

> **Correction:** versions up to 1.0.2 attributed this to the EGL backend that became the default in Wine 10.17. Testing in September 2026 disproved that. Forcing the GLX backend (`UseEGL=N`) does not restore the rubber band, and neither does the native Wayland driver, a Wine virtual desktop, or Wine 11.17.

### One-frame render delay
SketchUp's view invalidation under Wine does not trigger an immediate repaint. The fix attaches observers to SketchUp's model, view, selection, tool, layer, and rendering options events and forces a synchronous `invalidate.refresh` on each change.

This delay comes from the XWayland path. Running on Wine's native Wayland driver removes it, along with a vertex snap indicator that is drawn offset from the cursor. The plugin therefore leaves this fix off when it detects that driver.

Both fixes share a single set of SketchUp observers. This prevents them from removing each other's observers — a known issue when multiple plugins independently register `ToolsObserver` instances on the same model.

---

## System Requirements

- SketchUp 2017 (64-bit) installed under Wine
- Wine 10.x (staging recommended) or later; Wine 9.22 or later for the native Wayland driver
- Linux with a Wayland session (recommended) or X11
- NVIDIA, AMD, or Intel GPU with working OpenGL 4.x drivers

### Tested Configuration
- Fedora 43, GNOME, Wayland session
- Wine Staging 11.0 (also verified on 11.17)
- NVIDIA GeForce RTX 3090 Ti, driver 580.178.04
- SketchUp 2017 Make (64-bit)

---

## Installation

### 1. Find your SketchUp plugins folder

```bash
find <WINEPREFIX> -name "Plugins" -type d
```

If you used the default Wine prefix:

```bash
find ~/.wine -name "Plugins" -type d
```

The path will be something like:

```
<WINEPREFIX>/drive_c/users/<username>/AppData/Roaming/SketchUp/SketchUp 2017/SketchUp/Plugins/
```

### 2. Copy the plugin file

```bash
cp wine_sketchup_fix.rb "<path-to-plugins-folder>/"
```

### 3. Install IE8 web components (optional but recommended)

Required for SketchUp's web content panels (3D Warehouse, Extension Warehouse, etc.) to display correctly:

```bash
WINEPREFIX=<your-prefix> winetricks ie8
```

---

## Required Launch Configuration

### Environment flags

The following environment variable is required when launching SketchUp:

```
WINEDLLOVERRIDES="libglesv2=d"
```

This forces Wine to use its built-in GLES2 implementation for the embedded Chromium web helper (`sketchup_webhelper.exe`). Without it, web content panels will not render correctly after installing IE8.

### Recommended: Wine's native Wayland driver

On a Wayland desktop session, Wine uses XWayland by default. Switching to Wine's native Wayland driver removes the one-frame render delay and the vertex snap indicator offset, and panning and orbiting are noticeably smoother.

Enable it in your prefix:

```bash
WINEPREFIX=<your-prefix> wine reg add "HKCU\\Software\\Wine\\Drivers" /v Graphics /d wayland /f
```

Then launch with `DISPLAY` unset, which is what stops Wine from using XWayland:

```bash
env -u DISPLAY WINEPREFIX=<your-prefix> WINEDLLOVERRIDES="libglesv2=d" \
  wine "C:/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"
```

To confirm the driver in use, with SketchUp running:

```bash
for p in $(pgrep -f SketchUp.exe); do grep -oE '(winewayland|winex11)\.so' /proc/$p/maps; done | sort -u
```

Only `winewayland.so` should be listed. To revert to XWayland:

```bash
WINEPREFIX=<your-prefix> wine reg delete "HKCU\\Software\\Wine\\Drivers" /v Graphics /f
```

See **Known Limitations** for the trade-offs before switching.

### Example launch command

XWayland or X11:

```bash
WINEPREFIX=~/.wine-sketchup \
WINEDLLOVERRIDES="libglesv2=d" \
wine "C:/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"
```

Native Wayland driver, once the registry value above is set:

```bash
env -u DISPLAY \
WINEPREFIX=~/.wine-sketchup \
WINEDLLOVERRIDES="libglesv2=d" \
wine "C:/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"
```

### GNOME desktop launcher

When SketchUp is installed under Wine, a `.desktop` file is automatically created at:

```
~/.local/share/applications/wine/Programs/SketchUp 2017/SketchUp.desktop
```

#### Launcher for the native Wayland driver

Create `~/.local/share/applications/sketchup2017-wayland.desktop`, replacing `<username>` and the icon name with your own (find the icon with `grep "^Icon=" ~/.local/share/applications/wine/Programs/SketchUp\ 2017/SketchUp.desktop`):

```ini
[Desktop Entry]
Type=Application
Name=SketchUp 2017 (Wayland)
Exec=env -u DISPLAY WINEPREFIX=/home/<username>/.wine-sketchup WINEDLLOVERRIDES=libglesv2=d wine "/home/<username>/.wine-sketchup/drive_c/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"
Icon=D962_SketchUpIcon.0
StartupWMClass=sketchup.exe
Categories=Graphics;
```

`StartupWMClass` makes the running window group under this launcher in the dash. Wine's generated `SketchUp.desktop` claims the same window class, so remove that line from it, or GNOME may group the window under the wrong launcher:

```bash
sed -i '/^StartupWMClass=/d' ~/.local/share/applications/wine/Programs/SketchUp\ 2017/SketchUp.desktop
update-desktop-database ~/.local/share/applications
```

Note that Wine regenerates the files under `applications/wine/` when software is installed or updated in that prefix, so this may need repeating.

#### Known issue with .lnk shortcuts

Wine's automatically generated `.desktop` file launches SketchUp via a `.lnk` Windows shortcut file. Installing IE8 via winetricks breaks Wine's shell link resolution, causing the launcher to fail silently with:

```
ShellExecuteEx failed: File not found
```

The fix is to update the `Exec` line to point directly to the SketchUp executable instead of the `.lnk` shortcut, and to add the required `WINEDLLOVERRIDES` flag.

Edit the file:

```bash
nano ~/.local/share/applications/wine/Programs/SketchUp\ 2017/SketchUp.desktop
```

Replace the `Exec` line with:

```ini
Exec=env "WINEPREFIX=/home/<username>/.wine-sketchup" WINEDLLOVERRIDES="libglesv2=d" wine "C:\\\\Program Files\\\\SketchUp\\\\SketchUp 2017\\\\SketchUp.exe"
```

Note the quadruple backslashes — the `.desktop` file format requires backslashes to be escaped, and Windows paths also use backslashes, resulting in `\\\\` for each path separator.

Then update the desktop database:

```bash
update-desktop-database ~/.local/share/applications
```

> **Note:** On Wayland, `Alt+F2 → r` to restart the GNOME shell is not available. A full log out and log back in is required for the launcher changes to appear in the application menu.

---

## Features

The plugin implements a complete replacement for SketchUp's native select tool with the following behaviour:

| Action | Behaviour |
|--------|-----------|
| Single click on geometry | Selects the clicked entity |
| Single click on empty space | Clears selection |
| Shift + click | Adds to / removes from selection |
| Left-to-right drag | Window selection — selects entities fully inside the box |
| Right-to-left drag | Crossing selection — selects entities the box touches or crosses |
| Double click | Selects entity and directly connected geometry |
| Triple click | Selects all connected geometry |
| Spacebar / Escape | Returns to select tool without affecting selection |

The rubber band box is colour coded:
- **Green** — window selection (left to right)
- **Blue** — crossing selection (right to left)

Both fixes can be individually toggled via **Plugins → View Refresh Fix for Wine** and **Plugins → Rubber Band Fix for Wine**, and those choices are remembered between sessions.

On first run the defaults are set by graphics driver detection: the rubber band fix is enabled on every driver, and the view refresh fix only under XWayland or native X11. Detection uses the `DISPLAY` environment variable and Wine's `Graphics` registry value. A mixed setting such as `wayland,x11` with `DISPLAY` set is ambiguous and is treated as XWayland — use the menu toggle to override.

---

## Known Limitations

### Native Wayland driver: menu bar dropdowns
Dropdown menus from the menu bar are drawn behind the 3D viewport where they overlap it. The items are still there and can be clicked, but are not visible. Right-click context menus, toolbars and dialogs are unaffected. Present in Wine 11.0 and 11.17. The Wine developers listed child window rendering as an open item when OpenGL support was added to the Wayland driver.

### Native Wayland driver: non-maximised windows
In a non-maximised window the viewport may pan by itself when the cursor nears its edge, and panning can stop at an invisible boundary short of the right edge. Both appear after launch or a window resize and go away when the window is maximised. Cause not yet established.

### Native Wayland driver: no window decorations
GNOME does not draw title bars for native Wayland applications, and Wine's Wayland driver does not draw one either. Use **Super + drag** to move a window and **Super + right-drag** to resize.

### Native Wayland driver: no virtual desktop
`wine explorer /desktop=...` is ignored by the Wayland driver; SketchUp opens as a normal window.

### Axis inference initialisation
The red/green/blue axis snap guides require at least one successful snap to a point before they activate for the session. Snapping to the model origin (0,0,0) at the start of each session will initialise them. This is a pre-existing Wine behaviour and is not caused by this plugin.

### X11 axis inference
Axis inference lines do not display correctly under native X11. A Wayland session is recommended.

### XWayland: vertex snap indicator offset
Under XWayland the snap indicator can be drawn offset from the cursor on the first click of an operation, although the click itself registers at the correct point. The native Wayland driver resolves this.

---

## Diagnostics

### Verify OpenGL context
In SketchUp, go to **Window → Preferences → OpenGL → Graphics Card Details**. You should see your GPU listed as the renderer with GL Version 4.x. If you see `llvmpipe` or `softpipe`, Wine is using software rendering and GPU drivers need to be resolved first.

### Verify 32-bit libraries (if using 32-bit SketchUp)
SketchUp 2017 Make is available in both 32-bit and 64-bit versions. If using the 32-bit version, ensure 32-bit OpenGL libraries are installed:

```bash
# Debian/Ubuntu
sudo apt install mesa-libGL:i386

# Fedora
sudo dnf install mesa-libGL.i686 xorg-x11-drv-nvidia-libs.i686
```

### Check which graphics driver is in use
With SketchUp running:

```bash
for p in $(pgrep -f SketchUp.exe); do grep -oE '(winewayland|winex11)\.so' /proc/$p/maps; done | sort -u
```

`winewayland.so` means the native Wayland driver, `winex11.so` means XWayland or native X11.

### Check which GPU is rendering
On a hybrid graphics system, confirm SketchUp is on the discrete GPU:

```bash
nvidia-smi | grep -i sketchup
```

Rendering on a second GPU whose output is not connected to your monitors can fail entirely — under XWayland this shows up as a black viewport with `dri3_alloc_render_buffer` errors.

### Switch OpenGL backend (EGL/GLX)
Wine 10.17 and later default to EGL on X11. GLX can be forced for testing:

```bash
WINEPREFIX=<prefix> wine reg add "HKCU\\Software\\Wine\\X11 Driver" /v UseEGL /t REG_SZ /d N /f
```

Remove the value to go back to EGL. Note that there is no `WINE_OPENGL_BACKEND` environment variable; earlier versions of this README suggested one, and it had no effect.

---

## Attribution

- View refresh fix originally authored by **Nick Hogle** ([DSDev-NickHogle](https://github.com/DSDev-NickHogle))
- Extended by **Ivo Tsanov** ([itsanov](https://github.com/itsanov)) — [original gist](https://gist.github.com/itsanov/a6b9016dff5a5c0ee270ff8b82ebf66f)
- Rubber band selection fix and plugin merge by **[Swazib0y](https://github.com/Swazib0y)**, developed with [Claude](https://claude.ai) (Anthropic), 2026

---

## License

MIT
