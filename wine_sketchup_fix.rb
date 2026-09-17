# Name:        Wine SketchUp Fix
# Description: Fixes missing rubber band selection box and (on XWayland only)
#              the one-frame render delay when running SketchUp 2017 under
#              Wine on Linux
# Author:      Swazib0y, based on work by Nick Hogle (DSDev-NickHogle)
#              and Ivo Tsanov (itsanov)
# Version:     1.1.0
# Date:        2026-09-17
# License:     MIT
#
# Attribution:
#   View refresh fix originally authored by Nick Hogle (DSDev-NickHogle)
#   Extended by Ivo Tsanov (itsanov)
#   Source: https://gist.github.com/itsanov/a6b9016dff5a5c0ee270ff8b82ebf66f
#
#   Rubber band selection fix developed with Claude (Anthropic), 2026
#   Both fixes merged into a single plugin to prevent observer conflicts.
#
# Background:
#   SketchUp 2017 draws its temporary overlays (the rubber band selection
#   rectangle, inference markers) directly to the OpenGL FRONT buffer rather
#   than the back buffer. An OpenGL call trace under Wine 11 shows a repeated
#   glDrawBuffer(GL_FRONT) / draw / glFinish / glDrawBuffer(GL_BACK) cycle.
#   Front buffer drawing is not reliably presented on a compositing display
#   server, so the rubber band is invisible.
#
#   A $stdout.flush call immediately before draw2d restores the rubber band.
#   Why it works has not been established - it is an empirical fix. An earlier
#   version of this plugin attributed the problem to the EGL backend introduced
#   in Wine 10.17, but testing in September 2026 disproved that: forcing the
#   GLX backend (UseEGL=N) does not bring the rubber band back, and neither
#   does Wine's native Wayland driver.
#
# Fixes:
#   1. One-frame render delay (view refresh fix) - XWayland/X11 only
#   2. Missing rubber band selection box (draw2d flush fix) - all drivers
#   3. Component and group edit mode entry via double-click
#
# Graphics driver detection:
#   Wine's native Wayland driver resolves the one-frame render delay and the
#   vertex snap indicator offset on its own, so fix 1 is enabled automatically
#   only when SketchUp is running through XWayland or native X11. Detection
#   uses the DISPLAY environment variable and Wine's Graphics registry value.
#   Both fixes can be overridden from the Plugins menu, and those choices are
#   remembered between sessions.
#
# Install to:
#   <WINEPREFIX>/drive_c/users/<username>/AppData/Roaming/SketchUp/
#     SketchUp 2017/SketchUp/Plugins/
#
# To find your plugins folder, run:
#   find <WINEPREFIX> -name "Plugins" -type d
#
# Default WINEPREFIX is ~/.wine if you did not specify a custom one.
#
# Required launch flags:
#   WINEDLLOVERRIDES="libglesv2=d" - Fixes web content panels (3D Warehouse,
#                                    Extension Warehouse etc.)
#
# Recommended configuration (see README):
#   Wine's native Wayland driver, enabled with the Graphics registry value
#   and by launching with DISPLAY unset.
#
# Known limitations:
#   - Native Wayland driver: menu bar dropdowns are drawn behind the viewport
#     where they overlap it. Right-click context menus are unaffected.
#   - Native Wayland driver: in a non-maximised window the viewport may pan by
#     itself near its edges, and panning can hit an invisible boundary. Running
#     maximised avoids both.
#   - Axis inference lines (red/green/blue snap guides) require one successful
#     snap to a point before activating. Snapping to the origin (0,0,0) at
#     the start of each session will initialise them. This is a pre-existing
#     Wine behaviour unrelated to this plugin.
#   - Axis inference lines do not display correctly under native X11.
#     The native Wayland driver is recommended.

require 'sketchup'

