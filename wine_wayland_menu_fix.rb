# wine_wayland_menu_fix.rb
#
# Wine Wayland Menu Fix for SketchUp 2017 under Wine
# Version: 1.0.0
#
# PROBLEM
#   Under Wine's native Wayland driver (winewayland.drv), Win32 popup menus
#   (menu-bar dropdowns, right-click context menus and their submenus) are
#   created as Wayland subsurfaces of the main window, as is SketchUp's
#   OpenGL canvas. Each is stacked with place_above(main window), which puts
#   the most recently stacked subsurface lowest. A newly opened menu is
#   stacked after the canvas, so it lands underneath it. It only becomes
#   visible when Wine next restacks the canvas, which happens when the main
#   window updates (for example a canvas redraw or a focus change).
#   Menus are unaffected under XWayland/X11.
#
# FIX
#   A lightweight timer tracks visible Win32 popup-menu windows
#   (window class "#32768") via Fiddle. When a new one appears (a menu, a
#   submenu, or a switch to another dropdown), the canvas is refreshed now
#   and for a few further ticks. The refresh makes Wine restack the canvas
#   below the menu.
#   When no menu opens, the only cost is one window lookup per tick.
#
# MODES (Plugins > Wine Wayland Menu Fix)
#   Auto      - active only when the Wine Wayland driver is detected (default)
#   Always on - active on any driver
#   Off       - inactive
#
# This add-on is independent of wine_sketchup_fix.rb and can be installed
# with or without it.

require 'sketchup.rb'

