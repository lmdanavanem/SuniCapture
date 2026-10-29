# Changelog

## 0.4.1 — 2026-10-29

### Fixed

- Linux uses a single compact title bar with correctly sized minimize, maximize, restore and close controls.
- Language menus, selection colors and native file dialogs remain readable when changing between light and dark appearance.
- Application button styling no longer changes the size of native window controls.
- Initial windows fit smaller desktop work areas, including a 200% display scale.
- The Linux package explicitly includes the system SVG-loader dependency used by GTK icons.

### Improved

- Consistent vector icons, left-aligned navigation and a more compact capture/editor toolbar.
- Complete-window screenshots and automated checks for caption actions, popup contrast, dialogs and file choosers, in French and English using Ubuntu's Yaru theme.
- Capture, annotation, recording and local-library workflows are retained.

## 0.4.0 — 2026-10-29

### Added

- Native Linux x64 application with a Debian/Ubuntu installer and an archive distribution.
- Region, desktop and window screenshots on X11; annotation tools, image/PDF export, favorites and restorable Trash.
- Linux H.264 MP4 recording, optional system playback audio, floating stop control and local video preview.
- French/English interface, light/dark themes, About, help and preferences on Linux.
- Experimental Wayland capture through desktop permission dialogs and PipeWire. Desktop shortcuts must be configured by the user on Wayland.

### Improved

- English is the primary repository description and README; complete French documentation remains available.
- Linux uses a separate local library; installing or updating the application preserves existing captures.
- Linux packaging and automated desktop checks complement the Windows build.

### Fixed

- Windows video saving waits for the native writer to release the completed MP4 before promoting it into the library.

## 0.3.0 — 2026-10-29

### Added

- French and English interface with an immediate, persistent language switch.
- About dialog with product identity, version, privacy information, storage location and component licenses.
- Language and light/dark appearance controls in preferences, alongside existing capture options.
- Built-in help and shortcuts, available with F1 and from About.
- French and English documentation and a portable Windows x64 distribution.

### Preserved

- Region, full-desktop and selected-window screenshots; image import and clipboard workflows.
- Annotation tools, automatic saving, crop, undo/redo and image/PDF export.
- Local library, favorites and restorable Trash.
- Primary-display H.264 MP4 recording with optional system playback audio.
- Open captures, pending annotations, active tools and user-entered text when changing language.

### Verification

- 36 core checks and 94 UI/recording checks passed locally.
- 307 French/English resources checked for coverage and matching format arguments.
- Finalized MP4 decoded by Windows; original image bytes preserved by editing and language changes.

## 0.2.0 — 2026-10-29

- Dedicated recording workspace with duration, audio selection, start/stop state and floating stop control.
- MP4 finalization, library indexing, preview and export.
- Global Ctrl+Shift+4 recording shortcut and `--record` workspace option.

## 0.1.0 — 2026-10-28

- Initial local screenshot, library and annotation workflows.
- Image import, clipboard support, flattened image/PDF export, favorites and restorable Trash.
- Light/dark themes and notification-area access.
