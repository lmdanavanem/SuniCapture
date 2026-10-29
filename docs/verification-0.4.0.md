# SuniCapture 0.4.0 verification

Local checks completed on 29 October 2026 using synthetic images and isolated test libraries. The [machine-readable report](verification-0.4.0.json) contains the individual checks without machine paths.

| Area | Result | Environment |
|---|---|---|
| Windows core, storage and exports | 36 passed | Packaged Windows x64 application |
| Windows interface and recording | 94 passed | Interactive Windows desktop; synthetic display cover, microphone and playback audio disabled |
| Linux core, interface, screenshot and recording | 65 passed | Ubuntu 22.04 x86_64, GTK 3, Xvfb, Openbox and a private session bus |
| Linux portal contracts | 10 passed | Private D-Bus service; no real desktop permissions changed |
| Linux Debian package and archive | Passed | Installed `.deb` and archive in a folder containing spaces; unprivileged user, unrelated working directory |
| French and English resources | Passed | 307 Windows resources, 353 merged Linux resources; references and format arguments checked |

Linux checks cover all annotation tools, crop, undo/redo, PNG/JPEG/BMP/PDF exports, original preservation, damaged-index recovery, language switching with pending drawings, Cancel/Save preferences, light/dark and compact layouts, About/help/preferences, native X11 screenshots, window selection and region cropping. The screen and a decoded H.264 video frame are checked against known synthetic color pixels. The MP4 is finalized, indexed and opened in the integrated preview. Global shortcut conflicts and release are checked.

The portal checks cover fast responses, region targets, older screenshot fallback, cancellation, refusal of nonlocal image URIs, the ScreenCast request sequence, real descriptor passing and session cleanup. They exercise the API contract; they do not establish compatibility with a physical Wayland compositor.

Windows checks retain existing capture/edit/library workflows and validate a real finalized MP4 with the Windows decoder. Finalization now waits briefly if the native writer still holds its file handle after reporting completion.

The [Linux workflow](../.github/workflows/linux-build.yml) installs and tests both Linux distributions on Ubuntu 22.04 and 24.04. The [Windows workflow](../.github/workflows/windows-build.yml) runs resource, build and core checks. [Current runs](https://github.com/lmdanavanem/SuniCapture/actions) show the exact revision and results.

## Qualification limits

- X11/Xorg is the validated Linux capture session. Wayland is experimental and needs the portal backend matching the desktop.
- Physical GNOME/KDE sessions, mixed-DPI hardware, HDR, protected content and system-audio device routing are not covered by virtual-desktop checks.
- Linux builds target x86_64, Python 3.10+ and Debian/Ubuntu system packages. ARM and other distribution installations are not qualified.
- Capture libraries remain separate from application files. No tests use the personal library, personal desktop pixels or microphone input.

Package hashes are generated after packaging and supplied in the public release's `SHA256SUMS.txt`.
