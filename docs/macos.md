# SuniCapture on macOS

SuniCapture has a native macOS application written in Swift with SwiftUI and AppKit. It runs on macOS 15 Sequoia or later, on Apple silicon and Intel Macs (universal binary). Screenshots and recordings use Apple's ScreenCaptureKit; the application contains no third-party code.

## Install

Download `SuniCapture-<version>-macos-universal.dmg` and `SHA256SUMS-macos.txt` from the [releases](https://github.com/lmdanavanem/SuniCapture/releases), then check the download:

```sh
shasum -a 256 -c SHA256SUMS-macos.txt
```

Open the disk image and drag **SuniCapture** to **Applications**. Installing a later version replaces the application and keeps your library.

The public build is not notarized yet. The first time you open it, macOS may say it cannot verify the developer: click **Done**, open **System Settings › Privacy & Security**, and choose **Open Anyway** at the bottom of the page. This is needed once per version.

## Screen recording permission

macOS asks for the **Screen & System Audio Recording** permission the first time you capture or record. Turn on SuniCapture in **System Settings › Privacy & Security › Screen & System Audio Recording**. If the permission is missing, SuniCapture explains it and offers to open the right settings page. Imports, the editor and the library work without this permission.

The microphone is never used, so macOS does not ask for microphone access. Computer audio comes from ScreenCaptureKit and only when **Include computer audio** is enabled; SuniCapture's own sounds are excluded.

## Capture, annotate and record

The macOS version has the same workflows as Windows and Linux:

- Region capture on a frozen image of every display, full desktop (all displays in one image) and window capture. Delay: 0, 3, 5 or 10 seconds.
- Window capture uses the window's own pixels, so a partly covered window is captured as it is displayed.
- Import PNG, JPEG, BMP, TIFF or GIF (first frame) with the Import button, drag and drop, the Finder (**Open With › SuniCapture**) or `⌘V`.
- Arrows, rectangles, ellipses, pen, highlight, text, numbered steps, opaque redaction and crop; undo and redo; automatic saving after 800 ms; zoom with the buttons, `⌘+`/`⌘-`/`⌘0` or a trackpad pinch.
- Export to PNG, JPEG, BMP or single-page PDF; copy the annotated image.
- Library search, favorites, rename, restorable Trash and **Restore original**.
- H.264 MP4 recording of the primary display at its native resolution, up to 30 fps (ScreenCaptureKit writes fewer frames while the screen does not change), with the cursor, optional computer audio, a countdown and a floating **Stop** button. The floating button is excluded from the video. The MP4 is written as a `.partial.mp4` file, validated, then added to the library.
- French/English interface, light and dark themes, About, preferences and built-in help (`F1` or `⌘?`).

At 100 % zoom the editor shows one image pixel per screen pixel, so a Retina capture appears at its original size.

## Shortcuts

macOS reserves `⌘⇧3`, `⌘⇧4` and `⌘⇧5` for its own screenshots, so SuniCapture keeps the Windows global shortcuts on the Control key. They work from any application and need no Accessibility permission.

| Action | Shortcut |
|---|---|
| Capture a region | `⌃⇧1` |
| Capture all displays | `⌃⇧2` |
| Choose a window | `⌃⇧3` |
| Start / stop recording | `⌃⇧4` |
| Import / paste | `⌘O` / `⌘V` |
| Save / export | `⌘S` / `⌘E` |
| Copy annotated image | `⌘C` |
| Undo / redo | `⌘Z` / `⇧⌘Z` (or `⌘Y`) |
| New region capture | `⌘N` |
| Help / preferences | `F1` or `⌘?` / `⌘,` |
| Tools | V pointer, A arrow, R rectangle, O ellipse, P pen, H highlight, T text, N step, B redact, C crop |

If another application already owns one of the global shortcuts, SuniCapture reports it in the status bar; the buttons and menus remain available. Text fields keep their own editing shortcuts.

## Menu bar, windows and files

SuniCapture adds an icon to the menu bar with Open, Capture a region, Capture full screen, Record screen, Preferences, About and Quit. Closing the main window keeps SuniCapture in the menu bar when **Keep SuniCapture in the menu bar when the window is closed** is enabled (default); otherwise closing the window quits. Quit with `⌘Q` or from the menu bar icon. Quitting during a recording first finalizes the MP4.

Captures stay in `~/Library/Application Support/SuniCapture`: `originals`, `edited`, `videos`, `library.json` and `settings.json`, in the same format as the Windows and Linux versions. A library copied from another system opens unchanged. The previous index is kept as `.bak`; an unreadable index is preserved before recovery.

Command-line options, for scripts and Shortcuts: `--capture-region`, `--capture-screen`, `--capture-window`, `--record` (opens the recording workspace), an image path to import, and `--data-dir <folder>` for a separate library. When SuniCapture is not already running, launch them with `open -a SuniCapture --args <option>`; a running instance keeps its library and is simply brought to the front.

## Limits

Scrolling capture, OCR, multipage documents, webcam, microphone, video trimming and cloud destinations are not included, as on Windows and Linux. Protected content (for example DRM video) appears black. Only the primary display is recorded. Mixed-density display configurations compose all displays at the highest pixel density.

## Build and verify

Building requires macOS 15 or later with Xcode 26 (Swift 6.2) or later, and Python 3 for the translation check.

```sh
python3 scripts/check-localization.py
./scripts/build-macos.sh
```

The script builds a universal `dist/SuniCapture.app`, signs it (ad hoc by default; set `SUNICAPTURE_SIGN_IDENTITY` to use a certificate), runs the core checks in an isolated library, then creates `dist/SuniCapture-<version>-macos-universal.dmg` and `dist/SHA256SUMS-macos.txt`. `--install` copies the application to `/Applications`.

```sh
./scripts/build-macos.sh --ui-checks
```

`--ui-checks` adds interface, screen capture and real recording checks. They need an interactive desktop and the screen recording permission for the built application, and they cover the primary display with a synthetic image for a few seconds. Ad hoc signatures change with every build, so macOS asks for the permission again; a stable signing identity keeps it.

For development, `swift run --package-path src/SuniCapture.macOS SuniCapture --qa` starts the application on an isolated library with a synthetic image. The macOS sources are in `src/SuniCapture.macOS`; they reuse the shared translations in `src/SuniCapture/Localization/strings.json` and add the macOS texts in `Resources/strings.macos.json`.
