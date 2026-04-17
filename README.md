# wine-sketchup-fix

A SketchUp 2017 plugin that fixes two rendering issues when running under Wine on Linux:

1. **One-frame render delay** — view state changes (selections, geometry edits, tool switches) are not reflected until the next user interaction
2. **Missing rubber band selection box** — the drag-to-select rectangle is not visible during mouse drag operations

Both issues are caused by Wine's OpenGL rendering behaviour and are not present on native Windows installations.

---

## Root Causes

### One-frame render delay
SketchUp's view invalidation under Wine does not trigger an immediate repaint. The fix attaches observers to SketchUp's model, view, selection, tool, layer, and rendering options events and forces a synchronous `invalidate.refresh` on each change.

### Missing rubber band selection box
SketchUp draws the rubber band selection rectangle using `draw2d` — a 2D orthographic overlay rendered on top of the 3D viewport. Under Wine, the OpenGL buffer swap consumes the `draw2d` output before it is composited onto the frame, making it invisible.

The fix implements a custom Ruby select tool that replicates SketchUp's native selection behaviour. A `$stdout.flush` call immediately before the `draw2d` call introduces enough timing slack to allow the overlay to be composited correctly before the buffer swap occurs.

Both fixes share a single set of SketchUp observers. This prevents the two fixes from accidentally removing each other's observers — a known issue when multiple plugins independently register `ToolsObserver` instances on the same model.

---

## System Requirements

- SketchUp 2017 (64-bit) installed under Wine
- Wine 10.x (staging recommended) or later
- Linux with Wayland/XWayland (recommended) or X11
- NVIDIA, AMD, or Intel GPU with working OpenGL 4.x drivers

### Tested Configuration
- Fedora 42, GNOME 48, Wayland
- Wine Staging 10.20
- NVIDIA GeForce RTX 3090 Ti, driver 580.126.18
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

### Optional flag

```
WINE_OPENGL_BACKEND=glx
```

Forces Wine to use the GLX backend instead of EGL. This is redundant under Wayland/XWayland (where GLX is used by default) but may be needed on some native X11 configurations where Wine defaults to EGL and produces an incorrect `RGBA:8-8-8-0` pixel format.

### Example launch command

```bash
WINEPREFIX=~/.wine-sketchup \
WINEDLLOVERRIDES="libglesv2=d" \
wine "C:/Program Files/SketchUp/SketchUp 2017/SketchUp.exe"
```

### GNOME desktop launcher

When SketchUp is installed under Wine, a `.desktop` file is automatically created at:

```
~/.local/share/applications/wine/Programs/SketchUp 2017/SketchUp.desktop
```

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

Both fixes can be individually toggled via **Plugins → View Refresh Fix for Wine** and **Plugins → Rubber Band Fix for Wine**. Both are enabled by default on startup.

---

## Known Limitations

### Axis inference initialisation
The red/green/blue axis snap guides require at least one successful snap to a point before they activate for the session. Snapping to the model origin (0,0,0) at the start of each session will initialise them. This is a pre-existing Wine behaviour and is not caused by this plugin.

### X11 axis inference
Axis inference lines do not display correctly under native X11. Wayland/XWayland is recommended for best results.

### Snap indicator delay
The snap point indicator (the small circle that appears when hovering near snap points) may lag by one frame under some configurations. This is a pre-existing Wine behaviour that the view refresh fix partially mitigates but does not fully resolve.

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

### Check Wine OpenGL backend
To confirm Wine is using GLX rather than EGL, run SketchUp with OpenGL debug logging:

```bash
WINEPREFIX=<prefix> WINEDEBUG=+wgl wine SketchUp.exe 2>&1 | grep -i "glxdrv\|egldrv" | head -5
```

You should see `glxdrv` in the output. If you see `egldrv`, add `WINE_OPENGL_BACKEND=glx` to your launch command.

---

## Attribution

- View refresh fix originally authored by **Nick Hogle** ([DSDev-NickHogle](https://github.com/DSDev-NickHogle))
- Extended by **Ivo Tsanov** ([itsanov](https://github.com/itsanov)) — [original gist](https://gist.github.com/itsanov/a6b9016dff5a5c0ee270ff8b82ebf66f)
- Rubber band selection fix and plugin merge by **[Swazib0y](https://github.com/Swazib0y)**, developed with [Claude](https://claude.ai) (Anthropic), 2026

---

## License

MIT
