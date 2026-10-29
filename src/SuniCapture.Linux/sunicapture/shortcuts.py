"""Own only this process's X11 key grabs; Wayland uses desktop-managed shortcuts."""
import ctypes
import ctypes.util

from .runtime import GLib


class KeyEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("root", ctypes.c_ulong),
                ("subwindow", ctypes.c_ulong), ("time", ctypes.c_ulong), ("x", ctypes.c_int), ("y", ctypes.c_int),
                ("x_root", ctypes.c_int), ("y_root", ctypes.c_int), ("state", ctypes.c_uint),
                ("keycode", ctypes.c_uint), ("same_screen", ctypes.c_int)]


class Event(ctypes.Union):
    _fields_ = [("type", ctypes.c_int), ("key", KeyEvent), ("padding", ctypes.c_long * 24)]


class Shortcuts:
    def __init__(self, callback):
        self.callback = callback
        self.display = None
        self.timer = None
        self.registered = {}
        self.conflicts = []
        self.lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        for name, types, result in (
            ("XOpenDisplay", [ctypes.c_char_p], ctypes.c_void_p),
            ("XDefaultRootWindow", [ctypes.c_void_p], ctypes.c_ulong),
            ("XStringToKeysym", [ctypes.c_char_p], ctypes.c_ulong),
            ("XKeysymToKeycode", [ctypes.c_void_p, ctypes.c_ulong], ctypes.c_uint),
            ("XGrabKey", [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int], ctypes.c_int),
            ("XUngrabKey", [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong], ctypes.c_int),
            ("XSync", [ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            ("XPending", [ctypes.c_void_p], ctypes.c_int),
            ("XNextEvent", [ctypes.c_void_p, ctypes.POINTER(Event)], ctypes.c_int),
            ("XCloseDisplay", [ctypes.c_void_p], ctypes.c_int),
            ("XSetErrorHandler", [ctypes.c_void_p], ctypes.c_void_p)):
            function = getattr(self.lib, name)
            function.argtypes, function.restype = types, result
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("X11 display unavailable.")
        self.root = self.lib.XDefaultRootWindow(self.display)
        errors = []
        handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
        handler = handler_type(lambda *_: errors.append(True) or 0)
        previous = self.lib.XSetErrorHandler(ctypes.cast(handler, ctypes.c_void_p))
        try:
            for number in range(1, 5):
                key = self.lib.XKeysymToKeycode(self.display, self.lib.XStringToKeysym(str(number).encode()))
                errors.clear()
                for lock in (0, 2, 16, 18):
                    self.lib.XGrabKey(self.display, key, 5 | lock, self.root, 0, 1, 1)
                self.lib.XSync(self.display, 0)
                if errors:
                    for lock in (0, 2, 16, 18):
                        self.lib.XUngrabKey(self.display, key, 5 | lock, self.root)
                    self.conflicts.append(number)
                else:
                    self.registered[key] = number
        finally:
            self.lib.XSync(self.display, 0)
            self.lib.XSetErrorHandler(previous)
        self.timer = GLib.timeout_add(60, self.poll)

    def poll(self):
        while self.display and self.lib.XPending(self.display):
            event = Event()
            self.lib.XNextEvent(self.display, ctypes.byref(event))
            if event.type == 2 and event.key.keycode in self.registered:
                self.callback(self.registered[event.key.keycode])
        return bool(self.display)

    def close(self):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        if self.display:
            for key in self.registered:
                for lock in (0, 2, 16, 18):
                    self.lib.XUngrabKey(self.display, key, 5 | lock, self.root)
            self.lib.XSync(self.display, 0)
            self.lib.XCloseDisplay(self.display)
            self.display = None
