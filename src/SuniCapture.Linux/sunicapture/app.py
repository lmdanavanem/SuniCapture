from __future__ import annotations

from datetime import datetime
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import sys
import time

from . import VERSION
from .runtime import Gtk, Gdk, GdkPixbuf, GLib, Gio, L, brand_path, drain
from .core import Store, load_image, export_image, surface_from_pixbuf, surface_pixbuf, now
from .editor import AnnotationCanvas, TOOLS
from .capture import is_wayland, desktop_pixbuf, primary_rectangle, windows, window_pixbuf, RegionSelector
from .portals import PortalClient, SERVICE
from .recorder import Recorder


def css(dark):
    colors = dict(chrome="#191E2E" if dark else "#F8FAFC", surface="#22283A" if dark else "#FFFFFF",
                  border="#343C52" if dark else "#E2E8F0", text="#F1F5F9" if dark else "#0F172A",
                  muted="#A5B4CA" if dark else "#64748B", soft="#2C3C59" if dark else "#E9EFFD",
                  hover="#2A3648" if dark else "#EEF2F7", canvas="#0B101A" if dark else "#E5E7EB")
    definitions = "\n".join("@define-color " + key + " " + value + ";" for key, value in colors.items())
    return definitions + """
    window, dialog { background: @chrome; color: @text; font-family: Sans; font-size: 13px; }
    label { color: @text; }
    .muted { color: @muted; }
    .surface, .sidebar { background: @surface; }
    .sidebar { border-right: 1px solid @border; }
    .canvas { background: @canvas; }
    .header { background: @surface; border-bottom: 1px solid @border; }
    .toolbar { border-bottom: 1px solid @border; padding: 10px 18px; }
    .status { border-top: 1px solid @border; padding: 6px 17px; }
    button { background-image: none; background-color: @surface; color: @text; border: 1px solid @border; border-radius: 7px; padding: 8px 12px; box-shadow: none; text-shadow: none; }
    button:hover { border-color: #2563EB; background-color: @hover; }
    button:focus { border-color: #2563EB; outline-color: #2563EB; }
    button:disabled { opacity: .4; }
    button label { color: inherit; }
    button.primary { background: #2563EB; color: white; border-color: #2563EB; font-weight: bold; }
    button.primary:hover { background: #1D4ED8; }
    button.danger { background: #DC2626; color: white; border-color: #DC2626; }
    button.quiet { background: transparent; border-color: transparent; }
    button.nav { border-color: transparent; background: transparent; padding: 6px 12px; }
    button.selected, button.nav.selected { background: @soft; border-color: @soft; }
    entry, textview, textview text { background: @surface; color: @text; border-color: @border; border-radius: 6px; padding: 7px; caret-color: #2563EB; }
    list, row { background: @surface; color: @text; }
    row { border-radius: 8px; margin: 2px 0; padding: 8px; }
    row:selected { background: @soft; color: @text; }
    .card { background: @surface; border: 1px solid @border; border-radius: 12px; padding: 20px; }
    .privacy, .badge { background: @soft; border: 1px solid @border; border-radius: 10px; padding: 16px; }
    .badge { border-radius: 20px; padding: 8px 14px; }
    .section { border-top: 1px solid @border; padding-top: 16px; margin-top: 18px; }
    .tool { padding: 8px; min-width: 20px; }
    separator { background: @border; }
    """


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, application=None, data_dir=None, qa=False):
        super().__init__(application=application)
        self.qa = qa
        self.store = Store(data_dir)
        L.set_language(self.store.settings["Language"])
        self.bindings = []
        self.current = None
        self.filter = "all"
        self.busy = False
        self.modal_depth = 0
        self.save_timer = None
        self.library_loading = False
        self.playbin = None
        self.playing = False
        self.last_error = None
        self.recorder = Recorder()
        self.portal = None
        self.portal_stream = None
        self.portal_subscription = None
        self.record_bar = None
        self.record_clock = None
        self.record_error = None
        self.exit_after_recording = False
        self.counter = None
        self.shortcuts = None
        self.tray = None
        self.fit = True
        self.set_title("SuniCapture")
        self.set_icon_from_file(str(brand_path("sunicapture-icon.png")))
        self.set_default_size(min(1800, max(1100, int(self.store.settings.get("WindowWidth", 1440)))), min(1100, max(700, int(self.store.settings.get("WindowHeight", 940)))))
        self.set_size_request(1100, 700)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self.on_close)
        self.connect("key-press-event", self.on_key)
        self.connect("drag-data-received", self.on_drop)
        self.drag_dest_set(Gtk.DestDefaults.ALL, [Gtk.TargetEntry.new("text/uri-list", 0, 0)], Gdk.DragAction.COPY)
        self.provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), self.provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.apply_theme()
        self.build()
        self.refresh_library()
        self.update_editor()
        self.update_recording()
        self.record_timer = GLib.timeout_add(500, self.tick_recording)
        if not qa:
            self.connect("realize", self.start_desktop_integration)

    def style(self, widget, name):
        widget.get_style_context().add_class(name)
        return widget

    def bind(self, widget, key, method="set_label"):
        getattr(widget, method)(L.t(key))
        self.bindings.append((widget, key, method))
        return widget

    def label(self, key=None, text=None, size=13, bold=False, muted=False):
        widget = Gtk.Label(xalign=0)
        widget.set_line_wrap(True)
        if key:
            self.bind(widget, key, "set_text")
        elif text is not None:
            widget.set_text(str(text))
        from .runtime import Pango
        font = Pango.FontDescription("Sans Bold" if bold else "Sans")
        font.set_absolute_size(size * Pango.SCALE)
        widget.override_font(font)
        if muted:
            self.style(widget, "muted")
        return widget

    def button(self, key, action, kind=None, tooltip=None):
        button = Gtk.Button()
        self.bind(button, key)
        button.connect("clicked", lambda *_: self.guard(action))
        if kind:
            self.style(button, kind)
        if tooltip:
            self.bind(button, tooltip, "set_tooltip_text")
        return button

    def guard(self, action):
        try:
            return action()
        except Exception as error:
            self.error(error)
            return False

    def set_status(self, message):
        self.status.set_text(str(message))

    def error(self, error):
        self.last_error = str(error)
        self.set_status(str(error))
        if not self.qa:
            dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE, text=L.t("linux.error"))
            dialog.format_secondary_text(str(error))
            dialog.get_widget_for_response(Gtk.ResponseType.CLOSE).set_label(L.t("action.close"))
            self.run_dialog(dialog)

    def build(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        header = self.style(Gtk.Box(spacing=8), "header")
        header.set_border_width(12)
        header.pack_start(Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(brand_path("sunicapture-icon.png")), 43, 43, True)), False, False, 0)
        title = Gtk.Label()
        title.set_markup('<span size="17000" weight="bold">Suni<span foreground="#EF3438">Capture</span></span>')
        header.pack_start(title, False, False, 0)
        version = self.style(Gtk.Label(label=VERSION), "badge")
        header.pack_start(version, False, False, 6)
        header.pack_start(Gtk.Box(), True, True, 0)
        header.pack_start(self.label("header.local", muted=True), False, False, 12)
        header.pack_start(self.button("action.import", self.import_dialog, tooltip="action.importHint"), False, False, 0)
        header.pack_start(self.button("action.paste", self.paste, tooltip="action.pasteHint"), False, False, 0)
        self.language_button = Gtk.Button(label=L.language.upper())
        self.language_button.set_tooltip_text(L.t("language.choose"))
        self.language_button.connect("clicked", self.language_menu)
        header.pack_start(self.language_button, False, False, 5)
        about = Gtk.Button(label="?")
        about.connect("clicked", lambda *_: self.guard(self.about_dialog))
        self.bind(about, "about.title", "set_tooltip_text")
        header.pack_start(about, False, False, 0)
        theme = Gtk.Button(label="◐")
        theme.connect("clicked", lambda *_: self.guard(self.toggle_theme))
        self.bind(theme, "theme.change", "set_tooltip_text")
        header.pack_start(theme, False, False, 0)
        settings = Gtk.Button.new_from_icon_name("preferences-system-symbolic", Gtk.IconSize.BUTTON)
        settings.connect("clicked", lambda *_: self.guard(self.settings_dialog))
        self.bind(settings, "settings.hint", "set_tooltip_text")
        header.pack_start(settings, False, False, 0)
        root.pack_start(header, False, False, 0)
        actions = self.style(Gtk.Box(spacing=9), "toolbar")
        self.capture_controls = []
        for key, mode in (("capture.region", "region"), ("capture.screen", "screen"), ("capture.window", "window")):
            button = self.button(key, lambda mode=mode: self.capture(mode), "primary" if mode == "region" else None)
            self.capture_controls.append(button)
            actions.pack_start(button, False, False, 0)
        self.record_button = self.button("record.title", self.open_recording)
        actions.pack_start(self.record_button, False, False, 0)
        actions.pack_start(Gtk.Box(), True, True, 0)
        actions.pack_start(self.label("capture.delay", muted=True), False, False, 0)
        self.delay = Gtk.ComboBoxText()
        for seconds, key in ((0, "delay.none"), (3, "delay.3"), (5, "delay.5"), (10, "delay.10")):
            self.delay.append(str(seconds), L.t(key))
        self.delay.set_active_id(str(self.store.settings["CaptureDelay"]))
        self.delay.connect("changed", self.delay_changed)
        actions.pack_start(self.delay, False, False, 0)
        root.pack_start(actions, False, False, 0)
        body = Gtk.Box()
        root.pack_start(body, True, True, 0)
        self.build_sidebar(body)
        self.stack = Gtk.Stack()
        self.stack.set_hhomogeneous(False)
        self.stack.set_vhomogeneous(False)
        self.stack.set_hexpand(True)
        self.stack.set_vexpand(True)
        body.pack_start(self.stack, True, True, 0)
        self.build_home()
        self.build_editor()
        self.build_recording()
        self.build_video()
        bottom = self.style(Gtk.Box(), "status")
        self.status = self.label(text=L.t("status.ready"), size=10, muted=True)
        self.status.set_ellipsize(3)
        bottom.pack_start(self.status, True, True, 0)
        bottom.pack_end(self.label("shortcut.regionHint", size=10, muted=True), False, False, 0)
        root.pack_start(bottom, False, False, 0)

    def build_sidebar(self, body):
        sidebar = self.style(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6), "sidebar")
        sidebar.set_size_request(265, -1)
        sidebar.set_border_width(16)
        row = Gtk.Box()
        row.pack_start(self.label("library.title", size=15, bold=True), True, True, 0)
        self.count = self.label(text="0", muted=True)
        row.pack_end(self.count, False, False, 0)
        sidebar.pack_start(row, False, False, 5)
        self.search = Gtk.SearchEntry()
        self.bind(self.search, "library.search", "set_placeholder_text")
        self.search.connect("search-changed", lambda *_: self.refresh_library())
        sidebar.pack_start(self.search, False, False, 5)
        sidebar.pack_start(self.button("record.title", self.open_recording, "nav"), False, False, 0)
        self.filter_buttons = {}
        for key, name in (("library.all", "all"), ("library.favorites", "favorite"), ("library.recordings", "video"), ("library.trash", "trash")):
            button = self.button(key, lambda name=name: self.set_filter(name), "nav")
            button.set_halign(Gtk.Align.FILL)
            self.filter_buttons[name] = button
            sidebar.pack_start(button, False, False, 0)
        self.library_heading = self.label("library.recent", size=11, muted=True)
        sidebar.pack_start(self.library_heading, False, False, 12)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.library = Gtk.ListBox()
        self.library.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.library.connect("row-selected", self.row_selected)
        scroll.add(self.library)
        sidebar.pack_start(scroll, True, True, 0)
        self.empty_library = self.label("library.empty", size=11, muted=True)
        sidebar.pack_start(self.empty_library, False, False, 6)
        sidebar.pack_start(Gtk.Separator(), False, False, 4)
        sidebar.pack_start(self.label("library.onComputer", bold=True, size=12), False, False, 0)
        sidebar.pack_start(self.label("library.originals", muted=True, size=11), False, False, 0)
        sidebar.pack_start(self.button("action.openFolder", lambda: self.open_path(self.store.root)), False, False, 0)
        body.pack_start(sidebar, False, False, 0)

    def build_home(self):
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_border_width(36)
        title = Gtk.Box(spacing=22)
        title.pack_start(Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(brand_path("sunicapture-logo.png")), 125, 125, True)), False, False, 0)
        words = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        words.set_valign(Gtk.Align.CENTER)
        words.pack_start(self.label("home.welcome", size=25, bold=True), False, False, 0)
        words.pack_start(self.label("home.subtitle", size=14, muted=True), False, False, 0)
        title.pack_start(words, True, True, 0)
        content.pack_start(title, False, False, 0)
        region = self.button("capture.region", lambda: self.capture("region"), "primary")
        region.set_size_request(-1, 92)
        self.capture_controls.append(region)
        content.pack_start(region, False, False, 0)
        content.pack_start(self.label("home.quick", size=17, bold=True), False, False, 5)
        grid = Gtk.Grid(column_spacing=12, row_spacing=12)
        grid.set_column_homogeneous(True)
        for index, (title_key, hint, action) in enumerate((("home.screen", "home.screenHint", lambda: self.capture("screen")),
                ("home.window", "home.windowHint", lambda: self.capture("window")),
                ("record.title", "home.recordHint", self.open_recording), ("home.image", "home.imageHint", self.import_dialog))):
            button = Gtk.Button()
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            card.set_border_width(18)
            card.pack_start(self.label(title_key, size=15, bold=True), False, False, 0)
            card.pack_start(self.label(hint, size=12, muted=True), False, False, 0)
            button.add(card)
            button.connect("clicked", lambda _, action=action: self.guard(action))
            button.set_hexpand(True)
            grid.attach(button, index % 2, index // 2, 1, 1)
        content.pack_start(grid, False, False, 0)
        content.pack_start(self.label("home.footer", size=12, muted=True), False, False, 12)
        scroll.add(content)
        self.stack.add_named(scroll, "home")

    def build_editor(self):
        editor = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        title = self.style(Gtk.Box(spacing=8), "toolbar")
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.image_name = self.label(text="", size=14, bold=True)
        self.image_info = self.label(text="", size=10, muted=True)
        titles.pack_start(self.image_name, False, False, 0)
        titles.pack_start(self.image_info, False, False, 0)
        title.pack_start(titles, True, True, 0)
        self.favorite_button = Gtk.Button(label="☆")
        self.favorite_button.connect("clicked", lambda *_: self.guard(self.favorite))
        title.pack_start(self.favorite_button, False, False, 0)
        title.pack_start(self.button("action.rename", self.rename, "quiet"), False, False, 0)
        self.trash_button = self.button("library.trash", self.trash, "quiet")
        title.pack_start(self.trash_button, False, False, 0)
        title.pack_start(self.button("action.home", self.show_home, "quiet"), False, False, 0)
        editor.pack_start(title, False, False, 0)
        tools = self.style(Gtk.Box(spacing=4), "toolbar")
        self.tool_buttons = {}
        glyphs = ("↖", "➜", "□", "○", "✎", "▰", "T", "①", "▣", "⌗")
        for tool, glyph in zip(TOOLS, glyphs):
            button = self.style(Gtk.Button(label=glyph), "tool")
            button.connect("clicked", lambda _, tool=tool: self.set_tool(tool))
            self.bind(button, "tool." + tool, "set_tooltip_text")
            self.tool_buttons[tool] = button
            tools.pack_start(button, False, False, 0)
        tools.pack_start(Gtk.Box(), True, True, 0)
        self.undo_button = Gtk.Button(label="↶")
        self.undo_button.connect("clicked", lambda *_: self.undo())
        self.bind(self.undo_button, "edit.undo", "set_tooltip_text")
        self.redo_button = Gtk.Button(label="↷")
        self.redo_button.connect("clicked", lambda *_: self.redo())
        self.bind(self.redo_button, "edit.redo", "set_tooltip_text")
        tools.pack_start(self.undo_button, False, False, 0)
        tools.pack_start(self.redo_button, False, False, 0)
        editor.pack_start(tools, False, False, 0)
        center = Gtk.Box()
        self.canvas_scroll = self.style(Gtk.ScrolledWindow(), "canvas")
        self.canvas_scroll.set_hexpand(True)
        self.canvas_scroll.set_vexpand(True)
        self.canvas = AnnotationCanvas(self.canvas_changed)
        self.canvas_scroll.add_with_viewport(self.canvas)
        self.canvas_scroll.connect("size-allocate", lambda *_: self.fit_canvas() if self.fit else None)
        center.pack_start(self.canvas_scroll, True, True, 0)
        property_shell = self.style(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "surface")
        property_shell.set_size_request(225, -1)
        properties = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        properties.set_size_request(220, -1)
        properties.set_border_width(16)
        properties.pack_start(self.label("edit.properties", size=14, bold=True), False, False, 0)
        self.tool_name = self.label(text=L.t("tool.arrow"), muted=True)
        properties.pack_start(self.tool_name, False, False, 0)
        properties.pack_start(self.label("edit.color", bold=True, size=12), False, False, 0)
        palette = Gtk.Grid(column_spacing=5, row_spacing=5)
        for index, color in enumerate(("#2563EB", "#DC2626", "#16A34A", "#F59E0B", "#8B5CF6", "#0F172A", "#FFFFFF", "#E11D48")):
            button = Gtk.Button()
            square = Gtk.Label()
            square.set_markup('<span background="' + color + '">     </span>')
            button.add(square)
            button.set_tooltip_text(color)
            button.connect("clicked", lambda _, color=color: self.set_color(color))
            palette.attach(button, index % 4, index // 4, 1, 1)
        properties.pack_start(palette, False, False, 0)
        self.hex_color = Gtk.Entry(text="#2563EB")
        self.bind(self.hex_color, "edit.hex", "set_tooltip_text")
        self.hex_color.connect("activate", lambda *_: self.guard(lambda: self.set_color(self.hex_color.get_text())))
        properties.pack_start(self.hex_color, False, False, 0)
        properties.pack_start(self.label("edit.thickness", bold=True, size=12), False, False, 0)
        thickness = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 1, 20, 1)
        thickness.set_value(4)
        thickness.connect("value-changed", lambda scale: setattr(self.canvas, "width", scale.get_value()))
        properties.pack_start(thickness, False, False, 0)
        self.text_options = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.text_options.set_no_show_all(True)
        self.text_options.pack_start(self.label("edit.textPlace", bold=True, size=12), False, False, 0)
        self.annotation_text = Gtk.Entry(text=L.t("edit.defaultText"))
        self.annotation_text.connect("changed", lambda entry: setattr(self.canvas, "text", entry.get_text()))
        self.text_options.pack_start(self.annotation_text, False, False, 0)
        text_size = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 12, 80, 1)
        text_size.set_value(28)
        text_size.connect("value-changed", lambda scale: setattr(self.canvas, "font_size", scale.get_value()))
        self.text_options.pack_start(text_size, False, False, 0)
        for child in self.text_options.get_children():
            child.show_all()
        properties.pack_start(self.text_options, False, False, 0)
        self.tool_hint = self.label(text=L.t("tool.drawHint"), size=11, muted=True)
        self.tool_hint.set_max_width_chars(24)
        properties.pack_start(self.tool_hint, False, False, 8)
        property_scroll = Gtk.ScrolledWindow()
        property_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        property_scroll.add(properties)
        property_shell.pack_start(property_scroll, True, True, 0)
        exports = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        exports.set_border_width(16)
        row = Gtk.Box(spacing=6)
        self.save_button = self.button("action.save", lambda: self.save_current(True), tooltip="edit.saveHint")
        row.pack_start(self.save_button, True, True, 0)
        row.pack_start(self.button("action.copy", self.copy_image, tooltip="edit.copyHint"), True, True, 0)
        exports.pack_start(row, False, False, 0)
        exports.pack_start(self.button("action.export", self.export_current, "primary"), False, False, 0)
        exports.pack_start(self.button("edit.original", self.restore_original, "quiet"), False, False, 0)
        property_shell.pack_start(exports, False, False, 0)
        center.pack_start(property_shell, False, False, 0)
        editor.pack_start(center, True, True, 0)
        footer = self.style(Gtk.Box(spacing=7), "status")
        self.dimensions = self.label(text="", size=11, muted=True)
        footer.pack_start(self.dimensions, True, True, 0)
        minus = Gtk.Button(label="−")
        minus.connect("clicked", lambda *_: self.zoom(self.canvas.zoom / 1.25))
        footer.pack_start(minus, False, False, 0)
        self.zoom_label = self.label(text="100 %", size=11)
        footer.pack_start(self.zoom_label, False, False, 0)
        plus = Gtk.Button(label="+")
        plus.connect("clicked", lambda *_: self.zoom(self.canvas.zoom * 1.25))
        footer.pack_start(plus, False, False, 0)
        footer.pack_start(self.button("edit.fit", self.enable_fit), False, False, 0)
        editor.pack_start(footer, False, False, 0)
        self.stack.add_named(editor, "editor")

    def build_recording(self):
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_border_width(36)
        content.pack_start(self.label("record.title", size=26, bold=True), False, False, 0)
        content.pack_start(self.label("record.subtitle", size=14, muted=True), False, False, 0)
        card = self.style(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18), "card")
        self.record_state = self.label("record.ready", size=21, bold=True)
        self.elapsed = self.label(text="00:00:00", size=29)
        card.pack_start(self.record_state, False, False, 0)
        card.pack_start(self.elapsed, False, False, 0)
        card.pack_start(self.label("linux.waylandSource" if is_wayland() else "linux.x11Source", bold=True), False, False, 0)
        card.pack_start(self.label("linux.waylandHint" if is_wayland() else "linux.recordHelp", muted=True), False, False, 0)
        self.audio = Gtk.CheckButton()
        self.bind(self.audio, "record.audio")
        self.audio.set_active(bool(self.store.settings["SystemAudio"]))
        self.audio.connect("toggled", self.audio_changed)
        card.pack_start(self.audio, False, False, 0)
        self.record_help = self.label("record.defaultHelp", size=12, muted=True)
        card.pack_start(self.record_help, False, False, 0)
        controls = Gtk.Box(spacing=10)
        self.start_button = self.button("record.start", self.start_recording, "danger")
        self.stop_button = self.button("record.stopSave", self.stop_recording)
        controls.pack_start(self.start_button, False, False, 0)
        controls.pack_start(self.stop_button, False, False, 0)
        card.pack_start(controls, False, False, 0)
        card.pack_start(self.label("linux.shortcutHelp", size=11, muted=True), False, False, 0)
        content.pack_start(card, False, False, 0)
        content.pack_start(self.button("record.show", lambda: self.set_filter("video")), False, False, 0)
        scroll.add(content)
        self.stack.add_named(scroll, "recorder")

    def build_video(self):
        self.video_view = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.video_view.set_border_width(32)
        self.video_name = self.label(text="", size=23, bold=True)
        self.video_info = self.label(text="", muted=True)
        self.video_view.pack_start(self.video_name, False, False, 0)
        self.video_view.pack_start(self.video_info, False, False, 0)
        self.video_holder = Gtk.Box()
        self.video_holder.set_hexpand(True)
        self.video_holder.set_vexpand(True)
        self.video_view.pack_start(self.video_holder, True, True, 0)
        controls = Gtk.Box(spacing=8)
        for key, action in (("video.play", self.play_video), ("video.open", lambda: self.open_path(self.store.current_file(self.current))),
                            ("video.export", self.export_current), ("action.rename", self.rename), ("video.favorite", self.favorite),
                            ("video.trash", self.trash), ("action.home", self.show_home)):
            controls.pack_start(self.button(key, action), False, False, 0)
        self.video_view.pack_start(controls, False, False, 0)
        self.stack.add_named(self.video_view, "video")

    def apply_theme(self):
        self.provider.load_from_data(css(bool(self.store.settings["DarkMode"])).encode())

    def toggle_theme(self):
        previous = self.store.settings["DarkMode"]
        self.store.settings["DarkMode"] = not previous
        try:
            self.store.save_settings()
        except Exception:
            self.store.settings["DarkMode"] = previous
            raise
        self.apply_theme()

    def language_menu(self, button):
        menu = Gtk.Menu()
        for code, name in (("en", "English"), ("fr", "Français")):
            item = Gtk.CheckMenuItem(label=name)
            item.set_active(code == L.language)
            item.connect("activate", lambda _, code=code: self.guard(lambda: self.change_language(code)))
            menu.append(item)
        menu.show_all()
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, None)

    def change_language(self, language):
        old = self.store.settings["Language"]
        self.store.settings["Language"] = language
        try:
            self.store.save_settings()
        except Exception:
            self.store.settings["Language"] = old
            raise
        self.refresh_language()

    def refresh_language(self):
        L.set_language(self.store.settings["Language"])
        for widget, key, method in self.bindings:
            getattr(widget, method)(L.t(key))
        self.language_button.set_label(L.language.upper())
        self.language_button.set_tooltip_text(L.t("language.choose"))
        selected = self.delay.get_active_id()
        self.delay.remove_all()
        for seconds, key in ((0, "delay.none"), (3, "delay.3"), (5, "delay.5"), (10, "delay.10")):
            self.delay.append(str(seconds), L.t(key))
        self.delay.set_active_id(selected or "0")
        self.refresh_library()
        self.update_item_labels()
        self.set_tool(self.canvas.tool)
        self.update_editor()
        self.update_recording()
        self.set_status(L.t("language.changed"))

    def delay_changed(self, combo):
        selected = combo.get_active_id()
        if selected is not None:
            self.store.settings["CaptureDelay"] = int(selected)
            self.guard(self.store.save_settings)

    def set_filter(self, name):
        if not self.save_current():
            return
        self.filter = name
        if name == "video":
            self.show_home()
        self.refresh_library()

    def refresh_library(self):
        self.library_loading = True
        try:
            for child in self.library.get_children():
                self.library.remove(child)
            query = self.search.get_text().strip().casefold()
            shown = []
            for item in self.store.items:
                trashed = bool(item.get("IsTrashed"))
                if (self.filter == "trash") != trashed:
                    continue
                if self.filter == "favorite" and not item.get("Favorite"):
                    continue
                if self.filter == "video" and item.get("Kind") != "video":
                    continue
                if query and query not in item.get("Name", "").casefold():
                    continue
                row = Gtk.ListBoxRow()
                row.item = item
                box = Gtk.Box(spacing=8)
                image = Gtk.Image.new_from_icon_name("video-x-generic" if item.get("Kind") == "video" else "image-x-generic", Gtk.IconSize.DIALOG)
                if item.get("Kind") != "video":
                    try:
                        image.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(self.store.current_file(item)), 54, 44, True))
                    except GLib.Error:
                        pass
                image.set_size_request(54, 44)
                box.pack_start(image, False, False, 0)
                text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
                name = Gtk.Label(label=item.get("Name", "Capture"), xalign=0)
                name.set_ellipsize(3)
                name.set_max_width_chars(20)
                subtitle = Gtk.Label(label=self.subtitle(item), xalign=0)
                subtitle.set_ellipsize(3)
                self.style(subtitle, "muted")
                text.pack_start(name, False, False, 0)
                text.pack_start(subtitle, False, False, 0)
                box.pack_start(text, True, True, 0)
                if item.get("Favorite"):
                    box.pack_end(Gtk.Label(label="★"), False, False, 0)
                row.add(box)
                self.library.add(row)
                if self.current and item["Id"] == self.current["Id"]:
                    self.library.select_row(row)
                shown.append(item)
            self.library.show_all()
            self.count.set_text(str(sum(not item.get("IsTrashed") for item in self.store.items)))
            self.empty_library.set_text(L.t("library.noMatch" if query else "library.emptyTrash" if self.filter == "trash" else "library.emptyVideo" if self.filter == "video" else "library.empty"))
            self.empty_library.set_visible(not shown)
            self.library_heading.set_text(L.t({"favorite": "library.yourFavorites", "video": "library.yourRecordings", "trash": "library.toRestore"}.get(self.filter, "library.recent")))
            for name, button in self.filter_buttons.items():
                style = button.get_style_context()
                style.add_class("selected") if name == self.filter else style.remove_class("selected")
        finally:
            self.library_loading = False

    def subtitle(self, item):
        if item.get("Kind") == "video":
            return "MP4 · " + str(round(item.get("DurationSeconds", 0))) + " s"
        return str(item.get("Width", 0)) + " × " + str(item.get("Height", 0)) + " px"

    def row_selected(self, widget, row):
        if not self.library_loading and row and row.item is not self.current:
            self.guard(lambda: self.open_item(row.item))

    def open_item(self, item):
        if not self.save_current():
            return False
        path = self.store.current_file(item)
        if not path.exists():
            raise FileNotFoundError(L.t("video.missing") if item.get("Kind") == "video" else L.t("image.missing"))
        self.stop_video()
        if item.get("Kind") == "video":
            self.current = item
            self.stack.set_visible_child_name("video")
            self.load_video(path)
        else:
            image = load_image(path)
            self.current = item
            self.canvas.load(image)
            self.fit = True
            self.stack.set_visible_child_name("editor")
            GLib.idle_add(lambda: self.fit_canvas() or False)
        self.update_item_labels()
        self.update_editor()
        self.set_status(L.t("status.imageOpen") if item.get("Kind") != "video" else L.t("video.ready"))
        return True

    def update_item_labels(self):
        if not self.current:
            return
        item = self.current
        self.image_name.set_text(item.get("Name", "Capture"))
        self.image_info.set_text(item.get("Source", "") + " · " + item.get("CreatedAt", "")[:16].replace("T", " "))
        self.favorite_button.set_label("★" if item.get("Favorite") else "☆")
        self.favorite_button.set_tooltip_text(L.t("favorite.remove" if item.get("Favorite") else "favorite.add"))
        self.trash_button.set_label(L.t("action.restore" if item.get("IsTrashed") else "library.trash"))
        self.video_name.set_text(item.get("Name", ""))
        self.video_info.set_text(L.t("linux.videoInfo", round(item.get("DurationSeconds", 0), 1), item.get("Width", 0), item.get("Height", 0)))

    def show_home(self):
        if not self.save_current():
            return False
        self.current = None
        self.stop_video()
        self.canvas.load(None)
        self.stack.set_visible_child_name("home")
        self.refresh_library()
        return True

    def set_tool(self, tool):
        self.canvas.tool = tool
        self.canvas.draft = None
        self.tool_name.set_text(L.t("tool." + tool))
        hint = {"select": "tool.selectHint", "text": "tool.textHint", "step": "tool.stepHint", "redact": "tool.redactionHint", "crop": "tool.cropHint", "highlight": "tool.highlightHint"}.get(tool, "tool.drawHint")
        self.tool_hint.set_text(L.t(hint))
        self.text_options.set_visible(tool == "text")
        for name, button in self.tool_buttons.items():
            style = button.get_style_context()
            style.add_class("selected") if name == tool else style.remove_class("selected")
        self.canvas.queue_draw()

    def set_color(self, color):
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ValueError(L.t("color.hint"))
        self.canvas.color = color
        self.hex_color.set_text(color)

    def canvas_changed(self):
        self.update_editor()
        if self.canvas.model.dirty:
            if self.save_timer:
                GLib.source_remove(self.save_timer)
            self.save_timer = GLib.timeout_add(800, self.autosave)
            self.set_status(L.t("status.savingAnnotations"))
        if self.fit:
            self.fit_canvas()

    def autosave(self):
        self.save_timer = None
        self.save_current()
        return False

    def save_current(self, announce=False):
        if self.save_timer:
            GLib.source_remove(self.save_timer)
            self.save_timer = None
        if not self.current or self.current.get("Kind") == "video" or not self.canvas.model.dirty:
            return True
        try:
            self.store.save_edited(self.current, self.canvas.model.render())
            self.canvas.model.mark_clean()
            self.update_editor()
            self.set_status(L.t("status.annotationsSaved" if announce else "status.localSaved"))
            return True
        except Exception as error:
            self.error(error)
            return False

    def update_editor(self):
        model = self.canvas.model
        self.undo_button.set_sensitive(bool(model.undo_stack))
        self.redo_button.set_sensitive(bool(model.redo_stack))
        self.save_button.set_sensitive(model.dirty)
        if model.base:
            self.dimensions.set_text(str(model.base.get_width()) + " × " + str(model.base.get_height()) + " px · " + L.t("status.saving" if model.dirty else "status.saved"))
        self.text_options.set_visible(self.canvas.tool == "text")

    def undo(self):
        self.canvas.model.undo()
        self.canvas.update_size()
        self.canvas.queue_draw()
        self.canvas_changed()

    def redo(self):
        self.canvas.model.redo()
        self.canvas.update_size()
        self.canvas.queue_draw()
        self.canvas_changed()

    def fit_canvas(self):
        if not self.canvas.model.base or self.stack.get_visible_child_name() != "editor":
            return
        width = max(10, self.canvas_scroll.get_allocated_width() - 76)
        height = max(10, self.canvas_scroll.get_allocated_height() - 76)
        base = self.canvas.model.base
        self.canvas.set_zoom(min(1, width / base.get_width(), height / base.get_height()))
        self.zoom_label.set_text(str(round(self.canvas.zoom * 100)) + " %")

    def enable_fit(self):
        self.fit = True
        self.fit_canvas()

    def zoom(self, scale):
        self.fit = False
        self.canvas.set_zoom(scale)
        self.zoom_label.set_text(str(round(self.canvas.zoom * 100)) + " %")

    def add_image(self, surface, source, name=None):
        if not self.save_current():
            return None
        item = self.store.add_image(surface, source, name)
        self.filter = "all"
        self.search.set_text("")
        self.open_item(item)
        self.refresh_library()
        if self.store.settings["CopyAfterCapture"] and not self.qa:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_image(surface_pixbuf(surface))
        return item

    def import_paths(self, paths):
        if self.busy or not self.save_current():
            return
        if len(paths) > 100:
            raise ValueError(L.t("linux.tooManyImports"))
        imported = 0
        for path in paths:
            try:
                self.add_image(load_image(path), L.t("source.imported"), Path(path).stem)
                imported += 1
            except Exception as error:
                self.error(error)
        self.set_status(L.t("linux.importCount", imported))

    def import_dialog(self):
        dialog = Gtk.FileChooserDialog(title=L.t("import.title"), transient_for=self, action=Gtk.FileChooserAction.OPEN)
        dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("action.import"), Gtk.ResponseType.OK)
        dialog.set_select_multiple(True)
        images = Gtk.FileFilter()
        images.set_name(L.t("linux.images"))
        images.add_pixbuf_formats()
        dialog.add_filter(images)
        response, paths = self.run_dialog(dialog, lambda: dialog.get_filenames())
        if response == Gtk.ResponseType.OK:
            self.import_paths(paths)

    def paste(self):
        image = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_image()
        if image is None:
            self.set_status(L.t("status.noClipboard"))
            return
        self.add_image(surface_from_pixbuf(image), L.t("source.clipboard"))

    def copy_image(self):
        if self.canvas.model.base and self.current and self.current.get("Kind") != "video":
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_image(surface_pixbuf(self.canvas.model.render()))
            self.set_status(L.t("status.copied"))

    def on_drop(self, widget, context, x, y, data, info, timestamp):
        paths = [Gio.File.new_for_uri(uri).get_path() for uri in data.get_uris()]
        paths = [path for path in paths if path]
        self.guard(lambda: self.import_paths(paths))
        context.finish(bool(paths), False, timestamp)

    def export_current(self):
        if not self.current:
            return
        video = self.current.get("Kind") == "video"
        dialog = Gtk.FileChooserDialog(title=L.t("video.exportTitle" if video else "export.title"), transient_for=self, action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("action.export"), Gtk.ResponseType.OK)
        dialog.set_do_overwrite_confirmation(True)
        name = re.sub(r"[/\\\x00-\x1f]", "_", self.current.get("Name", "Capture"))
        dialog.set_current_name(name + (".mp4" if video else ".png"))
        formats = (("MP4", "*.mp4"),) if video else (("PNG", "*.png"), ("JPEG", "*.jpg"), ("BMP", "*.bmp"), ("PDF", "*.pdf"))
        for label, pattern in formats:
            filter = Gtk.FileFilter()
            filter.set_name(label)
            filter.add_pattern(pattern)
            dialog.add_filter(filter)
        response, result = self.run_dialog(dialog, lambda: (dialog.get_filename(), dialog.get_filter().get_name()))
        if response != Gtk.ResponseType.OK:
            return
        filename, format = result
        path = Path(filename)
        if not path.suffix:
            path = path.with_suffix(".jpg" if format == "JPEG" else "." + format.lower())
        if path.resolve() == self.store.resolve(self.current["OriginalFile"]):
            raise ValueError(L.t("linux.originalProtected"))
        if video:
            shutil.copy2(self.store.current_file(self.current), path)
        else:
            export_image(self.canvas.model.render(), path)
            self.save_current()
        self.set_status((L.t("video.exported") if video else L.t("export.done")) + path.name)

    def favorite(self):
        if self.current:
            self.current["Favorite"] = not self.current.get("Favorite")
            self.store.save()
            self.update_item_labels()
            self.refresh_library()

    def trash(self):
        if self.current and self.save_current():
            self.current["IsTrashed"] = not self.current.get("IsTrashed")
            self.current["TrashedAt"] = now() if self.current["IsTrashed"] else None
            self.store.save()
            self.show_home()

    def rename(self):
        if not self.current:
            return
        dialog = Gtk.Dialog(title=L.t("rename.title"), transient_for=self, modal=True)
        dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("rename.save"), Gtk.ResponseType.OK)
        entry = Gtk.Entry(text=self.current.get("Name", ""))
        entry.set_max_length(140)
        entry.set_activates_default(True)
        entry.set_margin_top(20)
        entry.set_margin_bottom(20)
        entry.set_margin_start(20)
        entry.set_margin_end(20)
        dialog.get_content_area().add(entry)
        dialog.set_default_response(Gtk.ResponseType.OK)
        response, name = self.run_dialog(dialog, lambda: entry.get_text().strip())
        if response == Gtk.ResponseType.OK and name:
            self.current["Name"] = name
            self.store.save()
            self.update_item_labels()
            self.refresh_library()

    def restore_original(self):
        if not self.current or self.current.get("Kind") == "video":
            return
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION, text=L.t("linux.restoreQuestion"))
        dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("action.restore"), Gtk.ResponseType.OK)
        if self.run_dialog(dialog)[0] != Gtk.ResponseType.OK:
            return
        original = load_image(self.store.resolve(self.current["OriginalFile"]))
        self.current.update(EditedFile=None, Width=original.get_width(), Height=original.get_height())
        self.store.save()
        self.canvas.load(original)
        self.update_editor()
        self.fit_canvas()

    def run_dialog(self, dialog, value=None):
        self.modal_depth += 1
        dialog.connect("key-press-event", lambda widget, event: (widget.response(Gtk.ResponseType.CANCEL) or True) if event.keyval == Gdk.KEY_Escape else False)
        try:
            dialog.show_all()
            response = dialog.run()
            result = value() if value else None
            return response, result
        finally:
            dialog.destroy()
            self.modal_depth -= 1

    def open_path(self, path):
        Gio.AppInfo.launch_default_for_uri(Path(path).resolve().as_uri(), None)

    def shell_dialog(self, title, width=700, height=730):
        dialog = Gtk.Dialog(title=L.t(title), transient_for=self, modal=True)
        monitor = self.get_display().get_monitor_at_window(self.get_window()) if self.get_window() else self.get_display().get_monitor(0)
        area = monitor.get_workarea()
        dialog.set_default_size(min(width, area.width - 40), min(height, area.height - 60))
        dialog.add_button(L.t("action.close"), Gtk.ResponseType.CLOSE)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_hexpand(True)
        scroll.set_vexpand(True)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        body.set_border_width(26)
        scroll.add(body)
        dialog.get_content_area().pack_start(scroll, True, True, 0)
        return dialog, body

    @staticmethod
    def dialog_label(key, size=13, bold=False, *args):
        from .runtime import Pango
        label = Gtk.Label(label=L.t(key, *args), xalign=0)
        label.set_line_wrap(True)
        label.set_max_width_chars(72)
        font = Pango.FontDescription("Sans Bold" if bold else "Sans")
        font.set_absolute_size(size * Pango.SCALE)
        label.override_font(font)
        return label

    def create_about(self):
        dialog, body = self.shell_dialog("about.title", 740, 850)
        logo = Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(brand_path("sunicapture-logo.png")), 170, 152, True))
        body.pack_start(logo, False, False, 0)
        version = Gtk.Label(label=L.t("about.version", VERSION))
        self.style(version, "badge")
        version.set_halign(Gtk.Align.CENTER)
        body.pack_start(version, False, False, 0)
        tagline = self.dialog_label("about.tagline", 22, True)
        tagline.set_halign(Gtk.Align.CENTER)
        body.pack_start(tagline, False, False, 0)
        subtitle = self.dialog_label("about.subtitle", 14)
        subtitle.set_halign(Gtk.Align.CENTER)
        body.pack_start(subtitle, False, False, 0)
        badges = Gtk.Box(spacing=10)
        badges.set_halign(Gtk.Align.CENTER)
        for key in ("about.offline", "about.telemetry", "about.account"):
            badges.pack_start(self.style(self.dialog_label(key), "badge"), False, False, 0)
        body.pack_start(badges, False, False, 6)
        privacy = self.style(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9), "privacy")
        privacy.pack_start(self.dialog_label("about.privacyTitle", 17, True), False, False, 0)
        privacy.pack_start(self.dialog_label("about.privacy"), False, False, 0)
        privacy.pack_start(self.dialog_label("about.privacyNote", 12), False, False, 0)
        body.pack_start(privacy, False, False, 0)
        for heading, details in (("about.storage", "about.storageHint"), ("about.updates", "about.updateHint"), ("about.credits", "about.engine")):
            body.pack_start(self.style(self.dialog_label(heading, 17, True), "section"), False, False, 0)
            body.pack_start(self.dialog_label(details), False, False, 0)
            if heading == "about.storage":
                entry = Gtk.Entry(text=str(self.store.root))
                entry.set_editable(False)
                body.pack_start(entry, False, False, 0)
                folder = Gtk.Button(label=L.t("action.openFolder"))
                folder.connect("clicked", lambda *_: self.guard(lambda: self.open_path(self.store.root)))
                folder.set_halign(Gtk.Align.START)
                body.pack_start(folder, False, False, 0)
        body.pack_start(self.dialog_label("about.developer", 14, True), False, False, 0)
        dialog.add_button(L.t("help.open"), 101)
        dialog.add_button(L.t("settings.open"), 102)
        return dialog

    def about_dialog(self):
        response, _ = self.run_dialog(self.create_about())
        if response == 101:
            self.help_dialog()
        elif response == 102:
            self.settings_dialog()

    def create_help(self):
        dialog, body = self.shell_dialog("help.title", 720, 780)
        for title, content in (("help.captureTitle", "help.captureBody"), ("help.editTitle", "help.editBody"),
                               ("help.videoTitle", "linux.helpVideo"), ("help.storageTitle", "help.storageBody"),
                               ("help.globalShortcuts", "linux.shortcutHelp"), ("help.editorShortcuts", "help.editorShortcutList")):
            body.pack_start(self.style(self.dialog_label(title, 17, True), "section"), False, False, 0)
            body.pack_start(self.dialog_label(content), False, False, 0)
        return dialog

    def help_dialog(self):
        self.run_dialog(self.create_help())

    def create_settings(self):
        dialog, body = self.shell_dialog("settings.title", 700, 740)
        dialog.get_widget_for_response(Gtk.ResponseType.CLOSE).set_label(L.t("action.cancel"))
        dialog.add_button(L.t("settings.save"), Gtk.ResponseType.OK)
        body.pack_start(self.dialog_label("settings.heading", 22, True), False, False, 0)
        body.pack_start(self.dialog_label("settings.immediate"), False, False, 0)
        language = Gtk.ComboBoxText()
        language.append("en", "English")
        language.append("fr", "Français")
        language.set_active_id(L.language)
        theme = Gtk.ComboBoxText()
        theme.append("light", L.t("theme.lightName"))
        theme.append("dark", L.t("theme.darkName"))
        theme.set_active_id("dark" if self.store.settings["DarkMode"] else "light")
        for key, widget in (("language.label", language), ("theme.label", theme)):
            row = Gtk.Box(spacing=20)
            row.pack_start(self.dialog_label(key), True, True, 0)
            row.pack_end(widget, False, False, 0)
            body.pack_start(row, False, False, 0)
        copy = Gtk.CheckButton(label=L.t("settings.copy"))
        copy.set_active(bool(self.store.settings["CopyAfterCapture"]))
        tray = Gtk.CheckButton(label=L.t("linux.settingsTray"))
        tray.set_active(bool(self.store.settings["MinimizeToTray"]))
        audio = Gtk.CheckButton(label=L.t("settings.audio"))
        audio.set_active(bool(self.store.settings["SystemAudio"]))
        audio.set_sensitive(not self.recorder.active)
        body.pack_start(self.style(self.dialog_label("settings.capture", 17, True), "section"), False, False, 0)
        for checkbox in (copy, tray, audio):
            body.pack_start(checkbox, False, False, 0)
        if not self.tray or not self.tray.is_embedded():
            tray.set_sensitive(False)
            body.pack_start(self.dialog_label("linux.noTray", 12), False, False, 0)
        body.pack_start(self.style(self.dialog_label("help.globalShortcuts", 17, True), "section"), False, False, 0)
        body.pack_start(self.dialog_label("linux.shortcutHelp", 12), False, False, 0)
        body.pack_start(self.dialog_label("help.editorShortcutList", 12), False, False, 0)
        return dialog, dict(language=language, theme=theme, copy=copy, tray=tray, audio=audio)

    def settings_dialog(self):
        dialog, fields = self.create_settings()
        response, choices = self.run_dialog(dialog, lambda: dict(Language=fields["language"].get_active_id(),
            DarkMode=fields["theme"].get_active_id() == "dark", CopyAfterCapture=fields["copy"].get_active(),
            MinimizeToTray=fields["tray"].get_active(), SystemAudio=fields["audio"].get_active()))
        if response != Gtk.ResponseType.OK:
            return
        previous = self.store.settings.copy()
        self.store.settings.update(choices)
        try:
            self.store.save_settings()
        except Exception:
            self.store.settings = previous
            raise
        self.apply_theme()
        self.refresh_language()
        self.audio.set_active(bool(self.store.settings["SystemAudio"]))
        self.set_status(L.t("settings.saved"))

    def show_main(self):
        self.show()
        self.present()

    def countdown(self, seconds, callback):
        if seconds <= 0:
            GLib.timeout_add(180, lambda: (self.guard(callback), False)[1])
            return
        counter = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        counter.set_decorated(False)
        counter.set_keep_above(True)
        counter.set_skip_taskbar_hint(True)
        counter.set_default_size(130, 110)
        counter.set_position(Gtk.WindowPosition.CENTER)
        label = Gtk.Label()
        counter.add(label)
        self.counter = counter
        remaining = [seconds]

        def cancel(*_):
            if self.counter is counter:
                self.counter = None
                counter.destroy()
                if not self.recorder.active:
                    self.close_portal_stream()
                self.busy = False
                self.update_recording()
                self.show_main()
            return True

        def tick():
            if self.counter is not counter:
                return False
            label.set_markup('<span size="36000" weight="bold">' + str(remaining[0]) + '</span>')
            remaining[0] -= 1
            if remaining[0] < 0:
                self.counter = None
                counter.destroy()
                GLib.timeout_add(180, lambda: (self.guard(callback), False)[1])
                return False
            return True
        counter.connect("key-press-event", lambda _, event: cancel() if event.keyval == Gdk.KEY_Escape else False)
        counter.connect("delete-event", cancel)
        tick()
        counter.show_all()
        counter.present()
        GLib.timeout_add_seconds(1, tick)

    def capture(self, mode):
        if self.busy or self.recorder.active or self.modal_depth or not self.save_current():
            return
        target = None
        if mode == "window" and not is_wayland():
            choices = windows(self.get_window())
            if not choices:
                self.set_status(L.t("linux.noWindows"))
                return
            dialog = Gtk.Dialog(title=L.t("capture.chooseWindow"), transient_for=self, modal=True)
            dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("capture.confirmWindow"), Gtk.ResponseType.OK)
            chooser = Gtk.ComboBoxText()
            for index, choice in enumerate(choices):
                chooser.append(str(index), choice.title)
            chooser.set_active(0)
            chooser.set_margin_top(24)
            chooser.set_margin_bottom(24)
            chooser.set_margin_start(24)
            chooser.set_margin_end(24)
            dialog.get_content_area().add(chooser)
            response, selected = self.run_dialog(dialog, chooser.get_active_id)
            if response != Gtk.ResponseType.OK:
                return
            target = choices[int(selected)]
            target.window.focus(Gdk.CURRENT_TIME)
        self.busy = True
        self.update_recording()
        self.hide()

        def completed(image):
            try:
                if image is not None:
                    surface = image if hasattr(image, "get_format") else surface_from_pixbuf(image)
                    self.add_image(surface, L.t({"region": "source.region", "screen": "source.desktop", "window": "capture.window"}[mode]))
                else:
                    self.set_status(L.t("status.cancelled"))
            except Exception as error:
                self.error(error)
            finally:
                self.busy = False
                self.update_recording()
                self.show_main()

        def portal_done(error, path):
            if error:
                self.busy = False
                self.show_main()
                self.update_recording()
                if str(error) == L.t("status.cancelled"):
                    self.set_status(str(error))
                else:
                    self.error(error)
            else:
                try:
                    completed(load_image(path))
                except Exception as failure:
                    self.busy = False
                    self.show_main()
                    self.update_recording()
                    self.error(failure)

        def perform():
            try:
                if is_wayland():
                    self.portal = self.portal or PortalClient()
                    self.portal.screenshot(mode, portal_done)
                elif mode == "region":
                    picker = RegionSelector(desktop_pixbuf(), completed)
                    picker.show_all()
                    picker.present()
                else:
                    completed(window_pixbuf(target) if target else desktop_pixbuf())
            except Exception as error:
                self.busy = False
                self.update_recording()
                self.show_main()
                self.error(error)
        self.countdown(self.store.settings["CaptureDelay"], perform)

    def open_recording(self):
        if self.recorder.active:
            self.stop_recording()
            return
        if self.busy or not self.show_home():
            return
        self.stack.set_visible_child_name("recorder")
        self.update_recording()
        self.show_main()

    def audio_changed(self, widget):
        value = widget.get_active()
        if self.recorder.active or self.busy or value == self.store.settings["SystemAudio"]:
            return
        self.store.settings["SystemAudio"] = value
        self.guard(self.store.save_settings)

    def start_recording(self):
        if self.busy or self.recorder.active or self.modal_depth or not self.save_current():
            return
        self.busy = True
        self.record_error = None
        self.store.settings["SystemAudio"] = self.audio.get_active()
        try:
            self.store.save_settings()
        except Exception:
            self.busy = False
            self.update_recording()
            raise
        self.update_recording()
        self.hide()

        def start_stream(error=None, stream=None):
            if error:
                self.record_failed(str(error))
                return
            self.portal_stream = stream
            self.countdown(max(3, self.store.settings["CaptureDelay"]), launch)

        def launch():
            try:
                rectangle = list(primary_rectangle())
                rectangle[2] -= rectangle[2] % 2
                rectangle[3] -= rectangle[3] % 2
                self.recorder.start(self.store.root / "videos", self.store.settings["SystemAudio"], rectangle=rectangle,
                    stream=self.portal_stream, on_started=self.record_started, on_completed=self.record_completed, on_failed=self.record_failed)
                if self.portal_stream:
                    os.close(self.portal_stream["fd"])
                    self.portal_stream["fd"] = None
            except Exception as error:
                self.record_failed(str(error))

        if is_wayland():
            try:
                self.portal = self.portal or PortalClient()
                self.portal.screencast(start_stream)
            except Exception as error:
                self.record_failed(str(error))
        else:
            start_stream()

    def record_started(self):
        self.busy = False
        self.record_bar = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.record_bar.set_title("SuniCapture · " + L.t("linux.recording"))
        self.record_bar.set_decorated(False)
        self.record_bar.set_keep_above(True)
        self.record_bar.set_skip_taskbar_hint(True)
        panel = Gtk.Box(spacing=12)
        panel.set_border_width(12)
        self.record_clock = Gtk.Label(label="●  00:00:00")
        panel.pack_start(self.record_clock, False, False, 0)
        stop = Gtk.Button(label=L.t("record.stopSave"))
        self.style(stop, "danger")
        stop.connect("clicked", lambda *_: self.stop_recording())
        panel.pack_start(stop, False, False, 0)
        self.record_bar.add(panel)
        self.record_bar.connect("delete-event", lambda *_: (self.stop_recording(), True)[1])
        screen = Gdk.Screen.get_default()
        self.record_bar.move(max(0, screen.get_width() - 380), 22)
        self.record_bar.show_all()
        self.update_recording()

    def stop_recording(self):
        if self.recorder.active:
            self.recorder.stop()
            self.update_recording()

    def close_portal_stream(self):
        if self.portal_stream:
            if self.portal_stream.get("fd") is not None:
                os.close(self.portal_stream["fd"])
            if self.portal:
                self.portal.close_session(self.portal_stream["session"])
            self.portal_stream = None

    def finish_recording_ui(self):
        self.busy = False
        if self.record_bar:
            self.record_bar.destroy()
            self.record_bar = None
            self.record_clock = None
        self.close_portal_stream()
        self.update_recording()
        self.show_main()

    def record_completed(self, path, duration, width, height):
        try:
            self.finish_recording_ui()
            item = self.store.add_video(path, duration, width, height)
            self.filter = "all"
            self.search.set_text("")
            self.open_item(item)
            self.refresh_library()
            self.set_status(L.t("linux.recordSaved"))
        except Exception as error:
            self.error(error)
        if self.exit_after_recording:
            self.quit()

    def record_failed(self, message):
        self.record_error = message
        self.exit_after_recording = False
        self.finish_recording_ui()
        self.error(message)

    def update_recording(self):
        running = self.recorder.active
        stopping = self.recorder.stopping
        self.record_state.set_text(L.t("record.savingMp4" if stopping else "record.inProgress" if running else "linux.recordPreparing" if self.busy else "record.failed" if self.record_error else "record.ready"))
        self.record_button.set_label(L.t("record.finalizingShort" if stopping else "record.stopVideo" if running else "record.title"))
        self.record_button.set_sensitive(not self.busy and not stopping)
        self.start_button.set_sensitive(not self.busy and not running)
        self.stop_button.set_sensitive(running and not stopping)
        self.audio.set_sensitive(not running and not self.busy)
        for button in self.capture_controls:
            button.set_sensitive(not running and not self.busy)
        self.record_help.set_text(L.t("record.finalizingHelp" if stopping else "record.runningHelp" if running else "linux.recordHelp"))

    def tick_recording(self):
        total = max(0, int(time.monotonic() - self.recorder.started_at)) if self.recorder.started_at and self.recorder.active else 0
        text = f"{total // 3600:02}:{total // 60 % 60:02}:{total % 60:02}"
        self.elapsed.set_text(text)
        if self.record_clock:
            self.record_clock.set_text("●  " + text if not self.recorder.stopping else L.t("record.finishing"))
        return True

    def load_video(self, path):
        for child in self.video_holder.get_children():
            self.video_holder.remove(child)
        try:
            import gi
            gi.require_version("Gst", "1.0")
            from gi.repository import Gst
            Gst.init(None)
            self.playbin = Gst.ElementFactory.make("playbin", "preview")
            sink = Gst.ElementFactory.make("gtksink", "video-preview")
            if not self.playbin or not sink:
                raise RuntimeError(L.t("video.noPreview"))
            self.playbin.set_property("video-sink", sink)
            self.playbin.set_property("uri", Path(path).resolve().as_uri())
            widget = sink.get_property("widget")
            self.video_holder.pack_start(widget, True, True, 0)
            widget.show()
            self.playbin.set_state(Gst.State.PAUSED)
            self.playing = False
        except Exception:
            self.stop_video()
            self.video_holder.pack_start(Gtk.Label(label=L.t("video.noPreview")), True, True, 0)
            self.video_holder.show_all()

    def play_video(self):
        if self.playbin:
            from gi.repository import Gst
            self.playing = not self.playing
            self.playbin.set_state(Gst.State.PLAYING if self.playing else Gst.State.PAUSED)

    def stop_video(self):
        if self.playbin:
            from gi.repository import Gst
            self.playbin.set_state(Gst.State.NULL)
            self.playbin = None
            self.playing = False

    def start_desktop_integration(self, *_):
        if not is_wayland():
            try:
                from .shortcuts import Shortcuts
                self.shortcuts = Shortcuts(self.hotkey)
                if self.shortcuts.conflicts:
                    self.set_status(L.t("linux.globalConflict"))
            except Exception:
                self.set_status(L.t("linux.globalConflict"))
        self.tray = Gtk.StatusIcon.new_from_file(str(brand_path("sunicapture-icon.png")))
        self.tray.set_tooltip_text(L.t("linux.trayHint"))
        self.tray.connect("activate", lambda *_: self.show_main())
        self.tray.connect("popup-menu", self.tray_menu)
        self.tray.set_visible(True)
        if self.store.warning:
            self.set_status(self.store.warning)

    def tray_menu(self, status, button, timestamp):
        menu = Gtk.Menu()
        for key, action in (("tray.open", self.show_main), ("capture.region", lambda: self.capture("region")),
                            ("record.title", self.open_recording), ("about.title", self.about_dialog), ("action.quit", self.quit)):
            item = Gtk.MenuItem(label=L.t(key))
            item.connect("activate", lambda _, action=action: self.guard(action))
            menu.append(item)
        menu.show_all()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, status, button, timestamp)

    def hotkey(self, number):
        if self.modal_depth or self.busy:
            return
        if number == 4:
            if self.recorder.active:
                self.stop_recording()
            else:
                self.open_recording()
                self.guard(self.start_recording)
        else:
            self.guard(lambda: self.capture({1: "region", 2: "screen", 3: "window"}[number]))

    def on_key(self, widget, event):
        if event.keyval == Gdk.KEY_F1:
            self.guard(self.help_dialog)
            return True
        if self.busy:
            return False
        key = Gdk.keyval_name(event.keyval).lower()
        ctrl = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(event.state & Gdk.ModifierType.SHIFT_MASK)
        text_input = isinstance(self.get_focus(), (Gtk.Entry, Gtk.TextView))
        if ctrl and shift and key in ("1", "exclam", "2", "at", "3", "numbersign", "4", "dollar"):
            self.hotkey({"1": 1, "exclam": 1, "2": 2, "at": 2, "3": 3, "numbersign": 3, "4": 4, "dollar": 4}[key])
            return True
        actions = {"o": self.import_dialog, "s": lambda: self.save_current(True), "e": self.export_current}
        if not text_input:
            actions.update(v=self.paste, c=self.copy_image, z=self.undo, y=self.redo)
        if ctrl and key in actions:
            self.guard(actions[key])
            return True
        tools = dict(v="select", a="arrow", r="rectangle", o="ellipse", p="pen", h="highlight", t="text", n="step", b="redact", c="crop")
        if not ctrl and not text_input and self.stack.get_visible_child_name() == "editor" and key in tools:
            self.set_tool(tools[key])
            return True
        return False

    def on_close(self, *_):
        if self.recorder.active:
            dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION, text=L.t("linux.closeRecording"))
            dialog.add_buttons(L.t("action.cancel"), Gtk.ResponseType.CANCEL, L.t("record.stopSave"), Gtk.ResponseType.OK)
            if self.run_dialog(dialog)[0] == Gtk.ResponseType.OK:
                self.exit_after_recording = True
                self.stop_recording()
            return True
        if self.busy:
            return True
        if not self.save_current():
            return True
        if not self.qa and self.store.settings["MinimizeToTray"] and self.tray and self.tray.is_embedded():
            self.hide()
            return True
        self.quit()
        return True

    def quit(self):
        if self.recorder.active:
            self.exit_after_recording = True
            self.stop_recording()
            return
        if not self.save_current():
            return
        width, height = self.get_size()
        self.store.settings.update(WindowWidth=width, WindowHeight=height)
        self.guard(self.store.save_settings)
        self.stop_video()
        self.close_portal_stream()
        if self.shortcuts:
            self.shortcuts.close()
            self.shortcuts = None
        if self.tray:
            self.tray.set_visible(False)
            self.tray = None
        if self.record_timer:
            GLib.source_remove(self.record_timer)
            self.record_timer = None
        application = self.get_application()
        self.destroy()
        if application:
            application.quit()


