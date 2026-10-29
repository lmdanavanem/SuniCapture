"""Validate complete GTK windows and popups on an isolated Linux desktop."""
from pathlib import Path
import hashlib
import ctypes as C
import ctypes.util
import json
import os
import subprocess
import tempfile
import time
import traceback

from . import VERSION
from .runtime import Gtk, Gdk, GLib, L, drain
from .app import MainWindow
from .capture import capture_rectangle
from .diagnostics import fixture, spin


def settle(seconds=.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        drain()
        time.sleep(.01)


def descendants(widget):
    yield widget
    children = []
    if isinstance(widget, Gtk.Container):
        widget.forall(children.append)
    for child in children:
        yield from descendants(child)


def caption_buttons(window):
    return [widget for widget in descendants(window.get_titlebar())
            if isinstance(widget, Gtk.Button) and widget.get_visible()
            and "titlebutton" in widget.get_style_context().list_classes()]


def luminance(color):
    values = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4
              for value in (color.red, color.green, color.blue)]
    return .2126 * values[0] + .7152 * values[1] + .0722 * values[2]


def contrast(first, second):
    low, high = sorted((luminance(first), luminance(second)))
    return (high + .05) / (low + .05)


def full_snapshot(window, path):
    settle()
    display = Gdk.Display.get_default()
    display.sync()
    rect = window.get_window().get_frame_extents()
    scale = window.get_scale_factor()
    # Popup frame extents use different units on some GTK/X11 versions at 2x.
    # Read the actual X11 geometry so evidence includes every physical pixel.
    import gi
    gi.require_version("GdkX11", "3.0")
    from gi.repository import GdkX11
    library = C.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    library.XOpenDisplay.argtypes, library.XOpenDisplay.restype = [C.c_char_p], C.c_void_p
    library.XDefaultRootWindow.argtypes, library.XDefaultRootWindow.restype = [C.c_void_p], C.c_ulong
    library.XGetGeometry.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_int), C.POINTER(C.c_int),
        C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint)]
    library.XTranslateCoordinates.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong, C.c_int, C.c_int, C.POINTER(C.c_int), C.POINTER(C.c_int), C.POINTER(C.c_ulong)]
    library.XCloseDisplay.argtypes = [C.c_void_p]
    native = library.XOpenDisplay(None)
    identity = GdkX11.X11Window.get_xid(window.get_window())
    root, child = C.c_ulong(), C.c_ulong()
    x, y = C.c_int(), C.c_int()
    width, height, border, depth = C.c_uint(), C.c_uint(), C.c_uint(), C.c_uint()
    try:
        library.XGetGeometry(native, identity, C.byref(root), C.byref(x), C.byref(y), C.byref(width), C.byref(height), C.byref(border), C.byref(depth))
        library.XTranslateCoordinates(native, identity, library.XDefaultRootWindow(native), 0, 0, C.byref(x), C.byref(y), C.byref(child))
        image = capture_rectangle(max(0, x.value), max(0, y.value), width.value, height.value)
    finally:
        library.XCloseDisplay(native)
    image.savev(str(path), "png", [], [])
    return dict(width=width.value, height=height.value, scale=scale, units="physical pixels", screenshot=path.name)


