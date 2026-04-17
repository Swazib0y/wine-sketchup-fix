# Name:        Wine SketchUp Fix
# Description: Fixes one-frame render delay and missing rubber band selection
#              box when running SketchUp 2017 under Wine on Linux
# Author:      Swazib0y, based on work by Nick Hogle (DSDev-NickHogle)
#              and Ivo Tsanov (itsanov)
# Version:     1.0.0
# Date:        2026-04-16
# License:     MIT
#
# Attribution:
#   View refresh fix originally authored by Nick Hogle (DSDev-NickHogle)
#   Extended by Ivo Tsanov (itsanov)
#   Source: https://gist.github.com/itsanov/a6b9016dff5a5c0ee270ff8b82ebf66f
#
#   Rubber band selection fix developed with Claude (Anthropic), 2026
#   Root cause: Wine's OpenGL buffer swap consumes draw2d output before the
#   2D overlay is composited onto the frame. A $stdout.flush call before
#   draw2d introduces just enough timing slack to allow correct compositing.
#   Both fixes merged into a single plugin to prevent observer conflicts.
#
# Fixes:
#   1. One-frame render delay (view refresh fix)
#   2. Missing rubber band selection box (draw2d timing fix)
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
# Optional launch flags:
#   WINE_OPENGL_BACKEND=glx        - Forces GLX backend. Redundant under
#                                    Wayland/XWayland but may be needed on
#                                    some X11 configurations to ensure correct
#                                    pixel format selection.
#
# Known limitations:
#   - Axis inference lines (red/green/blue snap guides) require one successful
#     snap to a point before activating. Snapping to the origin (0,0,0) at
#     the start of each session will initialise it. This is a pre-existing
#     Wine behaviour unrelated to this plugin.
#   - Axis inference lines do not display correctly under native X11.
#     Wayland/XWayland is recommended for best results.

require 'sketchup'

