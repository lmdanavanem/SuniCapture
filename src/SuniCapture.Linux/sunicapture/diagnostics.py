from __future__ import annotations

from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import tempfile
import time
import traceback
import faulthandler

from .runtime import Gtk, Gdk, GdkPixbuf, GLib, Pango, PangoCairo, cairo, L, drain
from .core import Store, export_image, load_image, surface_pixbuf
from .editor import CanvasModel, Shape, AnnotationCanvas, TOOLS
from .capture import desktop_pixbuf, primary_rectangle, RegionSelector, windows, window_pixbuf, capture_rectangle
from .recorder import Recorder, validate_mp4
from .app import MainWindow


def fixture(width=1120, height=720):
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    context = cairo.Context(surface)
    context.set_source_rgb(.956, .969, .985)
    context.paint()
    context.set_source_rgb(1, 1, 1)
    context.rectangle(0, 0, width, 78)
    context.fill()
    context.set_source_rgb(.145, .388, .922)
    context.rectangle(42, 125, width - 84, 155)
    context.fill()
    for index in range(3):
        context.set_source_rgb(1, 1, 1)
        context.rectangle(42, 320 + index * 87, width - 84, 65)
        context.fill()
    def text(value, x, y, size, color=(.06, .09, .16)):
        context.set_source_rgb(*color)
        layout = PangoCairo.create_layout(context)
        layout.set_text(value, -1)
        description = Pango.FontDescription("Sans Bold")
        description.set_absolute_size(size * Pango.SCALE)
        layout.set_font_description(description)
        context.move_to(x, y)
        PangoCairo.show_layout(context, layout)
    text("Atelier Atlas · Synthetic workspace", 30, 24, 23)
    text("Every detail matters", 70, 155, 30, (1, 1, 1))
    text("Fictional data for local capture verification", 72, 215, 18, (1, 1, 1))
    for index, value in enumerate(("Review navigation", "Check the content", "Validate images")):
        text("✓  " + value, 65, 338 + index * 87, 20)
    text("No real account, client or personal document.", 42, height - 50, 14)
    return surface


def pixels(surface):
    surface.flush()
    return hashlib.sha256(bytes(surface.get_data())).hexdigest()


def synthetic_blue(image):
    offset = 135 * image.get_rowstride() + 100 * image.get_n_channels()
    color = image.get_pixels()[offset:offset + 3]
    return len(color) == 3 and all(abs(actual - expected) <= 12 for actual, expected in zip(color, (37, 99, 235)))