module NH
  module WineWaylandMenuFix

    VERSION          = '1.0.0'.freeze
    SETTINGS_SECTION = 'NH_WineWaylandMenuFix'.freeze
    MODES            = %w[auto on off].freeze

    POLL_INTERVAL    = 0.05    # seconds between menu checks
    BURST_REFRESHES  = 4       # refreshes per menu open (now + 3 more ticks)
    MENU_CLASS_ATOM  = 0x8000  # atom for "#32768", the Win32 popup-menu class
    MAX_WINDOWS      = 256     # safety cap on the window enumeration loop

    # ------------------------------------------------------------------
    # Win32 access via Fiddle. If this fails, the add-on stays inactive.
    # ------------------------------------------------------------------
    begin
      require 'fiddle'
      require 'fiddle/import'

      module User32
        extend Fiddle::Importer
        dlload 'user32'
        extern 'void* FindWindowExW(void*, void*, void*, void*)'
        extern 'int IsWindowVisible(void*)'
        extern 'int GetWindowRect(void*, void*)'
      end

      @rect_buf = Fiddle::Pointer.malloc(16) unless @rect_buf  # RECT: 4 x LONG
      @win32_ok = true
    rescue LoadError, StandardError => e
      @win32_ok    = false
      @win32_error = "#{e.class}: #{e.message}"
    end

    # ------------------------------------------------------------------
    # Logging
    # ------------------------------------------------------------------
    def self.log(msg)
      puts "[WineWaylandMenuFix] #{msg}"
    end

    def self.debug(msg)
      log(msg) if @debug
    end

    # ------------------------------------------------------------------
    # Driver detection
    #   Wayland if DISPLAY is unset or empty (Wine cannot use X11), or if
    #   "wayland" is the first entry in Wine's Graphics registry value
    #   (Wine tries the listed drivers in order).
    #   A false positive only costs refreshes while a menu opens under
    #   XWayland; a false negative leaves the menu bug in place. Hence this
    #   is deliberately less strict than wine_sketchup_fix.rb.
    # ------------------------------------------------------------------
    def self.detect_wayland
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

      graphics.to_s.split(',').first.to_s.strip.downcase == 'wayland'
    end

    # ------------------------------------------------------------------
    # Menu detection and refresh
    # ------------------------------------------------------------------

    # Visible Win32 popup-menu windows (menus and submenus), each identified
    # by [handle, left, top, right, bottom]. Including the position catches
    # a menu that replaces another within one tick, or a reused window
    # shown at a new position (e.g. moving between menu-bar dropdowns).
    def self.visible_menus
      menus  = []
      handle = 0
      MAX_WINDOWS.times do
        handle = User32.FindWindowExW(0, handle, MENU_CLASS_ATOM, 0).to_i
        break if handle == 0
        next if User32.IsWindowVisible(handle) == 0

        if User32.GetWindowRect(handle, @rect_buf) != 0
          menus << [handle] + @rect_buf[0, 16].unpack('l4')
        else
          menus << [handle]
        end
      end
      menus
    end

    def self.refresh_view
      model = Sketchup.active_model
      model.active_view.refresh if model
    end

    # Runs every POLL_INTERVAL seconds while the fix is active.
    def self.tick
      menus  = visible_menus
      opened = menus - @last_menus

      if !opened.empty?
        @burst = BURST_REFRESHES
        debug("menus #{@last_menus.size} -> #{menus.size}, " \
              "#{opened.size} new, refreshing")
      elsif menus.size != @last_menus.size
        debug("menus #{@last_menus.size} -> #{menus.size}")
      end
      @last_menus = menus

      if @burst > 0
        @burst -= 1
        refresh_view
      end
    rescue StandardError => e
      stop
      @failed = true
      log("disabled after error: #{e.class}: #{e.message}")
    end

    # ------------------------------------------------------------------
    # Start / stop
    # ------------------------------------------------------------------
    def self.start
      return if @timer || !@win32_ok || @failed
      @last_menus = []
      @burst      = 0
      @timer = UI.start_timer(POLL_INTERVAL, true) { tick }
      debug('timer started')
    end

    def self.stop
      return unless @timer
      UI.stop_timer(@timer)
      @timer = nil
      debug('timer stopped')
    end

    def self.should_run?
      case @mode
      when 'on'  then true
      when 'off' then false
      else @wayland
      end
    end

    def self.apply
      should_run? ? start : stop
    end

    def self.set_mode(mode)
      @mode = mode
      Sketchup.write_default(SETTINGS_SECTION, 'mode', mode)
      apply
      log("mode=#{@mode}, #{@timer ? 'active' : 'inactive'}")
    end

    # ------------------------------------------------------------------
    # Startup (safe to re-run via load)
    # ------------------------------------------------------------------
    stop

    @mode = Sketchup.read_default(SETTINGS_SECTION, 'mode', 'auto').to_s
    @mode = 'auto' unless MODES.include?(@mode)
    @wayland = detect_wayland
    @failed  = false
    @debug   = false if @debug.nil?

    if @win32_ok
      apply
      log("v#{VERSION}: driver=#{@wayland ? 'wayland' : 'x11'}, " \
          "mode=#{@mode}, #{@timer ? 'active' : 'inactive'}")
    else
      log("v#{VERSION}: inactive, Win32 access unavailable (#{@win32_error})")
    end

    # ------------------------------------------------------------------
    # Plugins menu
    # ------------------------------------------------------------------
    unless file_loaded?(__FILE__)
      submenu = UI.menu('Plugins').add_submenu('Wine Wayland Menu Fix')

      {
        'auto' => 'Auto (Wayland driver only)',
        'on'   => 'Always on',
        'off'  => 'Off'
      }.each do |mode, label|
        item = submenu.add_item(label) { set_mode(mode) }
        submenu.set_validation_proc(item) { @mode == mode ? MF_CHECKED : MF_UNCHECKED }
      end

      submenu.add_separator
      item = submenu.add_item('Debug logging') do
        @debug = !@debug
        log("debug logging #{@debug ? 'on' : 'off'}")
      end
      submenu.set_validation_proc(item) { @debug ? MF_CHECKED : MF_UNCHECKED }

      file_loaded(__FILE__)
    end

  end
end
