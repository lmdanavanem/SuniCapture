<p align="center"><img src="assets/Brand/sunicapture-logo.png" width="190" alt="SuniCapture"></p>

# SuniCapture

**Capture, annotate and record your screen locally.**

Windows x64 app with a local library, image editor and MP4 recording. Available in French and English, with light and dark themes. No account, application telemetry or capture uploads.

[Download the latest version](https://github.com/lmdanavanem/SuniCapture/releases/latest) · [All releases](https://github.com/lmdanavanem/SuniCapture/releases) · [Français](README.fr.md) · [Report an issue](https://github.com/lmdanavanem/SuniCapture/issues)

![SuniCapture home](docs/images/home.png)

## Download and run

1. Download **SuniCapture-0.3.0-win-x64.zip** from [release 0.3.0](https://github.com/lmdanavanem/SuniCapture/releases/tag/v0.3.0).
2. Extract the **complete folder** to a location of your choice.
3. Open **SuniCapture.exe** inside the extracted folder.

The distribution includes .NET. No .NET installation or administrator rights are required. Keep all accompanying files next to the executable. Compare the following result with **SHA256SUMS.txt** attached to the release:

```powershell
Get-FileHash .\SuniCapture-0.3.0-win-x64.zip -Algorithm SHA256
```

## Start from a source checkout

Open **Lancer SuniCapture.cmd** or **dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe**. The portable distribution includes .NET. Copy the complete application folder to another PC, or extract `SuniCapture-0.3.0-win-x64.zip`.

## Language, appearance and About

Use the **FR/EN globe** in the header to select **English** or **Français**. The interface changes immediately, and the choice is remembered after restart. Capture names and text you enter in annotations are preserved.

The **?** button opens **About SuniCapture**: logo, executable version, privacy information, library location, preferences and component licenses. The app works offline, without an account or application telemetry. This portable version does not check for updates online.

The **gear** opens preferences for language, light/dark theme and existing capture options. **Save preferences** applies changes without restarting; **Cancel** discards them. Press **F1**, or choose **Help and shortcuts** in About, to open the built-in guide. Escape closes dialogs.

## Capture and annotate

![SuniCapture editor](docs/images/editor.png)

Screenshots in this documentation show the French interface.

- Capture a region, all displays or a selected window. Optional delay: 0, 3, 5 or 10 seconds.
- Import PNG, JPEG, BMP, TIFF or GIF (first frame), drag files in, or paste an image.
- Use arrows, rectangles, ellipses, pen strokes, highlights, text, numbered steps and opaque redaction.
- Crop, zoom, fit, undo and redo. Annotations are saved automatically after 800 ms.
- Export flattened pixels to PNG, JPEG, BMP or a single-page PDF, or copy the annotated image.
- Search your local library, rename items, mark favorites and restore captures from Trash.

## Record screen video

1. Open **Record screen** and optionally enable **Include computer audio**.
2. Click **Start recording**. After the countdown, SuniCapture records the primary display.
3. Stop with the floating **Stop** button, **Stop and save**, or **Ctrl+Shift+4**.
4. Wait for MP4 finalization. The video appears in the library and its preview opens. **Export MP4…** saves a copy elsewhere.

Recording uses H.264 MP4 at 30 fps, includes the cursor and optionally includes system playback audio. The microphone is disabled. `--record` opens the recording workspace without starting a recording.

## Shortcuts

| Action | Shortcut |
|---|---|
| Capture a region | Ctrl+Shift+1 |
| Capture all displays | Ctrl+Shift+2 |
| Choose a window | Ctrl+Shift+3 |
| Start / stop recording | Ctrl+Shift+4 |
| Import / paste | Ctrl+O / Ctrl+V |
| Save / export | Ctrl+S / Ctrl+E |
| Copy annotated image | Ctrl+C |
| Undo / redo | Ctrl+Z / Ctrl+Y |
| Help | F1 |
| Tools | V pointer, A arrow, R rectangle, O ellipse, P pen, H highlight, T text, N step, B redact, C crop |

Tool shortcuts apply outside text fields. Conflicting global shortcuts are reported; the buttons remain available.

## Storage and updates

Files stay in `%LOCALAPPDATA%\SuniCapture`: `originals`, `edited`, `videos`, `library.json` and `settings.json`. The previous index is backed up with `.bak`. Trash is restorable and is never automatically emptied. Replacing the portable application folder keeps the library, which is stored separately.

Closing the main window minimizes it to the notification area by default. Use **Quit** in the tray menu to exit, or disable this preference.

## Limits

Scrolling capture, OCR, multipage documents, webcam, video trimming and cloud destinations are not included. Window capture brings the window to the front and captures visible pixels; it cannot reconstruct hidden or protected content. HDR may affect colors. Mixed-DPI monitor configurations still require hardware-specific qualification.

Saved annotations are flattened; individual objects cannot be reselected after reopening. Undo is available during the editing session. **Restore original** reloads the initial image. Opaque redaction removes covered pixels from exports; originals remain in the local library. The app does not encrypt files or preferences; Windows account permissions apply.

Windows N/KN may require Media Foundation. The video engine may require the Microsoft Visual C++ x64 runtime on another PC. These components are never installed automatically. Screenshots work independently of the video engine. System audio should be checked with your playback device.

## Build and verify

Requires Windows x64 and .NET SDK 10. NuGet access is needed to restore ScreenRecorderLib 7.0.1.

```powershell
dotnet build src/SuniCapture/SuniCapture.csproj -c Release
./scripts/build.ps1
python scripts/check-localization.py
# Also run UI workflows and the real recording test
./scripts/build.ps1 -RunUiChecks
```

The build creates a self-contained portable distribution, runs core checks in an isolated library, copies notices and documentation, then creates the ZIP and SHA-256 manifests.

```powershell
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --self-test --data-dir ./artifacts/qa-data/manual
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --ui-self-test --data-dir ./artifacts/qa-data/manual-ui
```

UI checks use synthetic content and briefly cover the primary display for the recording test. They do not record the personal desktop, use microphone audio, modify the clipboard or write into the personal library.

Local validation of version 0.3.0 passed **130 checks**, with **307 FR/EN resources verified**. Continuous integration runs translation, compilation, export and storage checks; video workflows are tested locally on an interactive Windows desktop.

See the [development guide](docs/development.md), [verification report](docs/verification-0.3.0.md), [video engine](docs/video-engine.md) and [changelog](CHANGELOG.md).

## Components

SuniCapture is developed by Suniworks. ScreenRecorderLib is distributed under the MIT license. .NET notices and component licenses accompany the portable distribution. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
