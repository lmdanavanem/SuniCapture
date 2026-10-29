from pathlib import Path
import json
import os

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, Gio, Pango, PangoCairo
import cairo


def resource_root():
    installed = Path(__file__).resolve().parents[1]
    if (installed / "resources" / "strings.json").is_file():
        return installed / "resources"
    source = Path(__file__).resolve().parents[3]
    return source


def brand_path(name):
    root = resource_root()
    return root / "assets" / "Brand" / name


class Strings:
    def __init__(self):
        root = resource_root()
        path = root / "strings.json"
        if not path.is_file():
            path = root / "src" / "SuniCapture" / "Localization" / "strings.json"
        self.catalog = json.loads(path.read_text(encoding="utf-8"))
        local = Path(__file__).with_name("strings.json")
        self.catalog.update(json.loads(local.read_text(encoding="utf-8")))
        self.language = "en"

    def t(self, key, *args):
        value = self.catalog[key][self.language]
        return value.format(*args) if args else value

    def set_language(self, language):
        self.language = "fr" if language == "fr" else "en"


L = Strings()


def dispatch(callback, *args):
    def invoke():
        callback(*args)
        return False
    GLib.idle_add(invoke)


def drain():
    while Gtk.events_pending():
        Gtk.main_iteration_do(False)