module NH
  module WineSketchupFix

    NATIVE_SELECT_TOOL_ID = 21022

    # -------------------------------------------------------------------------
    # Rubber Band Tool
    # Replaces the native select tool to draw a visible rubber band selection
    # box. Implements correct window (left-to-right) and crossing (right-to-left)
    # selection behaviour, single-click selection, shift-click to add to
    # selection, double-click to select connected geometry, and triple-click
    # to select all connected geometry.
    #
    # SketchUp's Ruby API click event sequence:
    #   Single click: DOWN -> UP
    #   Double click: DOWN -> UP -> DOWN -> DOUBLE_CLICK
    #   Triple click: DOWN -> UP -> DOWN -> DOUBLE_CLICK -> DOWN -> UP
    # -------------------------------------------------------------------------
    class RubberBandTool
      def initialize
        reset
        @last_click_time     = 0
        @click_count         = 0
        @just_double_clicked = false
        @last_double_click_x = 0
        @last_double_click_y = 0
      end

      def reset
        @dragging   = false
        @mouse_down = false
        @x1 = @y1 = @x2 = @y2 = nil
      end

      def onLButtonDown(flags, x, y, view)
        now = Time.now.to_f
        if now - @last_click_time < 0.5
          @click_count += 1
        else
          @click_count = 1
        end
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
        if !@dragging && ((@x2 - @x1).abs > 1 || (@y2 - @y1).abs > 1)
          @dragging = true
        end
        view.invalidate if @dragging
      end

      def onLButtonUp(flags, x, y, view)
        if @dragging
          perform_selection(flags, x, y, view)
          @click_count         = 0
          @just_double_clicked = false
        elsif @just_double_clicked && @click_count >= 2
          # Triple click - select all connected geometry
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
          # Single click (including after a double click) - pick entity under cursor
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
        # Double click - select entity and directly connected geometry
        ph = view.pick_helper
        ph.do_pick(x, y)
        picked = ph.best_picked
        if picked
          view.model.selection.clear
          view.model.selection.add(picked)
          if picked.is_a?(Sketchup::Face)
            view.model.selection.add(picked.edges)
          elsif picked.is_a?(Sketchup::Edge)
            view.model.selection.add(picked.faces)
          end
        end
        @just_double_clicked = true
        @last_double_click_x = x
        @last_double_click_y = y
        view.invalidate
        view.refresh
      end

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
            bounds  = e.bounds
            corners = (0..7).map { |i| view.screen_coords(bounds.corner(i)) }
            min_ex  = corners.map(&:x).min
            max_ex  = corners.map(&:x).max
            min_ey  = corners.map(&:y).min
            max_ey  = corners.map(&:y).max

            if crossing
              # Crossing: select if bounding box intersects selection rectangle
              view.model.selection.add(e) if min_ex <= x2 && max_ex >= x1 &&
                                             min_ey <= y2 && max_ey >= y1
            else
              # Window: select only if entire bounding box is inside selection rectangle
              view.model.selection.add(e) if min_ex >= x1 && max_ex <= x2 &&
                                             min_ey >= y1 && max_ey <= y2
            end
          rescue
            # Skip entities that can't be screen-projected
          end
        end
      end

      def draw(view)
        return unless @dragging && @x1
        # $stdout.flush is the key timing fix for Wine - without it, draw2d output
        # is swallowed by Wine's OpenGL buffer swap before the 2D overlay is
        # composited onto the frame
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
    end

    # -------------------------------------------------------------------------
    # Shared ToolsObserver
    # Single observer handling both the view refresh fix and rubber band re-push.
    # Using a single shared observer prevents the two fixes from accidentally
    # removing each other's observers via the SketchUp tools observer API.
    # -------------------------------------------------------------------------
    class SharedToolsObserver < Sketchup::ToolsObserver
      def onActiveToolChanged(tools, tool_name, tool_id)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?

        if NH::WineSketchupFix.rubber_band_enabled? && tool_id == NATIVE_SELECT_TOOL_ID
          UI.start_timer(0, false) {
            if NH::WineSketchupFix.rubber_band_enabled? &&
               Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
              Sketchup.active_model.tools.push_tool(RubberBandTool.new)
            end
          }
        end
      end

      def onToolStateChanged(tools, tool_name, tool_id, tool_state)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    class SharedViewObserver < Sketchup::ViewObserver
      def onViewChanged(view)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    class SharedSelectionObserver < Sketchup::SelectionObserver
      def onSelectionBulkChange(selection)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
      def onSelectionCleared(selection)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

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

    class SharedLayersObserver < Sketchup::LayersObserver
      def onCurrentLayerChanged(layers, layer); NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerAdded(layers, layer);          NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerChanged(layers, layer);        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onLayerRemoved(layers, layer);        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
      def onRemoveAllLayers(layers);            NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?; end
    end

    class SharedRenderingOptionsObserver < Sketchup::RenderingOptionsObserver
      def onRenderingOptionsChanged(rendering_options, type)
        NH::WineSketchupFix.refresh if NH::WineSketchupFix.view_fix_enabled?
      end
    end

    # -------------------------------------------------------------------------
    # Module state and methods
    # -------------------------------------------------------------------------
    @view_fix_enabled    = false
    @rubber_band_enabled = false
    @observers_attached  = false

    @tools_observer             = nil
    @view_observer              = nil
    @selection_observer         = nil
    @model_observer             = nil
    @layer_observer             = nil
    @rendering_options_observer = nil

    def self.view_fix_enabled?;    @view_fix_enabled;    end
    def self.rubber_band_enabled?; @rubber_band_enabled; end

    def self.refresh
      UI.start_timer(0, false) {
        Sketchup.active_model.active_view.invalidate.refresh
      }
    end

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

    def self.enable_view_fix
      @view_fix_enabled = true
      attach_observers
    end

    def self.disable_view_fix
      @view_fix_enabled = false
      detach_observers unless @rubber_band_enabled
    end

    def self.enable_rubber_band
      @rubber_band_enabled = true
      attach_observers
      if Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
    end

    def self.disable_rubber_band
      @rubber_band_enabled = false
      detach_observers unless @view_fix_enabled
      while Sketchup.active_model.tools.active_tool_id != NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.pop_tool
      end
    end

    def self.enable_all
      @view_fix_enabled    = true
      @rubber_band_enabled = true
      attach_observers
      if Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
    end

    def self.reattach_for_new_model
      detach_observers
      @observers_attached = false
      attach_observers if @view_fix_enabled || @rubber_band_enabled
      if @rubber_band_enabled &&
         Sketchup.active_model.tools.active_tool_id == NATIVE_SELECT_TOOL_ID
        Sketchup.active_model.tools.push_tool(RubberBandTool.new)
      end
    end

  end
end

# -------------------------------------------------------------------------
# Menu items
# -------------------------------------------------------------------------
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

# -------------------------------------------------------------------------
# AppObserver - re-attaches all observers when a new/opened model is loaded
# -------------------------------------------------------------------------
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

# -------------------------------------------------------------------------
# Auto-enable both fixes on startup
# -------------------------------------------------------------------------
NH::WineSketchupFix.enable_all
