from __future__ import annotations

from dataclasses import dataclass, field
import math

from .runtime import Gtk, Gdk, Pango, PangoCairo, cairo

TOOLS = ("select", "arrow", "rectangle", "ellipse", "pen", "highlight", "text", "step", "redact", "crop")


def rgb(value):
    value = value.lstrip("#")
    if len(value) != 6:
        raise ValueError("Use a six-digit hexadecimal color.")
    return tuple(int(value[index:index + 2], 16) / 255 for index in (0, 2, 4))


@dataclass
class Shape:
    kind: str
    start: tuple
    end: tuple
    color: str = "#2563EB"
    width: float = 4
    text: str = ""
    font_size: float = 28
    number: int = 1
    points: list = field(default_factory=list)


def draw_shape(context, shape):
    x1, y1 = shape.start
    x2, y2 = shape.end
    x, y, width, height = min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1)
    context.save()
    context.set_source_rgb(*rgb(shape.color))
    context.set_line_width(shape.width)
    context.set_line_cap(cairo.LINE_CAP_ROUND)
    context.set_line_join(cairo.LINE_JOIN_ROUND)
    if shape.kind == "arrow":
        context.move_to(x1, y1)
        context.line_to(x2, y2)
        angle = math.atan2(y2 - y1, x2 - x1)
        head = max(14, shape.width * 4)
        context.move_to(x2 - head * math.cos(angle - .5), y2 - head * math.sin(angle - .5))
        context.line_to(x2, y2)
        context.line_to(x2 - head * math.cos(angle + .5), y2 - head * math.sin(angle + .5))
        context.stroke()
    elif shape.kind in ("rectangle", "highlight", "redact"):
        if shape.kind == "highlight":
            context.set_source_rgba(*rgb(shape.color), .32)
        context.rectangle(x, y, width, height)
        context.fill() if shape.kind != "rectangle" else context.stroke()
    elif shape.kind == "ellipse" and width > 0 and height > 0:
        context.translate(x + width / 2, y + height / 2)
        context.scale(width / 2, height / 2)
        context.arc(0, 0, 1, 0, 2 * math.pi)
        context.restore()
        context.save()
        context.set_source_rgb(*rgb(shape.color))
        context.set_line_width(shape.width)
        context.stroke()
    elif shape.kind == "pen" and shape.points:
        context.move_to(*shape.points[0])
        for point in shape.points[1:]:
            context.line_to(*point)
        context.stroke()
    elif shape.kind in ("text", "step"):
        layout = PangoCairo.create_layout(context)
        layout.set_text(str(shape.number) if shape.kind == "step" else shape.text, -1)
        description = Pango.FontDescription("Sans Bold")
        description.set_absolute_size(shape.font_size * Pango.SCALE)
        layout.set_font_description(description)
        tw, th = layout.get_pixel_size()
        if shape.kind == "step":
            radius = max(17, shape.font_size * .7)
            context.arc(x1, y1, radius, 0, 2 * math.pi)
            context.fill_preserve()
            context.set_source_rgb(1, 1, 1)
            context.set_line_width(2)
            context.stroke()
            context.move_to(x1 - tw / 2, y1 - th / 2)
        else:
            context.set_source_rgb(1, 1, 1)
            context.rectangle(x1 - 6, y1 - 3, tw + 12, th + 6)
            context.fill()
            context.set_source_rgb(*rgb(shape.color))
            context.move_to(x1, y1)
        PangoCairo.show_layout(context, layout)
    context.restore()