class Application(Gtk.Application):
    def __init__(self, arguments):
        flags = Gio.ApplicationFlags.HANDLES_COMMAND_LINE
        if arguments.data_dir or arguments.qa:
            flags |= Gio.ApplicationFlags.NON_UNIQUE
        super().__init__(application_id="ch.suniworks.SuniCapture", flags=flags)
        self.arguments = arguments
        self.window = None
        self.exit_code = 0

    def do_activate(self):
        if self.window is None:
            self.window = MainWindow(self, self.arguments.data_dir, self.arguments.qa)
            self.window.show_all()
            self.window.update_editor()
        self.window.show_main()

    def do_command_line(self, command_line):
        self.activate()
        args = parse_arguments(command_line.get_arguments()[1:])
        cwd = Path(command_line.get_cwd() or os.getcwd())
        if args.files:
            self.window.guard(lambda: self.window.import_paths([str(Path(path) if Path(path).is_absolute() else cwd / path) for path in args.files]))
        if args.record:
            self.window.open_recording()
        if args.capture_region:
            self.window.capture("region")
        if args.capture_screen:
            self.window.capture("screen")
        if args.capture_window:
            self.window.capture("window")
        return 0


def parse_arguments(arguments=None):
    parser = argparse.ArgumentParser(description="SuniCapture: local screenshots, annotations and screen recording.")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--data-dir")
    parser.add_argument("--qa", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--record", action="store_true", help="Open the recording workspace without starting recording.")
    parser.add_argument("--capture-region", action="store_true")
    parser.add_argument("--capture-screen", action="store_true")
    parser.add_argument("--capture-window", action="store_true")
    parser.add_argument("files", nargs="*")
    return parser.parse_args(arguments)


def main():
    arguments = parse_arguments()
    if arguments.self_test:
        from .diagnostics import run
        return 0 if run(arguments.data_dir) else 1
    if not Gtk.init_check()[0]:
        print("SuniCapture needs an X11 or Wayland desktop session.", file=sys.stderr)
        return 1
    application = Application(arguments)
    return application.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
