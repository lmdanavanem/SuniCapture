from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import json
import math
import os
import re
import shutil
import uuid

from .runtime import Gdk, GdkPixbuf, cairo, L

MAX_PIXELS = 100_000_000


def now():
    return datetime.now(timezone.utc).isoformat()


def load_image(path):
    path = Path(path)
    if path.stat().st_size > 512 * 1024 * 1024:
        raise ValueError(L.t("image.limit"))
    info = GdkPixbuf.Pixbuf.get_file_info(str(path))
    if not info or info[1] < 1 or info[2] < 1 or info[1] * info[2] > MAX_PIXELS:
        raise ValueError(L.t("image.pixelLimit"))
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(path))
    return surface_from_pixbuf(pixbuf)


def surface_from_pixbuf(pixbuf):
    if pixbuf is None or pixbuf.get_width() * pixbuf.get_height() > MAX_PIXELS:
        raise ValueError(L.t("image.pixelLimit"))
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, pixbuf.get_width(), pixbuf.get_height())
    context = cairo.Context(surface)
    Gdk.cairo_set_source_pixbuf(context, pixbuf, 0, 0)
    context.paint()
    return surface


def surface_pixbuf(surface):
    surface.flush()
    return Gdk.pixbuf_get_from_surface(surface, 0, 0, surface.get_width(), surface.get_height())


def export_image(surface, path):
    path = Path(path)
    extension = path.suffix.lower()
    if extension not in (".png", ".jpg", ".jpeg", ".bmp", ".pdf"):
        raise ValueError(L.t("image.exportType"))
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        if extension == ".png":
            surface.write_to_png(str(temporary))
        else:
            opaque = cairo.ImageSurface(cairo.FORMAT_RGB24, surface.get_width(), surface.get_height())
            context = cairo.Context(opaque)
            context.set_source_rgb(1, 1, 1)
            context.paint()
            context.set_source_surface(surface, 0, 0)
            context.paint()
            if extension == ".pdf":
                pdf = cairo.PDFSurface(str(temporary), surface.get_width(), surface.get_height())
                context = cairo.Context(pdf)
                context.set_source_surface(opaque, 0, 0)
                context.paint()
                context.show_page()
                pdf.finish()
            else:
                surface_pixbuf(opaque).savev(str(temporary), "jpeg" if extension in (".jpg", ".jpeg") else "bmp", [], [])
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


class Store:
    def __init__(self, root=None):
        self.root = Path(root or Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "SuniCapture").resolve()
        self.warning = None
        for name in ("originals", "edited", "videos"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        items = self.read("library.json", [])
        self.items = []
        if isinstance(items, list):
            for item in items:
                try:
                    if not isinstance(item, dict) or not re.fullmatch(r"[0-9a-fA-F]{32}", item.get("Id", "")):
                        continue
                    self.resolve(item["OriginalFile"])
                    if item.get("EditedFile"):
                        self.resolve(item["EditedFile"])
                    self.items.append(item)
                except (ValueError, KeyError, TypeError):
                    continue
        loaded = self.read("settings.json", {})
        self.settings = {"Language": "en", "DarkMode": False, "CaptureDelay": 0, "CopyAfterCapture": True,
                         "SystemAudio": False, "MinimizeToTray": False, "WindowWidth": 1440, "WindowHeight": 940}
        if isinstance(loaded, dict):
            self.settings.update(loaded)
        self.settings["Language"] = "fr" if self.settings["Language"] == "fr" else "en"
        try:
            self.settings["CaptureDelay"] = min(10, max(0, int(self.settings.get("CaptureDelay", 0))))
        except (ValueError, TypeError):
            self.settings["CaptureDelay"] = 0

    def resolve(self, relative):
        if not isinstance(relative, str) or not relative or "\x00" in relative:
            raise ValueError(L.t("store.invalidPath"))
        normalized = relative.replace("\\", "/")
        if normalized.startswith("/") or ":" in normalized or ".." in Path(normalized).parts:
            raise ValueError(L.t("store.invalidPath"))
        path = (self.root / normalized).resolve()
        if not path.is_relative_to(self.root) or path == self.root:
            raise ValueError(L.t("store.outside"))
        return path

    def read(self, name, default):
        path = self.root / name
        if not path.exists():
            return default
        try:
            return json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            self.warning = L.t("library.loadWarning", name)
            try:
                shutil.copy2(path, path.with_name(path.name + ".unreadable-" + uuid.uuid4().hex[:8]))
                return json.loads(path.with_name(path.name + ".bak").read_text(encoding="utf-8-sig"))
            except (OSError, ValueError):
                return default

    def write(self, name, value):
        path = self.root / name
        temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
        try:
            with temporary.open("w", encoding="utf-8") as stream:
                json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
            if path.exists():
                shutil.copy2(path, path.with_name(path.name + ".bak"))
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()

    def save(self):
        self.write("library.json", self.items)

    def save_settings(self):
        self.write("settings.json", self.settings)

    def current_file(self, item):
        return self.resolve(item.get("EditedFile") or item["OriginalFile"])

    def add_image(self, surface, source, name=None):
        identity = uuid.uuid4().hex
        item = dict(Id=identity, Name=name or L.t("linux.captureName", datetime.now().strftime("%Y-%m-%d %H:%M")),
                    CreatedAt=now(), Kind="image", OriginalFile="originals/" + identity + ".png", EditedFile=None,
                    Width=surface.get_width(), Height=surface.get_height(), DurationSeconds=0,
                    Source=source, Favorite=False, IsTrashed=False, TrashedAt=None)
        export_image(surface, self.resolve(item["OriginalFile"]))
        self.items.insert(0, item)
        try:
            self.save()
        except Exception:
            self.items.remove(item)
            raise
        return item

    def save_edited(self, item, surface):
        relative = "edited/" + item["Id"] + ".png"
        previous = item.copy()
        export_image(surface, self.resolve(relative))
        item.update(EditedFile=relative, Width=surface.get_width(), Height=surface.get_height())
        try:
            self.save()
        except Exception:
            item.clear()
            item.update(previous)
            raise

    def add_video(self, path, duration, width, height):
        identity = uuid.uuid4().hex
        relative = "videos/" + identity + ".mp4"
        destination = self.resolve(relative)
        original = Path(path)
        if destination.exists():
            raise FileExistsError(destination)
        os.rename(original, destination)
        item = dict(Id=identity, Name=L.t("linux.recordingName", datetime.now().strftime("%Y-%m-%d %H:%M")),
                    CreatedAt=now(), Kind="video", OriginalFile=relative, EditedFile=None,
                    Width=width, Height=height, DurationSeconds=duration, Source=L.t("record.primary"),
                    Favorite=False, IsTrashed=False, TrashedAt=None)
        self.items.insert(0, item)
        try:
            self.save()
        except Exception:
            self.items.remove(item)
            os.rename(destination, original)
            raise
        return item