def run(output_root=None):
    if not Gtk.init_check()[0]:
        print("Visual checks need a graphical session; use a dedicated Xvfb desktop.")
        return False
    root = Path(output_root or tempfile.mkdtemp(prefix="sunicapture-visual-"))
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="run-", dir=root))
    images = directory / "screenshots"
    images.mkdir()
    checks, evidence = [], []
    failure = None
    window = dialog = menu = None
    wm = subprocess.Popen(["openbox", "--sm-disable"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def require(value, description):
        if not value:
            raise AssertionError(description)
        checks.append(description)
        print("PASS: " + description, flush=True)
    def frame_fits(target):
        frame = target.get_window().get_frame_extents()
        area = target.get_display().get_monitor_at_window(target.get_window()).get_workarea()
        return frame.width <= area.width and frame.height <= area.height
    try:
        Gtk.Settings.get_default().set_property("gtk-dialogs-use-header", True)
        Gtk.Settings.get_default().set_property("gtk-theme-name", os.environ.get("SUNICAPTURE_TEST_THEME", "Adwaita"))
        settle(.4)
        window = MainWindow(data_dir=directory / "profile", qa=True)
        window.show_all()
        window.present()
        settle(.8)
        require(frame_fits(window), "Initial complete window fits the desktop work area")
        buttons = caption_buttons(window)
        require(len(buttons) == 3, "Main title bar exposes minimize, maximize and close")
        require(all(24 <= button.get_allocated_width() <= 36 and 24 <= button.get_allocated_height() <= 34 for button in buttons),
                "Native caption buttons have compact logical dimensions")
        require(window.header_bar.get_allocated_height() <= 56, "A single compact title bar contains product and window controls")
        minimized = next(button for button in buttons if "minimize" in button.get_style_context().list_classes())
        minimized.clicked()
        spin(lambda: bool(window.get_window().get_state() & Gdk.WindowState.ICONIFIED))
        window.deiconify()
        window.present()
        spin(lambda: not window.get_window().get_state() & Gdk.WindowState.ICONIFIED)
        require(window.get_visible(), "Native minimize and restore leave the application usable")
        maximized = next(button for button in caption_buttons(window) if "maximize" in button.get_style_context().list_classes())
        maximized.clicked()
        spin(window.is_maximized)
        require(frame_fits(window), "Native maximize fits the complete window to the work area")
        settle()
        # GTK rebuilds its caption controls when the window state changes.
        maximized = next(button for button in caption_buttons(window)
                         if set(button.get_style_context().list_classes()) & {"maximize", "unmaximize"})
        maximized.clicked()
        spin(lambda: not window.is_maximized())
        item = window.add_image(fixture(), "Synthetic verification", "Atlas — user title")
        original = window.store.resolve(item["OriginalFile"])
        digest = hashlib.sha256(original.read_bytes()).hexdigest()
        for dark in (False, True):
            window.store.settings["DarkMode"] = dark
            window.apply_theme()
            for language in ("en", "fr"):
                window.change_language(language)
                suffix = language + ("-dark" if dark else "-light")
                window.show_home()
                evidence.append(full_snapshot(window, images / ("home-" + suffix + ".png")))
                menu = window.language_menu(window.language_button)
                settle()
                children = menu.get_children()
                background = menu.get_style_context().get_background_color(Gtk.StateFlags.NORMAL)
                foreground = children[0].get_style_context().get_color(Gtk.StateFlags.NORMAL)
                require(background.alpha > .99 and contrast(background, foreground) >= 4.5, suffix + " language menu has readable text on an opaque matching surface")
                require(all(26 <= child.get_allocated_height() <= 40 for child in children), suffix + " language menu rows stay compact")
                evidence.append(full_snapshot(menu.get_toplevel(), images / ("menu-" + suffix + ".png")))
                menu.popdown()
                menu.destroy()
                menu = None
                selected = window.filter_buttons["all"]
                require(contrast(selected.get_style_context().get_background_color(Gtk.StateFlags.NORMAL), selected.get_style_context().get_color(Gtk.StateFlags.NORMAL)) >= 4.5,
                        suffix + " selected navigation remains readable")
                window.open_item(item)
                settle()
                require(window.save_button.get_mapped() and frame_fits(window), suffix + " editor and export controls remain inside the desktop")
                evidence.append(full_snapshot(window, images / ("editor-" + suffix + ".png")))
                for name, factory in (("about", window.create_about), ("help", window.create_help), ("preferences", lambda: window.create_settings()[0])):
                    dialog = factory()
                    dialog.show_all()
                    dialog.present()
                    settle()
                    buttons = caption_buttons(dialog)
                    require(frame_fits(dialog) and dialog.get_action_area().get_mapped(), name + " " + suffix + " fits with its title bar and footer")
                    require(buttons and all(button.get_allocated_width() <= 36 and button.get_allocated_height() <= 34 for button in buttons), name + " " + suffix + " has a compact native close control")
                    evidence.append(full_snapshot(dialog, images / (name + "-" + suffix + ".png")))
                    buttons[-1].clicked()
                    settle()
                    require(not dialog.get_visible(), name + " " + suffix + " closes through its native caption button")
                    dialog.destroy()
                    dialog = None
        # Open the actual file choosers, inspect their controls, and cancel before any write.
        original_runner = window.run_dialog
        def inspect_dialog(target, value=None):
            target.show_all()
            target.present()
            settle()
            action = target.get_widget_for_response(Gtk.ResponseType.OK)
            evidence.append(full_snapshot(target, images / ("file-chooser-" + str(len(evidence)) + ".png")))
            require(action and action.get_allocated_height() <= 44, "System file chooser keeps native action-button dimensions")
            require(frame_fits(target), "System file chooser fits the desktop")
            target.destroy()
            return Gtk.ResponseType.CANCEL, None
        window.run_dialog = inspect_dialog
        window.import_dialog()
        window.export_current()
        window.run_dialog = original_runner
        require(hashlib.sha256(original.read_bytes()).hexdigest() == digest and item["Name"] == "Atlas — user title", "Visual validation preserves original bytes and user-entered titles")
        next(button for button in caption_buttons(window) if "close" in button.get_style_context().list_classes()).clicked()
        settle()
        require(not window.get_visible(), "Main native close exits without leaving an inaccessible hidden window")
        window = None
    except Exception:
        failure = traceback.format_exc()
    finally:
        if menu:
            menu.destroy()
        if dialog:
            dialog.destroy()
        if window:
            window.quit()
        wm.terminate()
        wm.wait(timeout=3)
    report = dict(success=failure is None, version=VERSION, count=len(checks), checks=checks, failure=failure,
                  scale=int(os.environ.get("GDK_SCALE", "1")), theme=Gtk.Settings.get_default().get_property("gtk-theme-name"), evidence=evidence)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    (directory / "report.json").write_text(text, encoding="utf8")
    (root / "latest-report.json").write_text(text, encoding="utf8")
    print(text)
    return failure is None
