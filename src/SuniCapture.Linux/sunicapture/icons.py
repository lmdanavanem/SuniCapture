"""Small vector icons using the current GTK foreground color."""
import math
from .runtime import Gtk, cairo


class Icon(Gtk.DrawingArea):
    def __init__(self, name, size=18, color=None):
        super().__init__()
        self.name, self.size, self.color = name, size, color
        self.set_size_request(size, size)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)
        self.connect("draw", self.draw)

    def draw(self, widget, context):
        context.save()
        context.translate((self.get_allocated_width() - self.size) / 2, (self.get_allocated_height() - self.size) / 2)
        context.scale(self.size / 24, self.size / 24)
        color = self.get_style_context().get_color(self.get_state_flags())
        if self.color:
            value = self.color.lstrip("#")
            context.set_source_rgb(*(int(value[index:index + 2], 16) / 255 for index in (0, 2, 4)))
        else:
            context.set_source_rgba(color.red, color.green, color.blue, color.alpha)
        context.set_line_width(1.7)
        context.set_line_cap(cairo.LINE_CAP_ROUND)
        context.set_line_join(cairo.LINE_JOIN_ROUND)
        def line(*points):
            context.move_to(*points[0])
            for point in points[1:]:
                context.line_to(*point)
            context.stroke()
        def rect(x, y, width, height):
            context.rectangle(x, y, width, height)
            context.stroke()
        def circle(x, y, radius):
            context.arc(x, y, radius, 0, 2 * math.pi)
            context.stroke()
        name = self.name
        if name in ("region", "crop"):
            for points in (((3, 9), (3, 3), (9, 3)), ((15, 3), (21, 3), (21, 9)), ((21, 15), (21, 21), (15, 21)), ((9, 21), (3, 21), (3, 15))):
                line(*points)
            if name == "crop":
                line((7, 2), (7, 17), (22, 17))
        elif name == "screen":
            rect(3, 4, 18, 13)
            line((8, 21), (16, 21)); line((12, 17), (12, 21))
        elif name == "window":
            rect(3, 4, 18, 16); line((3, 9), (21, 9))
            circle(6, 6.5, .35); circle(9, 6.5, .35)
        elif name in ("record", "video"):
            rect(3, 6, 13, 12); line((16, 10), (22, 7), (22, 17), (16, 14))
        elif name in ("folder", "library", "import"):
            line((3, 7), (3, 5), (10, 5), (12, 8), (21, 8), (21, 19), (3, 19), (3, 7))
            if name == "import":
                line((12, 11), (12, 17)); line((9, 14), (12, 17), (15, 14))
        elif name == "paste":
            rect(6, 5, 14, 16); rect(9, 3, 8, 4)
        elif name == "globe":
            circle(12, 12, 9); line((3, 12), (21, 12))
            context.save(); context.translate(12, 12); context.scale(.45, 1); circle(0, 0, 9); context.restore()
        elif name == "help":
            circle(12, 12, 9); line((10, 8), (13, 8), (15, 10), (12, 13), (12, 14)); circle(12, 17, .4)
        elif name == "theme":
            circle(12, 12, 9)
            context.arc(12, 12, 6, -math.pi / 2, math.pi / 2); context.close_path(); context.fill()
        elif name == "settings":
            for x, y in ((5, 8), (12, 16), (19, 6)):
                line((x, 3), (x, y - 3)); line((x, y + 3), (x, 21)); circle(x, y, 3)
        elif name == "favorite":
            points = []
            for index in range(10):
                angle = -math.pi / 2 + index * math.pi / 5
                radius = 9 if index % 2 == 0 else 4
                points.append((12 + radius * math.cos(angle), 12 + radius * math.sin(angle)))
            line(*points, points[0])
        elif name == "trash":
            line((3, 6), (21, 6)); rect(8, 3, 8, 3)
            line((5, 6), (6, 21), (18, 21), (19, 6)); line((10, 10), (10, 17)); line((14, 10), (14, 17))
        elif name == "select":
            line((5, 3), (5, 20), (10, 15), (14, 22), (17, 20), (13, 13), (20, 13), (5, 3))
        elif name == "arrow":
            line((4, 20), (20, 4)); line((11, 4), (20, 4), (20, 13))
        elif name == "rectangle":
            rect(4, 5, 16, 14)
        elif name == "ellipse":
            context.save(); context.translate(12, 12); context.scale(1, .75); circle(0, 0, 9); context.restore()
        elif name in ("pen", "highlight"):
            line((4, 20), (6, 13), (17, 2), (22, 7), (11, 18), (4, 20)); line((14, 5), (19, 10))
            if name == "highlight":
                line((3, 22), (20, 22))
        elif name == "text":
            line((4, 6), (4, 3), (20, 3), (20, 6)); line((12, 3), (12, 21)); line((8, 21), (16, 21))
        elif name == "step":
            circle(12, 12, 9); line((10, 9), (12, 7), (12, 17)); line((9, 17), (15, 17))
        elif name == "redact":
            context.rectangle(3, 6, 18, 12); context.fill()
        elif name in ("undo", "redo"):
            if name == "redo":
                context.translate(24, 0); context.scale(-1, 1)
            line((9, 4), (3, 10), (9, 16))
            context.move_to(3, 10); context.line_to(13, 10); context.curve_to(21, 10, 21, 16, 19, 20); context.stroke()
        elif name == "home":
            line((3, 11), (12, 3), (21, 11)); line((6, 9), (6, 21), (18, 21), (18, 9))
        context.restore()
        return False
