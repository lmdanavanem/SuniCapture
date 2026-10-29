# SuniCapture on Linux

SuniCapture 0.4.1 has a native GTK desktop application for Linux x86_64. The Linux distribution uses Python and multimedia components supplied by the operating system; it does not contain or run the Windows executable.

## Install on Debian or Ubuntu

The package targets Ubuntu 22.04 or newer and Debian 12 or newer, on x86_64. Download `SuniCapture-0.4.1-linux-amd64.deb` and `SHA256SUMS.txt` from the [release](https://github.com/lmdanavanem/SuniCapture/releases/tag/v0.4.1).

```sh
sha256sum SuniCapture-0.4.1-linux-amd64.deb
# Compare with the matching line in SHA256SUMS.txt.
sudo apt install ./SuniCapture-0.4.1-linux-amd64.deb
sunicapture
```

The package manager resolves GTK, Python, FFmpeg and GStreamer dependencies. It may need network access during installation. The application itself works offline. Start it from the desktop application menu or with `sunicapture`. Installing a later package upgrades application files and keeps your library.

## Archive distribution

The archive is useful when you prefer an application folder. System dependencies are still required. On Debian/Ubuntu:

```sh
sudo apt install python3 python3-gi python3-gi-cairo python3-cairo python3-gst-1.0 \
  gir1.2-gtk-3.0 gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad \
  gstreamer1.0-libav gstreamer1.0-gtk3 gstreamer1.0-pipewire ffmpeg \
  pulseaudio-utils libx11-6 fonts-dejavu-core librsvg2-common
tar -xf SuniCapture-0.4.1-linux-x64.tar.xz
./SuniCapture-0.4.1-linux-x64/sunicapture
```

The archive launcher can run from a folder containing spaces. Keep the complete folder together. Other distributions need equivalent system packages and Python 3.10 or later; their installation has not been qualified.

## Desktop sessions

| Session | Capture and recording | Shortcuts |
|---|---|---|
| X11 / Xorg | Region, full desktop, visible window; primary-display MP4 recording | Ctrl+Shift+1–4 registered while the application runs; conflicts reported |
| Wayland, experimental | System screenshot selector; ScreenCast permission dialog and PipeWire recording | Assign application commands in your desktop's keyboard settings |

The X11 workflows are tested on an isolated Linux desktop with real screenshot and video encoders. Wayland depends on the compositor and its portal backend; it has not been qualified end to end on a physical GNOME/KDE desktop. Use an Xorg session for the validated capture workflows.

Wayland needs `xdg-desktop-portal`, the backend matching your desktop and PipeWire. Ubuntu GNOME normally uses its GNOME backend; KDE uses its KDE backend. SuniCapture requests access through the system dialog each time. Cancelling returns to the application. On older screenshot portals, the system selector determines the target even if you started from the region/window button.

These commands can be assigned to desktop shortcuts:

```sh
sunicapture --capture-region
sunicapture --capture-screen
sunicapture --capture-window
sunicapture --record
```

`--record` opens the recording workspace; starting a recording requires the Start button. On X11, Ctrl+Shift+4 starts/stops recording. A notification-area icon is available only on desktops that support GTK status icons. Closing the window exits when no supported tray is present.

## Window controls and appearance

Version 0.4.1 uses a single compact GTK title bar with native minimize, maximize, restore and close actions. Menu colors follow the application appearance. Toolbar icons use vector drawing, and dialogs keep a visible footer. Interface layout checks include 100% and 200% display scaling; this does not qualify mixed-DPI capture hardware.

## Audio and files

Computer audio uses the monitor source of the current default playback sink through PulseAudio or its PipeWire compatibility service. If no playback monitor is available, the application reports it; it never substitutes microphone input. Audio routing still needs verification with your own playback device.

Captures stay in `$XDG_DATA_HOME/SuniCapture`, or `~/.local/share/SuniCapture` by default. Originals, edited images, videos, the JSON index and preferences are stored separately from the installation. Trash is restorable. An interrupted recording is kept as a `.partial.mp4` if recovery is needed; only finalized, validated MP4 files enter the library.

Exports support PNG, JPEG, BMP and single-page PDF. Opaque redaction removes covered pixels from exported images; the original remains in the local library. Saved annotations are flattened. Mixed-DPI displays, HDR and protected content require desktop-specific testing. Linux ARM, AppImage and macOS packages are not provided by this release.

## Build and verify

The builder needs `dpkg-dev` and `desktop-file-utils` in addition to runtime packages. Desktop verification also needs `xvfb`, `xauth`, `openbox` and `dbus-x11`; visual checks with the Ubuntu theme need `yaru-theme-gtk`.

```sh
python3 scripts/check-localization.py
python3 scripts/build-linux.py
dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24' \
  python3 src/SuniCapture.Linux/launch.py --self-test --data-dir artifacts/linux-checks
```

Use a dedicated virtual desktop for self-tests: they create a synthetic full-screen fixture, take screenshots and record that fixture. Reports and diagnostic captures are saved only below the supplied test directory. The personal capture library is not used. See [verification](verification-0.4.1.md).