module NH
  module WineSketchupFix

    # The tool ID for SketchUp's native select tool. Used to detect when
    # the native select tool becomes active so we can re-push our replacement.
    NATIVE_SELECT_TOOL_ID = 21022

    # Registry section used by Sketchup.read_default / write_default to
    # remember the enabled state of each fix between sessions.
    SETTINGS_SECTION = 'NH_WineSketchupFix'.freeze

    # =========================================================================
    # RubberBandTool
    #
    # A complete replacement for SketchUp's native select tool that draws a
    # visible rubber band selection box using draw2d with a $stdout.flush
    # timing fix for Wine's OpenGL buffer swap issue.
    #
    # Implements:
    #   - Single click:           select / deselect entity under cursor
    #   - Shift + click:          add to / remove from selection
    #   - Left-to-right drag:     window selection (entities fully inside box)
    #   - Right-to-left drag:     crossing selection (entities touching box)
    #   - Double click on face/edge:       select entity + connected geometry
    #   - Double click on group/component: enter edit mode
    #   - Triple click:           select all connected geometry
    #
    # SketchUp's Ruby API click event sequence:
    #   Single click:  DOWN -> UP
    #   Double click:  DOWN -> UP -> DOWN -> DOUBLE_CLICK
    #   Triple click:  DOWN -> UP -> DOWN -> DOUBLE_CLICK -> DOWN -> UP
    # =========================================================================
    class RubberBandTool

      def initialize
        reset
        @last_click_time     = 0   # time of last button down event
        @click_count         = 0   # rapid click counter for double/triple detection
        @just_double_clicked = false # true after onLButtonDoubleClick fires
        @last_double_click_x = 0   # screen x of last double click
        @last_double_click_y = 0   # screen y of last double click
      end

      # Resets drag state between interactions. Does not reset click tracking
      # variables as these need to persist across the double/triple click sequence.
      def reset
        @dragging   = false
        @mouse_down = false
        @x1 = @y1 = @x2 = @y2 = nil
      end

      # -----------------------------------------------------------------------
      # Mouse event handlers
      # -----------------------------------------------------------------------

      def onLButtonDown(flags, x, y, view)
        now = Time.now.to_f
        @click_count = (now - @last_click_time < 0.5) ? @click_count + 1 : 1
        @last_click_time = now
        @mouse_down = true
        @dragging   = false
        @x1 = @x2  = x
        @y1 = @y2  = y
        view.invalidate
      end

      def onMouseMove(flags, x, y, view)
        return unless @mouse_down
        @x2 = x
        @y2 = y
        @dragging = true if !@dragging && ((@x2 - @x1).abs > 1 || (@y2 - @y1).abs > 1)
        view.invalidate if @dragging
      end

      def onLButtonUp(flags, x, y, view)
        if @dragging
          # Rubber band drag - perform area selection
          perform_selection(flags, x, y, view)
          @click_count         = 0
          @just_double_clicked = false

        elsif @just_double_clicked && @click_count >= 2
          # Triple click - select all connected geometry using the coordinates
          # captured during the double click event
          ph = view.pick_helper
          ph.do_pick(@last_double_click_x, @last_double_click_y)
          picked = ph.best_picked
          if picked
            view.model.selection.clear
            view.model.selection.add(picked.all_connected)
          end
          @just_double_clicked = false
          @click_count         = 0

        else
          # Single click (also handles click after double click to deselect)
          @just_double_clicked = false
          ph = view.pick_helper
          ph.do_pick(x, y)
          picked = ph.best_picked
          unless flags & COPY_MODIFIER_MASK == COPY_MODIFIER_MASK
            view.model.selection.clear
          end
          view.model.selection.add(picked) if picked
        end

        reset
        view.invalidate
        view.refresh
      end

      def onLButtonDoubleClick(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        picked = ph.best_picked
        return unless picked

        if picked.is_a?(Sketchup::Group) || picked.is_a?(Sketchup::ComponentInstance)
          # Double click on group/component - enter edit mode.
          # We select the entity, temporarily suppress the ToolsObserver re-push
          # (so our tool doesn't get pushed back before the native select tool
          # can process the edit mode entry), then pop our tool to hand off
          # to the native select tool which handles the actual edit mode entry.
          view.model.selection.clear
          view.model.selection.add(picked)
          NH::WineSketchupFix.suppress_reattach
          view.model.tools.pop_tool

        else
          # Double click on face/edge - select entity and directly connected geometry.
          # Sets @just_double_clicked so onLButtonUp can detect a subsequent
          # triple click on its next invocation.
          view.model.selection.clear
          view.model.selection.add(picked)
          if picked.is_a?(Sketchup::Face)
            view.model.selection.add(picked.edges)
          elsif picked.is_a?(Sketchup::Edge)
            view.model.selection.add(picked.faces)
          end
          @just_double_clicked = true
          @last_double_click_x = x
          @last_double_click_y = y
          view.invalidate
          view.refresh
        end
      end

      # -----------------------------------------------------------------------
      # Selection logic
      # -----------------------------------------------------------------------

      # Performs rubber band selection based on drag direction:
      #   Left-to-right: window selection - entity bounding box must be fully inside
      #   Right-to-left: crossing selection - entity bounding box need only intersect
      def perform_selection(flags, x, y, view)
        x1 = [@x1, x].min
        y1 = [@y1, y].min
        x2 = [@x1, x].max
        y2 = [@y1, y].max

        unless flags & COPY_MODIFIER_MASK == COPY_MODIFIER_MASK
          view.model.selection.clear
        end

        crossing = @x1 > x  # right-to-left drag = crossing selection

        view.model.active_entities.each do |e|
          next unless e.is_a?(Sketchup::Face)             ||
                      e.is_a?(Sketchup::Edge)             ||
                      e.is_a?(Sketchup::Group)            ||
                      e.is_a?(Sketchup::ComponentInstance)
          begin
            corners = (0..7).map { |i| view.screen_coords(e.bounds.corner(i)) }
            min_ex  = corners.map(&:x).min
            max_ex  = corners.map(&:x).max
            min_ey  = corners.map(&:y).min
            max_ey  = corners.map(&:y).max

            if crossing
              view.model.selection.add(e) if min_ex <= x2 && max_ex >= x1 &&
                                             min_ey <= y2 && max_ey >= y1
            else
              view.model.selection.add(e) if min_ex >= x1 && max_ex <= x2 &&
                                             min_ey >= y1 && max_ey <= y2
            end
          rescue
            # Skip entities whose bounds cannot be projected to screen space
          end
        end
      end

      # -----------------------------------------------------------------------
      # Rendering
      # -----------------------------------------------------------------------

      def draw(view)
        return unless @dragging && @x1

        # $stdout.flush is an empirical fix: without it the rubber band drawn
        # by draw2d below is never presented on screen under Wine. SketchUp
        # draws these overlays to the OpenGL front buffer, which a compositing
        # display server does not reliably present. Confirmed still required
        # with both the EGL and GLX backends, and with Wine's native Wayland
        # driver (Wine 11.0 and 11.17, September 2026).
        $stdout.flush

        color = @x1 > @x2 ?
          Sketchup::Color.new(0, 100, 255, 255) :   # right-to-left: crossing (blue)
          Sketchup::Color.new(0, 180, 0,   255)      # left-to-right: window (green)
        view.drawing_color = color
        view.line_width    = 1
        view.draw2d(GL_LINE_LOOP, [
          Geom::Point3d.new(@x1, @y1, 0),
          Geom::Point3d.new(@x2, @y1, 0),
          Geom::Point3d.new(@x2, @y2, 0),
          Geom::Point3d.new(@x1, @y2, 0)
        ])
      end

      # -----------------------------------------------------------------------
      # Tool lifecycle callbacks
      # -----------------------------------------------------------------------

      def deactivate(view)
        reset
        @just_double_clicked = false
        @click_count         = 0
        view.invalidate
        view.refresh
      end

      def suspend(view)
        reset
        view.invalidate
      end

      def resume(view)
        view.invalidate
      end

      def getInstructorContentDirectory
        nil
      end

    end # class RubberBandTool

    # =========================================================================
    # Shared Observers
    #
    # All observers are managed as a single set to prevent the two fixes from
    # accidentally removing each other's observers. This was a known failure
    # mode when the view refresh fix and rubber band fix each independently
    # registered a ToolsObserver on the same model.
    #
    # The SharedToolsObserver handles both concerns:
    #   - View refresh: forces a redraw on tool state changes
    #   - Rubber band:  re-pushes RubberBandTool when the native select tool
    #                   becomes active (e.g. after spacebar or tool switch)
    # =========================================================================

    # Listens for tool activation and state changes. Handles both the view
    # refresh fix and the rubber band tool re-push.
    class SharedToolsObserver < Sketchup::ToolsObserver
      def onActiveToolChanged(tools, tool_name, tool_id)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?

        # Re-push our rubber band tool on top of the native select tool.
        # Uses a timer to avoid re-entering the tools stack mid-callback.
        if NH::WineSketchupFix.rubber_band_enabled? && tool_id == NATIVE_SELECT_TOOL_ID
          UI.start_timer(0, false) {
            if NH::WineSketchupFix.rubber_band_enabled? &&
                Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID &&
                Sketchup.active_model.active_path.nil?
              Sketchup.active_model.tools.push_tool(RubberBandTool.new)
            end
          }
        end
      end

      def onToolStateChanged(tools, tool_name, tool_id, tool_state)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    # Listens for camera/view changes (orbit, pan, zoom) and forces a redraw.
    class SharedViewObserver < Sketchup::ViewObserver
      def onViewChanged(view)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    # Listens for selection changes and forces a redraw so the selection
    # highlight updates without requiring further user interaction.
    class SharedSelectionObserver < Sketchup::SelectionObserver
      def onSelectionBulkChange(selection)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
      def onSelectionCleared(selection)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    # Listens for model-level events (transactions, component placement, etc.)
    # and forces a redraw to reflect geometry changes immediately.
    class SharedModelObserver < Sketchup::ModelObserver
      def onActivePathChanged(model);  NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onEraseAll(model);           NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onExplode(model);            NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onTransactionCommit(model);  NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onTransactionAbort(model);   NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onTransactionRedo(model);    NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onTransactionUndo(model);    NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onDeleteModel(model);        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onPlaceComponent(instance);  NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
    end

    # Listens for layer visibility and ordering changes and forces a redraw.
    class SharedLayersObserver < Sketchup::LayersObserver
      def onCurrentLayerChanged(layers, layer); NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerAdded(layers, layer);          NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerChanged(layers, layer);        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerRemoved(layers, layer);        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onRemoveAllLayers(layers);            NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
    end

    # Listens for rendering option changes (edge style, face style, shadows etc.)
    # and forces a redraw so style changes are reflected immediately.
    class SharedRenderingOptionsObserver < Sketchup::RenderingOptionsObserver
      def onRenderingOptionsChanged(rendering_options, type)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    # =========================================================================
    # Module state
    # =========================================================================

    @view_fix_enabled    = false  # whether the view refresh fix is active
    @rubber_band_enabled = false  # whether the rubber band fix is active
    @observers_attached  = false  # whether observers are attached to the current model

    # Observer instance references - kept so we can remove them cleanly
    @tools_observer             = nil
    @view_observer              = nil
    @selection_observer         = nil
    @model_observer             = nil
    @layer_observer             = nil
    @rendering_options_observer = nil

    # =========================================================================
    # Public API
    # =========================================================================

    def self.view_fix_enabled?;    @view_fix_enabled;    end
    def self.rubber_band_enabled?; @rubber_band_enabled; end

    def self.enable_view_fix
      @view_fix_enabled = true
      attach_observers
      save_settings
    end

    def self.disable_view_fix
      @view_fix_enabled = false
      detach_observers unless @rubber_band_enabled
      save_settings
    end

    def self.enable_rubber_band
      @rubber_band_enabled = true
      attach_observers
      if Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
      save_settings
    end

    def self.disable_rubber_band
      @rubber_band_enabled = false
      detach_observers unless @view_fix_enabled
      while Sketchup.active_model.tools.active_tool_id != NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.pop_tool
      end
      save_settings
    end

    # Returns true when SketchUp appears to be running on Wine's native
    # Wayland driver rather than through XWayland or native X11.
    #
    # Two independent signals are used because neither is conclusive alone:
    #   - DISPLAY is unset: Wine cannot load the X11 driver without it
    #   - Wine's Graphics registry value is exactly "wayland"
    # A mixed setting such as "wayland,x11" with DISPLAY set is ambiguous and
    # is treated as not-Wayland; use the Plugins menu to override.
    def self.wayland_driver?
      display = ENV['DISPLAY']
      return true if display.nil? || display.empty?

      graphics = nil
      begin
        require 'win32/registry'
        Win32::Registry::HKEY_CURRENT_USER.open('Software\\Wine\\Drivers') do |reg|
          graphics = reg['Graphics']
        end
      rescue LoadError, StandardError
        # Value absent (the usual case on XWayland) or registry unreadable
        graphics = nil
      end

      graphics.to_s.strip.downcase == 'wayland'
    end

    # Writes the current enabled state of both fixes so they are restored on
    # the next launch.
    def self.save_settings
      Sketchup.write_default(SETTINGS_SECTION, 'view_fix_enabled',    @view_fix_enabled)
      Sketchup.write_default(SETTINGS_SECTION, 'rubber_band_enabled', @rubber_band_enabled)
    end

    # Applies the saved settings on startup. On first run the defaults are:
    #   - rubber band fix: enabled on every graphics driver
    #   - view refresh fix: enabled only on XWayland/X11, where it is needed
    def self.start
      @view_fix_enabled = Sketchup.read_default(
        SETTINGS_SECTION, 'view_fix_enabled', !wayland_driver?
      )
      @rubber_band_enabled = Sketchup.read_default(
        SETTINGS_SECTION, 'rubber_band_enabled', true
      )

      attach_observers if @view_fix_enabled || @rubber_band_enabled

      if @rubber_band_enabled &&
         Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
    end

    # Re-attaches observers to the new model object after a new/open model event.
    # Required because SketchUp creates a new model object on open/new, making
    # any previously attached observers orphaned on the old model object.
    def self.reattach_for_new_model
      detach_observers
      @observers_attached = false
      attach_observers if @view_fix_enabled || @rubber_band_enabled
      if @rubber_band_enabled &&
         Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
    end

    # =========================================================================
    # Internal helpers
    # =========================================================================

    # Forces an immediate synchronous view refresh. Used by all observer
    # callbacks to work around Wine's one-frame render delay.
    def self.refresh
      UI.start_timer(0, false) {
        Sketchup.active_model.active_view.invalidate.refresh
      }
    end

    # Temporarily suppresses rubber band re-push to allow the native select
    # tool to enter component/group edit mode without being immediately
    # overridden by our ToolsObserver timer. The suppression window of 0.3s
    # is long enough for the native tool to process the edit mode entry but
    # short enough to be imperceptible to the user.
    def self.suppress_reattach
      @rubber_band_enabled = false
      UI.start_timer(0.3, false) {
        @rubber_band_enabled = true
      }
    end

    # Attaches all shared observers to the current model. Guards against
    # double-attachment with @observers_attached flag.
    def self.attach_observers
      return if @observers_attached
      model = Sketchup.active_model

      @tools_observer = SharedToolsObserver.new
      model.tools.add_observer(@tools_observer)

      @view_observer = SharedViewObserver.new
      model.active_view.add_observer(@view_observer)

      @selection_observer = SharedSelectionObserver.new
      model.selection.add_observer(@selection_observer)

      @model_observer = SharedModelObserver.new
      model.add_observer(@model_observer)

      @layer_observer = SharedLayersObserver.new
      model.layers.add_observer(@layer_observer)

      @rendering_options_observer = SharedRenderingOptionsObserver.new
      model.rendering_options.add_observer(@rendering_options_observer)

      @observers_attached = true
    end

    # Removes all shared observers from the current model and clears references.
    def self.detach_observers
      return unless @observers_attached
      model = Sketchup.active_model

      model.tools.remove_observer(@tools_observer)                         if @tools_observer
      model.active_view.remove_observer(@view_observer)                    if @view_observer
      model.selection.remove_observer(@selection_observer)                 if @selection_observer
      model.remove_observer(@model_observer)                               if @model_observer
      model.layers.remove_observer(@layer_observer)                        if @layer_observer
      model.rendering_options.remove_observer(@rendering_options_observer) if @rendering_options_observer

      @tools_observer             = nil
      @view_observer              = nil
      @selection_observer         = nil
      @model_observer             = nil
      @layer_observer             = nil
      @rendering_options_observer = nil
      @observers_attached         = false
    end

  end # module WineSketchupFix
end # module NH

# =============================================================================
# Menu items
# =============================================================================

view_fix_cmd = UI::Command.new("View Refresh Fix for Wine") {
  if NH::WineSketchupFix.view_fix_enabled?
    NH::WineSketchupFix.disable_view_fix
  else
    NH::WineSketchupFix.enable_view_fix
  end
}
view_fix_cmd.menu_text = "View Refresh Fix for Wine"
view_fix_cmd.set_validation_proc {
  NH::WineSketchupFix.view_fix_enabled? ? MF_CHECKED : MF_UNCHECKED
}

rubber_band_cmd = UI::Command.new("Rubber Band Fix for Wine") {
  if NH::WineSketchupFix.rubber_band_enabled?
    NH::WineSketchupFix.disable_rubber_band
  else
    NH::WineSketchupFix.enable_rubber_band
  end
}
rubber_band_cmd.menu_text = "Rubber Band Fix for Wine"
rubber_band_cmd.set_validation_proc {
  NH::WineSketchupFix.rubber_band_enabled? ? MF_CHECKED : MF_UNCHECKED
}

UI.menu("Plugins").add_item(view_fix_cmd)
UI.menu("Plugins").add_item(rubber_band_cmd)

# =============================================================================
# AppObserver
#
# Re-attaches all observers when a new or opened model is loaded. Required
# because SketchUp creates a new model object on each open/new event, which
# orphans observers attached to the previous model object.
# =============================================================================
class WineFixAppObserver < Sketchup::AppObserver
  def onNewModel(model)
    NH::WineSketchupFix.reattach_for_new_model
  end
  def onOpenModel(model)
    NH::WineSketchupFix.reattach_for_new_model
  end
  def expectsStartupModelNotifications
    true
  end
end

Sketchup.add_observer(WineFixAppObserver.new)

# =============================================================================
# Apply saved settings on startup
#
# On first run the rubber band fix is enabled on every graphics driver, and
# the view refresh fix only on XWayland/X11 where it is needed. Thereafter the
# Plugins menu choices are restored.
# =============================================================================
NH::WineSketchupFix.start
