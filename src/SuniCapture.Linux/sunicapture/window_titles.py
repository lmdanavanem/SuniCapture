"""Read bounded X11 window titles without relying on unbound GDK properties."""
import ctypes as C
import ctypes.util


class WindowTitles:
    def __init__(self):
        self.lib = C.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        for name, arguments, result in (
                ("XOpenDisplay", [C.c_char_p], C.c_void_p),
                ("XInternAtom", [C.c_void_p, C.c_char_p, C.c_int], C.c_ulong),
                ("XGetWindowProperty", [C.c_void_p, C.c_ulong, C.c_ulong, C.c_long, C.c_long, C.c_int,
                    C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_int), C.POINTER(C.c_ulong),
                    C.POINTER(C.c_ulong), C.POINTER(C.c_void_p)], C.c_int),
                ("XFree", [C.c_void_p], C.c_int),
                ("XSync", [C.c_void_p, C.c_int], C.c_int),
                ("XSetErrorHandler", [C.c_void_p], C.c_void_p),
                ("XCloseDisplay", [C.c_void_p], C.c_int)):
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("X11 display unavailable.")
        handler_type = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)
        self.handler = handler_type(lambda *_: 0)
        self.previous = self.lib.XSetErrorHandler(C.cast(self.handler, C.c_void_p))

    def title(self, identity):
        for name, codec in ((b"_NET_WM_NAME", "utf8"), (b"WM_NAME", "latin1")):
            atom = self.lib.XInternAtom(self.display, name, 1)
            if not atom:
                continue
            actual, format_, count, remaining, data = C.c_ulong(), C.c_int(), C.c_ulong(), C.c_ulong(), C.c_void_p()
            result = self.lib.XGetWindowProperty(self.display, identity, atom, 0, 4096, 0, 0,
                C.byref(actual), C.byref(format_), C.byref(count), C.byref(remaining), C.byref(data))
            try:
                if result == 0 and data.value and format_.value == 8:
                    return C.string_at(data, min(count.value, 16384)).decode(codec, errors="replace").rstrip("\0")
            finally:
                if data.value:
                    self.lib.XFree(data)
        return ""

    def close(self):
        self.lib.XSync(self.display, 0)
        self.lib.XSetErrorHandler(self.previous)
        self.lib.XCloseDisplay(self.display)