def spin(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        drain()
        if condition():
            return
        time.sleep(.02)
    raise TimeoutError("Timed out while waiting for a Linux workflow.")


def snapshot(window, path):
    drain()
    # Mapping and resize notifications arrive asynchronously from the X server.
    deadline = time.monotonic() + .15
    while time.monotonic() < deadline:
        drain()
        time.sleep(.01)
    window.get_window().invalidate_rect(None, True)
    window.get_window().process_updates(True)
    Gdk.Display.get_default().sync()
    width, height = window.get_size()
    origin = window.get_window().get_origin()
    image = capture_rectangle(origin[-2], origin[-1], width, height)
    if image is None:
        raise RuntimeError("Could not render the Linux window.")
    image.savev(str(path), "png", [], [])


def run(output_root=None):
    faulthandler.enable()
    if not Gtk.init_check()[0]:
        print("Linux checks need a graphical session; run with xvfb-run.")
        return False
    root = Path(output_root or tempfile.mkdtemp(prefix="sunicapture-checks-"))
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="run-", dir=root))
    images = directory / "screenshots"
    images.mkdir()
    checks = []
    failure = None
    window = None
    cover = None
    wm = None
    def require(value, message):
        if not value:
            raise AssertionError(message)
        checks.append(message)
        print("PASS: " + message, flush=True)
    try:
        wm = subprocess.Popen(["openbox", "--sm-disable"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(.4)
        store = Store(directory / "core")
        original = fixture()
        item = store.add_image(original, "Synthetic verification", "Étude – capture été")
        original_path = store.resolve(item["OriginalFile"])
        digest = hashlib.sha256(original_path.read_bytes()).hexdigest()
        require(Store(store.root).items[0]["Name"] == item["Name"], "Library persists Unicode capture names")
        model = CanvasModel()
        model.load(original)
        initial = pixels(model.render())
        require(not model.dirty and not model.undo_stack, "Opening an image starts with a clean undo history")
        shapes = [Shape("arrow", (80, 85), (300, 220)), Shape("rectangle", (90, 320), (600, 390)),
                  Shape("ellipse", (350, 80), (550, 220)), Shape("pen", (50, 600), (300, 650), points=[(50, 600), (100, 620), (300, 650)]),
                  Shape("highlight", (45, 420), (900, 465)), Shape("text", (500, 110), (500, 110), text="Révision française – English"),
                  Shape("step", (1000, 340), (1000, 340), number=1), Shape("redact", (700, 500), (1000, 560), color="#DC2626")]
        for shape in shapes:
            before = pixels(model.render())
            model.add(shape)
            require(model.dirty and pixels(model.render()) != before, shape.kind + " changes exported image pixels")
        for _ in shapes:
            model.undo()
        require(pixels(model.render()) == initial and not model.dirty, "Undo restores original pixels and clean state")
        model.redo()
        require(model.dirty, "Redo restores an annotation")
        model.crop(20, 30, 600, 400)
        require(model.base.get_width() == 600 and model.base.get_height() == 400, "Crop uses image pixel coordinates")
        model.undo()
        require(model.base.get_width() == 1120, "Undo crop restores image dimensions")
        model.add(Shape("redact", (700, 500), (1000, 560), color="#DC2626"))
        result = model.render()
        for extension in ("png", "jpg", "bmp", "pdf"):
            path = directory / ("export." + extension)
            export_image(result, path)
            require(path.stat().st_size > 100, extension.upper() + " export produces a real output file")
            if extension != "pdf":
                decoded = load_image(path)
                require(decoded.get_width() == 1120 and decoded.get_height() == 720, extension.upper() + " export decodes with expected dimensions")
        require((directory / "export.pdf").read_bytes().startswith(b"%PDF"), "PDF export has a valid PDF header")
        store.save_edited(item, result)
        require(item["EditedFile"] and store.current_file(item).exists(), "Edited pixels are stored separately from the original")
        require(hashlib.sha256(original_path.read_bytes()).hexdigest() == digest, "Editing preserves original file bytes")
        item["Favorite"] = True
        item["IsTrashed"] = True
        store.save()
        require(Store(store.root).items[0]["Favorite"] and Store(store.root).items[0]["IsTrashed"], "Favorites and restorable Trash survive storage reload")
        item["IsTrashed"] = False
        store.save()
        require(not Store(store.root).items[0]["IsTrashed"], "Restoring a trashed capture preserves its original")
        for path in ("../escape.png", "/tmp/escape.png", "C:\\escape.png", "originals/../../escape.png"):
            try:
                store.resolve(path)
                raise AssertionError("Unsafe capture path accepted")
            except ValueError:
                checks.append("Library rejects unsafe path " + path)
        (store.root / "library.json").write_text("{ broken", encoding="utf8")
        recovered = Store(store.root)
        require(recovered.warning and recovered.items and list(store.root.glob("library.json.unreadable-*")), "A damaged index is preserved and recovered from its backup")
        window = MainWindow(data_dir=directory / "ui", qa=True)
        window.show_all()
        window.present()
        window.update_editor()
        drain()
        require(window.stack.get_visible_child_name() == "home" and L.language == "en", "Linux starts on the English home screen")
        snapshot(window, images / "home-en-light.png")
        current = window.add_image(fixture(), "Synthetic image", "Projet de démonstration")
        require(window.stack.get_visible_child_name() == "editor" and window.current is current, "An imported capture opens in the Linux editor")
        window.canvas.model.add(Shape("arrow", (300, 300), (640, 500)))
        window.canvas.model.add(Shape("step", (970, 430), (970, 430), number=1))
        window.canvas_changed()
        if window.save_timer:
            GLib.source_remove(window.save_timer)
            window.save_timer = None
        pending = pixels(window.canvas.model.render())
        window.annotation_text.set_text("Texte personnel / custom text")
        window.set_tool("highlight")
        window.change_language("fr")
        require(window.current is current and window.canvas.model.dirty and pixels(window.canvas.model.render()) == pending,
                "Changing language preserves the open capture and pending annotation pixels")
        require(window.canvas.tool == "highlight" and window.annotation_text.get_text() == "Texte personnel / custom text" and current["Name"] == "Projet de démonstration",
                "Changing language preserves active tool and user-entered names and text")
        require(Store(window.store.root).settings["Language"] == "fr" and window.tool_name.get_text() == "Surligner", "French preference persists and live tool labels update")
        require(window.save_current() and not window.canvas.model.dirty, "The Linux editor saves pending annotations")
        snapshot(window, images / "editor-fr-light.png")
        window.favorite()
        window.set_filter("favorite")
        require(len(window.library.get_children()) == 1, "Favorites filter includes the saved capture")
        window.search.set_text("missing-result")
        window.refresh_library()
        require(not window.library.get_children(), "Library search excludes nonmatching capture names")
        window.search.set_text("")
        window.set_filter("all")
        window.open_item(current)
        window.trash()
        require(current["IsTrashed"] and window.store.resolve(current["OriginalFile"]).exists(), "Trash keeps the original capture file")
        window.set_filter("trash")
        window.open_item(current)
        window.trash()
        require(not current["IsTrashed"], "The Linux UI restores a capture from Trash")
        window.set_filter("all")
        window.open_item(current)
        previous_settings = window.store.settings.copy()
        original_settings_factory = window.create_settings
        def altered_settings(response):
            dialog, fields = original_settings_factory()
            fields["language"].set_active_id("en")
            fields["theme"].set_active_id("dark")
            fields["copy"].set_active(not previous_settings["CopyAfterCapture"])
            GLib.timeout_add(120, lambda: (dialog.response(response), False)[1])
            return dialog, fields
        window.create_settings = lambda: altered_settings(Gtk.ResponseType.CANCEL)
        window.settings_dialog()
        require(window.store.settings == previous_settings, "Cancelling preferences discards language, theme and capture changes")
        window.create_settings = lambda: altered_settings(Gtk.ResponseType.OK)
        window.settings_dialog()
        window.create_settings = original_settings_factory
        require(L.language == "en" and window.store.settings["DarkMode"] and Store(window.store.root).settings["DarkMode"], "Saving preferences applies and persists English and dark mode")
        snapshot(window, images / "editor-en-dark.png")
        window.resize(1100, 700)
        deadline = time.monotonic() + .4
        while time.monotonic() < deadline:
            drain()
            time.sleep(.01)
        snapshot(window, images / "editor-compact-dark.png")
        print("Compact window size: " + str(tuple(window.get_size())), flush=True)
        require(window.get_size().width <= 1100 and window.get_size().height <= 740 and window.save_button.get_mapped(), "Compact Linux layout keeps editor export and save controls visible")
        for language in ("en", "fr"):
            window.change_language(language)
            for name, create in (("about", window.create_about), ("help", window.create_help), ("preferences", lambda: window.create_settings()[0])):
                dialog = create()
                dialog.show_all()
                drain()
                snapshot(dialog, images / (name + "-" + language + "-dark.png"))
                require(dialog.get_size().height < 1000 and dialog.get_action_area().get_mapped(), name + " " + language + " dialog keeps a visible fixed footer")
                dialog.destroy()
        window.change_language("en")
        window.store.settings["DarkMode"] = False
        window.apply_theme()
        window.resize(1440, 940)
        window.show_home()
        cover = Gtk.Window()
        cover.set_title("Synthetic capture verification")
        cover.set_decorated(False)
        cover.set_keep_above(True)
        root_window = Gdk.get_default_root_window()
        desktop_width, desktop_height = root_window.get_width(), root_window.get_height()
        scene = fixture(desktop_width, desktop_height)
        area = Gtk.DrawingArea()
        area.set_size_request(desktop_width, desktop_height)
        area.connect("draw", lambda _, context: (context.set_source_surface(scene, 0, 0), context.paint(), False)[2])
        cover.add(area)
        cover.move(0, 0)
        cover.show_all()
        drain()
        time.sleep(.2)
        require(cover.get_size().width == desktop_width and cover.get_size().height == desktop_height, "Synthetic content covers the isolated Linux desktop")
        desktop = desktop_pixbuf()
        require(desktop.get_width() == desktop_width and desktop.get_height() == desktop_height, "Native X11 screenshot reads actual desktop pixels")
        require(synthetic_blue(desktop), "X11 screenshot contains the synthetic scene's expected color pixels")
        choices = windows(window.get_window())
        target = next(choice for choice in choices if choice.title == "Synthetic capture verification")
        captured_window = window_pixbuf(target)
        require(captured_window.get_width() == desktop_width and captured_window.get_height() == desktop_height, "Native X11 window capture reads the selected window")
        selected = []
        picker = RegionSelector(desktop, selected.append)
        picker.show_all()
        drain()
        class Mouse:
            button = 1
            x = 120
            y = 90
        picker.press(picker.area, Mouse())
        event = Mouse()
        event.x, event.y = 520, 370
        picker.release(picker.area, event)
        require(selected and selected[0].get_width() == 400 and selected[0].get_height() == 280, "Region selection crops the requested frozen desktop pixels")
        before_count = len(window.store.items)
        window.capture("screen")
        spin(lambda: not window.busy and len(window.store.items) == before_count + 1)
        require(window.current["Width"] == desktop_width and window.current["Height"] == desktop_height, "Capture button workflow stores and opens a real X11 screenshot")
        window.open_recording()
        window.audio.set_active(False)
        window.start_recording()
        spin(lambda: window.record_bar is not None or window.record_error, 35)
        if window.record_error:
            raise RuntimeError("Recording failed: " + window.record_error)
        require(window.recorder.active and window.record_bar is not None and not window.start_button.get_sensitive() and window.stop_button.get_sensitive(),
                "Linux recording starts a real encoder and floating stop control")
        started = time.monotonic()
        spin(lambda: time.monotonic() - started >= 2.2, 5)
        window.stop_recording()
        require(window.recorder.stopping, "Stop waits for MP4 finalization")
        spin(lambda: not window.recorder.active and not window.busy, 50)
        require(window.current and window.current["Kind"] == "video" and window.stack.get_visible_child_name() == "video", "Finalized MP4 is indexed and opens in the Linux video preview")
        path = window.store.current_file(window.current)
        duration, width, height = validate_mp4(path)
        require(duration >= 1 and width == desktop_width and height == desktop_height, "Finalized screen recording has the expected size and duration")
        decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-threads", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"], capture_output=True, timeout=20, check=True)
        loader = GdkPixbuf.PixbufLoader.new_with_type("png")
        loader.write(decoded.stdout)
        loader.close()
        require(synthetic_blue(loader.get_pixbuf()), "FFmpeg decodes a real MP4 frame containing the synthetic screen pixels")
        require(window.playbin is not None and window.record_bar is None and window.start_button.get_sensitive(), "Video preview and recorder controls recover after finalization")
        cover.destroy()
        cover = None
        drain()
        snapshot(window, images / "video-saved.png")
        window.open_recording()
        snapshot(window, images / "recorder-en-light.png")
        from .shortcuts import Shortcuts
        first = Shortcuts(lambda number: None)
        second = Shortcuts(lambda number: None)
        require(len(first.registered) == 4 and len(second.conflicts) == 4, "X11 global shortcuts register and report existing key conflicts")
        second.close()
        first.close()
        third = Shortcuts(lambda number: None)
        require(len(third.registered) == 4, "Closing shortcuts releases only the application's X11 key grabs")
        third.close()
        require(hashlib.sha256(original_path.read_bytes()).hexdigest() == digest, "All Linux verification workflows preserve the original image bytes")
    except Exception:
        failure = traceback.format_exc()
    finally:
        if cover:
            cover.destroy()
        if window:
            if window.recorder.active:
                window.recorder.stop()
                try:
                    spin(lambda: not window.recorder.active, 48)
                except Exception:
                    pass
            window.quit()
        if wm:
            wm.terminate()
            try:
                wm.wait(timeout=3)
            except subprocess.TimeoutExpired:
                wm.kill()
    report = dict(success=failure is None, version="0.4.0", platform="Linux x64 / X11", count=len(checks), checks=checks,
                  failure=failure, checkedAt=datetime.now(timezone.utc).isoformat(), runDirectory=str(directory), screenshots=str(images))
    text = json.dumps(report, ensure_ascii=False, indent=2)
    (directory / "report.json").write_text(text, encoding="utf8")
    (root / "latest-report.json").write_text(text, encoding="utf8")
    print(text)
    return failure is None
