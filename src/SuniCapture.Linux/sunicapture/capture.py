from dataclasses import dataclass
import os
import subprocess

from .runtime import Gtk, Gdk, GdkPixbuf, Pango, PangoCairo, cairo, L
from .core import surface_from_pixbuf


def is_wayland():
    return os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland" or "wayland" in Gdk.Display.get_default().get_name().lower()


def desktop_pixbuf():
    if is_wayland():
        raise RuntimeError(L.t("linux.usePortal"))
    root = Gdk.get_default_root_window()
    return capture_rectangle(0, 0, root.get_width(), root.get_height())


def capture_rectangle(x, y, width, height):
    if width < 1 or height < 1 or width * height > 100_000_000:
        raise ValueError(L.t("image.pixelLimit"))
    source = os.environ.get("DISPLAY", ":0") + "+" + str(int(x)) + "," + str(int(y))
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "0", "-video_size",
               str(int(width)) + "x" + str(int(height)), "-i", source, "-frames:v", "1", "-threads", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"]
    result = subprocess.run(command, capture_output=True, timeout=15)
    if result.returncode != 0 or not result.stdout.startswith(b"\x89PNG"):
        raise RuntimeError(L.t("linux.captureFailed"))
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.write(result.stdout)
    loader.close()
    return loader.get_pixbuf().copy()


def primary_rectangle():
    display = Gdk.Display.get_default()
    monitor = display.get_primary_monitor() or display.get_monitor(0)
    geometry = monitor.get_geometry()
    return geometry.x, geometry.y, geometry.width, geometry.height


@dataclass
class WindowTarget:
    title: str
    window: object


def windows(exclude=None):
    import gi
    gi.require_version("GdkX11", "3.0")
    from gi.repository import GdkX11
    from .window_titles import WindowTitles
    screen = Gdk.Screen.get_default()
    choices = []
    titles = WindowTitles()
    try:
        for window in screen.get_window_stack() or []:
            if window == exclude or not window.is_visible() or window.is_destroyed():
                continue
            title = titles.title(GdkX11.X11Window.get_xid(window))
            choices.append(WindowTarget(title or L.t("capture.window"), window))
    finally:
        titles.close()
    return choices


def window_pixbuf(target):
    if target.window.is_destroyed():
        raise RuntimeError(L.t("desktop.closed"))
    rect = target.window.get_frame_extents()
    root = Gdk.get_default_root_window()
    x, y = max(0, rect.x), max(0, rect.y)
    width, height = min(rect.width, root.get_width() - x), min(rect.height, root.get_height() - y)
    if width < 2 or height < 2:
        raise RuntimeError(L.t("desktop.offscreen"))
    return capture_rectangle(x, y, width, height)


class RegionSelector(Gtk.Window):
    def __init__(self, snapshot, callback):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.snapshot = snapshot
        self.callback = callback
        self.start = None
        self.end = None
        self.completed = False
        self.set_title(L.t("region.title"))
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.move(0, 0)
        self.set_default_size(snapshot.get_width(), snapshot.get_height())
        self.area = Gtk.DrawingArea()
        self.area.set_size_request(snapshot.get_width(), snapshot.get_height())
        self.area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.POINTER_MOTION_MASK)
        self.area.connect("draw", self.draw)
        self.area.connect("button-press-event", self.press)
        self.area.connect("motion-notify-event", self.motion)
        self.area.connect("button-release-event", self.release)
        self.connect("key-press-event", self.key)
        self.connect("delete-event", lambda *_: self.finish(None))
        self.add(self.area)
        self.connect("realize", lambda *_: self.get_window().set_cursor(Gdk.Cursor.new_for_display(self.get_display(), Gdk.CursorType.CROSSHAIR)))

    def point(self, event):
        return (max(0, min(self.snapshot.get_width(), event.x)), max(0, min(self.snapshot.get_height(), event.y)))

    def press(self, widget, event):
        if event.button == 1:
            self.start = self.end = self.point(event)
            self.area.queue_draw()
        return True

    def motion(self, widget, event):
        if self.start:
            self.end = self.point(event)
            self.area.queue_draw()
        return True

    def release(self, widget, event):
        if self.start and event.button == 1:
            self.end = self.point(event)
            x, y = int(min(self.start[0], self.end[0])), int(min(self.start[1], self.end[1]))
            width, height = int(abs(self.end[0] - self.start[0])), int(abs(self.end[1] - self.start[1]))
            if width >= 2 and height >= 2:
                self.finish(self.snapshot.new_subpixbuf(x, y, width, height).copy())
        return True

    def key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.finish(None)
            return True
        return False

    def finish(self, image):
        if not self.completed:
            self.completed = True
            self.destroy()
            self.callback(image)
        return True

    def draw(self, widget, context):
        Gdk.cairo_set_source_pixbuf(context, self.snapshot, 0, 0)
        context.paint()
        context.set_source_rgba(.035, .06, .11, .5)
        context.rectangle(0, 0, self.snapshot.get_width(), self.snapshot.get_height())
        if self.start and self.end:
            x, y = min(self.start[0], self.end[0]), min(self.start[1], self.end[1])
            width, height = abs(self.end[0] - self.start[0]), abs(self.end[1] - self.start[1])
            context.rectangle(x, y, width, height)
            context.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
        context.fill()
        if self.start and self.end:
            context.set_source_rgb(.145, .388, .922)
            context.set_line_width(2)
            context.rectangle(x, y, width, height)
            context.stroke()
        layout = PangoCairo.create_layout(context)
        layout.set_text(L.t("region.instruction"), -1)
        layout.set_font_description(Pango.FontDescription("Sans 12"))
        tw, th = layout.get_pixel_size()
        context.set_source_rgba(.06, .09, .16, .96)
        context.rectangle((self.snapshot.get_width() - tw) / 2 - 18, 24, tw + 36, th + 22)
        context.fill()
        context.set_source_rgb(1, 1, 1)
        context.move_to((self.snapshot.get_width() - tw) / 2, 34)
        PangoCairo.show_layout(context, layout)
        return False