class CanvasModel:
    def __init__(self):
        self.base = None
        self.shapes = []
        self.undo_stack = []
        self.redo_stack = []
        self.revision = 0
        self.clean_revision = 0
        self.next_revision = 1

    @property
    def dirty(self):
        return self.revision != self.clean_revision

    def load(self, surface):
        self.base = surface
        self.shapes = []
        self.undo_stack.clear()
        self.redo_stack.clear()
        self.revision = self.clean_revision = 0
        self.next_revision = 1

    def snapshot(self):
        return self.base, list(self.shapes), self.revision

    def change(self):
        self.undo_stack.append(self.snapshot())
        self.undo_stack = self.undo_stack[-80:]
        self.redo_stack.clear()
        self.revision = self.next_revision
        self.next_revision += 1

    def add(self, shape):
        if self.base is None:
            return
        self.change()
        self.shapes.append(shape)

    def undo(self):
        if self.undo_stack:
            self.redo_stack.append(self.snapshot())
            self.base, self.shapes, self.revision = self.undo_stack.pop()

    def redo(self):
        if self.redo_stack:
            self.undo_stack.append(self.snapshot())
            self.base, self.shapes, self.revision = self.redo_stack.pop()

    def mark_clean(self):
        self.clean_revision = self.revision

    def render(self):
        if self.base is None:
            raise ValueError("No image to export.")
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.base.get_width(), self.base.get_height())
        context = cairo.Context(surface)
        context.set_source_surface(self.base, 0, 0)
        context.paint()
        for shape in self.shapes:
            draw_shape(context, shape)
        return surface

    def crop(self, x, y, width, height):
        if self.base is None:
            return
        x, y = max(0, int(x)), max(0, int(y))
        width = min(int(width), self.base.get_width() - x)
        height = min(int(height), self.base.get_height() - y)
        if width < 2 or height < 2:
            return
        image = self.render()
        result = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        context = cairo.Context(result)
        context.set_source_surface(image, -x, -y)
        context.paint()
        self.change()
        self.base, self.shapes = result, []


class AnnotationCanvas(Gtk.DrawingArea):
    def __init__(self, changed):
        super().__init__()
        self.model = CanvasModel()
        self.changed = changed
        self.tool = "arrow"
        self.color = "#2563EB"
        self.width = 4
        self.text = "Your text"
        self.font_size = 28
        self.zoom = 1
        self.draft = None
        self.set_can_focus(True)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.KEY_PRESS_MASK)
        self.connect("draw", self.draw)
        self.connect("button-press-event", self.press)
        self.connect("motion-notify-event", self.move)
        self.connect("button-release-event", self.release)
        self.connect("key-press-event", self.key)
        self.set_margin_start(30)
        self.set_margin_end(30)
        self.set_margin_top(30)
        self.set_margin_bottom(30)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)

    def load(self, surface):
        self.draft = None
        self.model.load(surface)
        self.update_size()
        self.queue_draw()

    def update_size(self):
        base = self.model.base
        self.set_size_request(max(1, int(base.get_width() * self.zoom)) if base else 1,
                              max(1, int(base.get_height() * self.zoom)) if base else 1)

    def set_zoom(self, zoom):
        self.zoom = min(6, max(.03, zoom))
        self.update_size()
        self.queue_draw()

    def point(self, event):
        base = self.model.base
        return (max(0, min(base.get_width(), event.x / self.zoom)), max(0, min(base.get_height(), event.y / self.zoom)))

    def press(self, widget, event):
        if event.button != 1 or self.model.base is None or self.tool == "select":
            return False
        self.grab_focus()
        point = self.point(event)
        self.draft = Shape(self.tool, point, point, self.color, self.width, self.text, self.font_size,
                           1 + sum(shape.kind == "step" for shape in self.model.shapes), [point])
        if self.tool in ("text", "step"):
            self.model.add(self.draft)
            self.draft = None
            self.changed()
        self.queue_draw()
        return True

    def move(self, widget, event):
        if self.draft:
            self.draft.end = self.point(event)
            if self.draft.kind == "pen":
                self.draft.points.append(self.draft.end)
            self.queue_draw()
        return bool(self.draft)

    def release(self, widget, event):
        if not self.draft:
            return False
        self.draft.end = self.point(event)
        shape = self.draft
        self.draft = None
        if shape.kind == "crop":
            self.model.crop(min(shape.start[0], shape.end[0]), min(shape.start[1], shape.end[1]),
                            abs(shape.end[0] - shape.start[0]), abs(shape.end[1] - shape.start[1]))
        elif shape.kind == "pen" or math.dist(shape.start, shape.end) >= 2:
            self.model.add(shape)
        self.update_size()
        self.queue_draw()
        self.changed()
        return True

    def key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape and self.draft:
            self.draft = None
            self.queue_draw()
            return True
        return False

    def draw(self, widget, context):
        if self.model.base is None:
            return False
        context.scale(self.zoom, self.zoom)
        context.set_source_rgb(1, 1, 1)
        context.paint()
        context.set_source_surface(self.model.base, 0, 0)
        context.paint()
        for shape in self.model.shapes:
            draw_shape(context, shape)
        if self.draft:
            if self.draft.kind == "crop":
                shape = Shape("rectangle", self.draft.start, self.draft.end, "#2563EB", 2)
                draw_shape(context, shape)
            else:
                draw_shape(context, self.draft)
        return False
