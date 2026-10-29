# SuniCapture 0.4.1 verification

This patch adds visual validation of the complete Linux window. Earlier functional checks did not sufficiently cover title-bar decorations or popup colors.

The reference environment is Ubuntu x86_64 with GTK 3 and the Yaru theme, running on an isolated X11 desktop. This checks GTK client-side window controls; it is not a physical GNOME/Wayland session qualification.

| Check | Scope |
|---|---|
| Functional suite | 65 checks: captures, annotations, exports, local storage, language changes and a real finalized/decoded MP4 |
| Visual suite | 64 checks per desktop profile, in French/English and light/dark modes |
| Desktop profiles | 1600 × 1000 at 100%; 1366 × 768 at 100%; 1920 × 1440 at 200% |
| Native controls | Minimize, maximize, restore and close actions; compact caption-button bounds |
| Menus | Opaque matching surface, compact rows and text contrast of at least 4.5:1 |
| Dialogs | About, help, preferences, import and export file choosers; title bars and footers included |
| Data preservation | Original image bytes and user-entered capture names unchanged |
| Distribution | Installed Debian package and extracted archive; source/package version alignment |

Screenshots use complete native window geometry, including the title bar. The visual suite reads X11 pixel dimensions for evidence, avoiding differences in GTK popup coordinates at a 200% scale. Screenshots use synthetic data and dedicated local libraries.

Run on a dedicated virtual desktop:

```sh
SUNICAPTURE_TEST_THEME=Yaru dbus-run-session -- \
  xvfb-run -a -s '-screen 0 1366x768x24' \
  sunicapture --visual-self-test --data-dir artifacts/linux-visual/laptop
```

The [Linux workflow](../.github/workflows/linux-build.yml) performs installed-package and archive checks on Ubuntu 22.04 and 24.04, then runs all three visual profiles. [Current build results](https://github.com/lmdanavanem/SuniCapture/actions) identify the exact revision. The [machine-readable local report](verification-0.4.1.json) records completed checks.

System playback-audio routing, protected content, HDR, mixed-DPI hardware and physical Wayland compositor capture remain outside this virtual-desktop qualification. Windows application behavior is unchanged by this Linux interface patch; the Windows build and core checks still run.
