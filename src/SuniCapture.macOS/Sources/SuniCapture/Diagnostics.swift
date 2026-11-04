import AppKit
import AVFoundation
import CryptoKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Local checks with synthetic pixels and isolated libraries; never reads the personal library.
enum Diagnostics {
    private struct Failure: Error { let label: String }

    private final class Checks {
        var passed: [String] = []
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(label: label) }
            passed.append(label)
        }
    }

    // MARK: Core (--self-test)

    static func runCore(_ outputRoot: URL) -> Bool {
        let run = runDirectory(outputRoot)
        let checks = Checks()
        var failure: String?
        do {
            try editorChecks(checks, run.appendingPathComponent("exports"))
            try storeChecks(checks, run)
        } catch { failure = describe(error) }
        return writeReport(checks.passed, failure, run, outputRoot)
    }

    private static func editorChecks(_ checks: Checks, _ output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = ImageFiles.context(width: 180, height: 120)!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<120 {
            for x in 0..<180 {
                let index = y * context.bytesPerRow + x * 4
                data[index] = 220; data[index + 1] = UInt8(y % 255); data[index + 2] = UInt8(x % 255); data[index + 3] = 255
            }
        }
        let source = context.makeImage()!
        let pixels = try bytes(source)
        let editor = AnnotationCanvas()
        editor.image = source
        try checks.require(editor.frame.width == 180 && editor.frame.height == 120, "image dimensions use pixels independently of source DPI")
        try checks.require(!editor.isDirty && !editor.canUndo && !editor.canRedo, "opening image starts a clean history")
        editor.addShape(.arrow, CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 30))
        let arrow = try bytes(editor.render())
        try checks.require(arrow != pixels, "arrow modifies exported pixels")
        editor.undo()
        try checks.require(!editor.isDirty && editor.canRedo && (try bytes(editor.render())) == pixels, "undo restores original pixels and clean state")
        editor.redo()
        try checks.require(editor.isDirty && editor.annotationCount == 1 && (try bytes(editor.render())) == arrow, "redo restores the rendered annotation")
        editor.undo()
        editor.addShape(.pixelate, CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60))
        let masked = try bytes(editor.render())
        let sample = 35 * 180 * 4 + 40 * 4
        try checks.require(Array(masked[sample..<sample + 4]) == [0x0F, 0x17, 0x2A, 255], "mask export replaces source with fully opaque pixels")
        editor.crop(CGRect(x: 10, y: 10, width: 100, height: 80))
        try checks.require(editor.image?.width == 100 && editor.image?.height == 80 && editor.annotationCount == 0, "crop flattens and keeps expected pixel dimensions")
        let cropped = try bytes(editor.render())
        editor.undo()
        try checks.require(editor.image?.width == 180 && (try bytes(editor.render())) == masked, "undo crop restores all previous pixels and annotation layers")
        editor.redo()
        try checks.require((try bytes(editor.render())) == cropped, "redo crop restores exact cropped pixels")
        editor.markClean()
        try checks.require(!editor.isDirty && editor.canUndo, "saving marks clean while retaining undo")
        editor.textValue = "Étape 1"
        editor.addShape(.step, CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 30))
        editor.addShape(.step, CGPoint(x: 70, y: 30), CGPoint(x: 70, y: 30))
        try checks.require(editor.state?.nextStep == 3 && editor.state?.annotations.map(\.number) == [1, 2], "numbered steps increase in order")
        editor.undo(); editor.undo()
        for name in ["png", "jpg", "bmp", "pdf"] {
            let url = output.appendingPathComponent("editor-export." + name)
            try ImageFiles.save(editor.render(), to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            try checks.require(size > 50, ".\(name) export produces a file")
            if name == "pdf" { continue }
            let decoded = try ImageFiles.load(url)
            try checks.require(decoded.width == 100 && decoded.height == 80, ".\(name) export decodes with cropped dimensions")
        }
        let pdf = CGPDFDocument(output.appendingPathComponent("editor-export.pdf") as CFURL)
        let box = pdf?.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero
        try checks.require(pdf?.numberOfPages == 1 && abs(box.width - 75) < 0.01 && abs(box.height - 60) < 0.01, "PDF contains one page sized to the cropped image")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasPrefix(".sunicapture-") }
        try checks.require(leftovers.isEmpty, "exports leave no partial temporary files")
        // ImageIO writes a generated Exif (color space, pixel size); nothing about the source device or place.
        let jpeg = CGImageSourceCreateWithURL(output.appendingPathComponent("editor-export.jpg") as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let exif = Set((jpeg[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]).keys)
        try checks.require(jpeg[kCGImagePropertyGPSDictionary] == nil && jpeg[kCGImagePropertyTIFFDictionary] == nil
            && exif.isSubset(of: [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]),
            "exports carry flattened pixels without source metadata")
    }

    private static func storeChecks(_ checks: Checks, _ run: URL) throws {
        let libraryPath = run.appendingPathComponent("library")
        let store = try LibraryStore(root: libraryPath)
        let item = try store.addImage(fixture(), source: "Test synthétique", name: "Capture été à Genève")
        let originalPath = try store.resolve(item.originalFile)
        let originalHash = SHA256.hash(data: try Data(contentsOf: originalPath))
        let editor = AnnotationCanvas()
        editor.image = try ImageFiles.load(originalPath)
        editor.inkColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        editor.addShape(.arrow, CGPoint(x: 120, y: 200), CGPoint(x: 450, y: 330))
        try store.saveEdited(item.id, editor.render())
        try checks.require(SHA256.hash(data: try Data(contentsOf: originalPath)) == originalHash, "Editing preserves original file bytes")
        let edited = store.item(item.id)!
        try checks.require(edited.editedFile != nil && FileManager.default.fileExists(atPath: try store.currentFile(edited).path), "Edited image stored separately from original")
        try store.update(item.id) { $0.favorite = true; $0.name = "Étude : révision façade" }
        let reopened = try LibraryStore(root: libraryPath)
        try checks.require(reopened.items.count == 1 && reopened.items[0].favorite && reopened.items[0].name == "Étude : révision façade", "Library persists unicode names and favorites")
        try store.update(item.id) { $0.isTrashed = true; $0.trashedAt = Date() }
        try checks.require(try LibraryStore(root: libraryPath).items[0].isTrashed && FileManager.default.fileExists(atPath: originalPath.path), "Trash preserves original and metadata")
        try store.update(item.id) { $0.isTrashed = false; $0.trashedAt = nil }
        try checks.require(!(try LibraryStore(root: libraryPath).items[0].isTrashed), "Trashed captures can be restored")

        let pendingVideo = store.videoDirectory.appendingPathComponent("pending-test.mp4")
        try Data(count: 128).write(to: pendingVideo)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: libraryPath.path)
        var indexFailed = false
        do { _ = try store.addVideo(pendingVideo, duration: 2, width: 10, height: 10) } catch { indexFailed = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: libraryPath.path)
        try checks.require(indexFailed && FileManager.default.fileExists(atPath: pendingVideo.path) && store.items.count == 1, "Failed video indexing rolls file back without losing original path")

        store.settings.darkMode = true
        store.settings.captureDelay = 5
        try store.saveSettings()
        let preferences = try LibraryStore(root: libraryPath).settings
        try checks.require(preferences.darkMode && preferences.captureDelay == 5, "Theme and delay persist across restart")
        try checks.require((try? store.resolve("..\\outside.png")) == nil && (try? store.resolve("../outside.png")) == nil
            && (try? store.resolve("/etc/passwd")) == nil, "Library rejects traversal paths")

        try Data("{ broken index".utf8).write(to: libraryPath.appendingPathComponent("library.json"))
        let recovered = try LibraryStore(root: libraryPath)
        try checks.require(recovered.loadWarning != nil && recovered.items.count == 1, "Corrupt index recovers from last valid backup")
        let unreadable = try FileManager.default.contentsOfDirectory(atPath: libraryPath.path).filter { $0.hasPrefix("library.json.unreadable-") }
        try checks.require(unreadable.count == 1, "Corrupt index preserved for recovery")
        try checks.require(FileManager.default.fileExists(atPath: originalPath.path), "Recovery leaves original captures untouched")

        // The temporary directory lives under /var, a symbolic link to /private/var.
        let linked = FileManager.default.temporaryDirectory.appendingPathComponent("SuniCapture-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linked) }
        let linkedStore = try LibraryStore(root: linked)
        let linkedItem = try linkedStore.addImage(fixture(), source: "Test synthétique")
        try checks.require(FileManager.default.fileExists(atPath: try linkedStore.currentFile(linkedItem).path), "Library opens captures through a symbolic-link path")

        let windowsPath = run.appendingPathComponent("windows-library")
        try FileManager.default.createDirectory(at: windowsPath, withIntermediateDirectories: true)
        let windowsIndex = """
        [{"Id":"0123456789abcdef0123456789abcdef","Name":"Capture Windows","CreatedAt":"2026-10-29T10:20:30.1234567+01:00","Kind":"image",\
        "OriginalFile":"originals\\\\0123456789abcdef0123456789abcdef.png","EditedFile":null,"Width":10,"Height":10,"DurationSeconds":0,\
        "Source":"Zone de l’écran","Favorite":true,"IsTrashed":false,"TrashedAt":null}]
        """
        try Data(windowsIndex.utf8).write(to: windowsPath.appendingPathComponent("library.json"))
        let windowsStore = try LibraryStore(root: windowsPath)
        try checks.require(windowsStore.items.count == 1 && windowsStore.items[0].favorite
            && windowsStore.items[0].createdAt == JSONDates.parse("2026-10-29T09:20:30.123Z")
            && (try windowsStore.currentFile(windowsStore.items[0])).lastPathComponent.hasSuffix(".png"), "Windows and Linux library indexes load unchanged")

        let largePath = run.appendingPathComponent("large-library")
        try FileManager.default.createDirectory(at: largePath, withIntermediateDirectories: true)
        let many = (0...20000).map { index -> CaptureItem in
            var value = CaptureItem()
            value.name = "Index \(index)"
            value.originalFile = "originals/fixture.png"
            return value
        }
        try JSONDates.encoder.encode(many).write(to: largePath.appendingPathComponent("library.json"))
        let large = try LibraryStore(root: largePath)
        try checks.require(large.items.count == 20001, "Library reload retains every item above 20000 entries")
        try large.save()
        try checks.require(try LibraryStore(root: largePath).items.count == 20001, "Saving large library preserves all capture references")
        try checks.require(L.format("{0:0}", [12.6]) == "13" && L.format("{{{0}}}", ["x"]) == "{x}", ".NET composite formats render on macOS")
        try checks.require(L.normalize("unsupported") == "fr" && L.normalize(nil) == "fr", "Invalid or missing locale keeps French compatibility with older settings")
    }

    // MARK: Interface (--ui-self-test)

    static func runInterface(_ model: AppModel, _ outputRoot: URL) async -> Bool {
        let run = runDirectory(outputRoot)
        screenshots = run.appendingPathComponent("screenshots")
        let checks = Checks()
        var failure: String?
        do {
            try await interfaceChecks(model, checks)
            try await captureChecks(checks)
            try await recordingChecks(model, checks, audio: false)
            try await recordingChecks(model, checks, audio: true)
        } catch { failure = describe(error) }
        return writeReport(checks.passed, failure, run, outputRoot)
    }

    private static func interfaceChecks(_ model: AppModel, _ checks: Checks) async throws {
        try checks.require(model.screen == .home, "Home renders with capture entry points")
        await screenshot(model, "home-fr-light")
        model.seedQAImage()
        try checks.require(model.current != nil && model.editor.canvas.image?.width == 1120 && model.screen == .editor, "New image opens in editor and library")
        model.editor.tool = .rectangle
        model.editor.canvas.addShape(.rectangle, CGPoint(x: 260, y: 210), CGPoint(x: 1080, y: 340))
        try checks.require(model.editor.canUndo && model.editor.isDirty, "Drawing enables undo and marks pending save")
        await screenshot(model, "editor-fr-light")
        try await Task.sleep(for: .seconds(1.2))
        try checks.require(!model.editor.isDirty && model.current?.editedFile != nil, "Editor autosave persists flattened annotations")
        model.toggleFavorite()
        try checks.require(model.current?.favorite == true, "Favorite action updates active capture")
        model.setFilter(.favorite)
        try checks.require(model.visibleItems.count == 1, "Favorites filter includes saved capture")
        model.search = "zzzz-no-match"
        try checks.require(model.visibleItems.isEmpty && model.emptyLibraryText == L.t("library.noMatch"), "Library search excludes nonmatching captures")
        model.search = ""
        let id = model.currentID!
        model.toggleTrash()
        try checks.require(model.store.item(id)?.isTrashed == true && model.screen == .home, "Trash action returns home and preserves file")
        model.setFilter(.trash)
        model.select(model.visibleItems[0])
        try checks.require(model.currentID == id && model.current?.isTrashed == true, "Trash view opens capture with restore action")
        model.toggleTrash()
        try checks.require(model.store.item(id)?.isTrashed == false, "Restore action returns capture to library")
        model.setFilter(.all)
        model.select(model.store.item(id)!)
        model.toggleTheme()
        try checks.require(model.store.settings.darkMode && NSApp.appearance?.name == .darkAqua && model.theme.surface == Color(hex: 0x22283A), "Dark theme applies SuniPDF surface token")
        await screenshot(model, "editor-fr-dark")
        model.editor.canvas.crop(CGRect(x: 0, y: 0, width: 890, height: 720))
        try checks.require(model.editor.canvas.image?.width == 890, "Crop updates integrated canvas dimensions")
        model.undo()
        try checks.require(model.editor.canvas.image?.width == 1120, "Undo crop restores integrated canvas")

        let originalHash = SHA256.hash(data: try Data(contentsOf: model.store.resolve(model.current!.originalFile)))
        model.editor.tool = .highlight
        model.editor.text = "Texte personnalisé / custom text"
        model.editor.canvas.addShape(.highlight, CGPoint(x: 300, y: 400), CGPoint(x: 600, y: 460))
        let image = model.editor.canvas.image
        let rendered = try bytes(model.editor.canvas.render())
        try checks.require(model.changeLanguage("en"), "Header language change saves English preference")
        try checks.require(model.currentID == id && model.editor.canvas.image === image && model.editor.isDirty && model.editor.tool == .highlight
            && (try bytes(model.editor.canvas.render())) == rendered, "Live language change preserves open image, unsaved drawings, active tool and rendered pixels")
        try checks.require(model.editor.text == "Texte personnalisé / custom text", "Language changes preserve user-entered annotation text and capture names")
        try checks.require(try LibraryStore(root: model.store.root).settings.language == "en", "English preference survives storage reload")
        try checks.require(L.t("capture.region") == "Capture a region" && L.t("tool.highlight") == "Highlight", "Primary capture action and tool properties are translated")
        await screenshot(model, "editor-en-dark")
        model.showRecordingWorkspace()
        await screenshot(model, "recorder-en-dark")
        try checks.require(model.screen == .recorder && model.recordButtonText == "Record screen" && model.recordingStateText == "Ready to record", "Recorder state and start action use English")
        var settings = model.store.settings
        settings.language = "fr"
        settings.darkMode = false
        try checks.require(model.applySettings(settings) && L.language == "fr" && (try LibraryStore(root: model.store.root)).settings.language == "fr", "Saving preferences applies and persists French without restarting")
        try checks.require(SHA256.hash(data: try Data(contentsOf: model.store.resolve(model.store.item(id)!.originalFile))) == originalHash, "FR/EN changes preserve original capture bytes and user metadata")
        model.sheet = .about
        model.handleHotkey(4)
        try checks.require(!model.recording && !model.recordingRequested, "Global recording shortcut cannot start behind a dialog")
        for (sheet, name) in [(Sheet.about, "about-fr"), (.settings, "settings-fr"), (.help, "help-fr"), (.rename, "rename-fr")] {
            model.sheet = sheet
            await screenshot(model, name)
            try checks.require(model.window?.attachedSheet != nil, "\(name): dialog opens as a sheet of the main window")
            model.sheet = nil
            try await Task.sleep(for: .milliseconds(500))
            try checks.require(model.window?.attachedSheet == nil, "\(name): closing restores the main window")
        }
        model.toggleTheme()
        model.sheet = .about
        await screenshot(model, "about-fr-dark")
        model.sheet = nil
        try await Task.sleep(for: .milliseconds(500))
        model.toggleTheme()
    }

    private static func captureChecks(_ checks: Checks) async throws {
        try checks.require(ScreenCapture.hasPermission, "Screen recording permission granted to this build")
        let snapshot = try await ScreenCapture.desktop()
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        try checks.require(abs(CGFloat(snapshot.image.width) - union.width * snapshot.scale) <= 2, "Full desktop capture covers every display at native density")
        let windows = try await ScreenCapture.windows()
        try checks.require(!windows.contains { $0.title.hasPrefix("SuniCapture") && $0.title.contains("QA") }, "Window list excludes SuniCapture windows")

        try checks.require(snapshot.displays.count == NSScreen.screens.count && snapshot.displays.allSatisfy {
            $0.image.width == Int(($0.frame.width * $0.scale).rounded()) && $0.image.height == Int(($0.frame.height * $0.scale).rounded())
        }, "Each display is captured at its own native resolution")
        // A display with a lower density must fill its area of the composite, not a corner of it.
        for display in snapshot.displays {
            let quarter = CGRect(x: display.frame.midX, y: display.frame.midY, width: display.frame.width / 2, height: display.frame.height / 2)
            let native = try meanLevel(display.image, CGRect(x: quarter.minX - display.frame.minX, y: quarter.minY - display.frame.minY,
                                                             width: quarter.width, height: quarter.height).applying(.init(scaleX: display.scale, y: display.scale)))
            let composed = try meanLevel(snapshot.image, quarter.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
                .applying(.init(scaleX: snapshot.scale, y: snapshot.scale)))
            try checks.require(abs(native - composed) < 12, "Display \(display.id) at \(Int(display.scale))x fills its area of the full desktop")
        }

        // One selection per display, plus one across two displays when they touch.
        var cases = snapshot.displays.map { display in
            (CGRect(x: display.frame.minX + 100, y: display.frame.minY + 120, width: 400, height: 300), display.scale, "display \(display.id)")
        }
        if let first = snapshot.displays.first,
           let neighbour = snapshot.displays.dropFirst().first(where: { abs($0.frame.minX - first.frame.maxX) < 1 }) {
            let top = max(first.frame.minY, neighbour.frame.minY) + 100
            cases.append((CGRect(x: first.frame.maxX - 200, y: top, width: 400, height: 200), snapshot.scale, "two displays"))
        }
        for (index, (rect, scale, label)) in cases.enumerated() {
            let selection = Task { await RegionSelector.select(snapshot) }
            try await Task.sleep(for: .milliseconds(800))
            guard let selector = RegionSelector.active else { throw Failure(label: "Region selector opens over every display") }
            selector.start = CGPoint(x: rect.minX, y: rect.minY)
            selector.end = CGPoint(x: rect.maxX, y: rect.maxY)
            selector.redraw()
            if index == 0 { await screenshotDisplay("region-selector") }
            selector.finish(true)
            let region = await selection.value
            try checks.require(region?.width == Int((rect.width * scale).rounded()) && region?.height == Int((rect.height * scale).rounded()),
                               "Region selection on \(label) keeps \(Int(scale))x native pixels")
        }
    }

    /// Average RGB level of a pixel rectangle (top-left origin).
    private static func meanLevel(_ image: CGImage, _ rect: CGRect) throws -> Double {
        guard let part = image.cropping(to: rect.integral) else { throw Failure(label: "pixel area") }
        return try bytes(ImageFiles.normalized(part)).enumerated().reduce(0.0) { $1.offset % 4 == 3 ? $0 : $0 + Double($1.element) }
            / Double(part.width * part.height * 3)
    }

    private static func recordingChecks(_ model: AppModel, _ checks: Checks, audio: Bool) async throws {
        let suffix = audio ? " (computer audio)" : ""
        guard let screen = NSScreen.screens.first else { throw Failure(label: "No display") }
        let cover = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.level = .screenSaver
        cover.isReleasedWhenClosed = false
        let imageView = NSImageView(frame: screen.frame)
        imageView.image = NSImage(cgImage: fixture(), size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        cover.contentView = imageView
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        model.store.settings.systemAudio = audio
        model.showRecordingWorkspace()
        let start = Task { await model.startRecording() }
        await start.value
        try checks.require(model.recording && !model.stoppingRecording, "Start recording action creates native session and floating stop control" + suffix)
        // Another process plays the sound: SuniCapture's own audio is excluded from recordings.
        if audio { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/afplay"), arguments: ["/System/Library/Sounds/Glass.aiff"]) }
        try await Task.sleep(for: .seconds(2))
        model.stopRecording()
        try checks.require(model.stoppingRecording, "Stop action waits for MP4 finalization" + suffix)
        for _ in 0..<120 where model.stoppingRecording || model.recording { try await Task.sleep(for: .milliseconds(500)) }
        try checks.require(!model.recording && model.lastRecordingFailure == nil, "Finished recording releases floating bar and restores start action" + suffix)
        guard let video = model.current, video.isVideo else { throw Failure(label: "Completed MP4 is indexed and opens in video preview" + suffix) }
        try checks.require(model.screen == .video, "Completed MP4 is indexed and opens in video preview" + suffix)
        if !audio { await screenshot(model, "video-fr") }
        let url = try model.store.currentFile(video)
        try VideoRecorder.validateMP4(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try checks.require(duration > 0.5 && !tracks.isEmpty, "Finalized MP4 decodes with a video track" + suffix)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        try checks.require(audio ? !sound.isEmpty : sound.isEmpty, audio ? "Computer audio is recorded as an audio track" : "No audio track without the computer audio option")
        try checks.require(!(try FileManager.default.contentsOfDirectory(atPath: model.store.videoDirectory.path)).contains { $0.hasSuffix(".partial.mp4") }, "No partial file remains after a completed recording" + suffix)
    }

    // MARK: Helpers

    private static var screenshots: URL?

    /// Complete-window image of the main window, or of its open sheet.
    private static func screenshot(_ model: AppModel, _ name: String) async {
        guard ScreenCapture.hasPermission, let directory = screenshots, let window = model.window else { return }
        try? await Task.sleep(for: .milliseconds(700))
        let target = window.attachedSheet ?? window
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let shareable = content.windows.first(where: { $0.windowID == CGWindowID(target.windowNumber) }) else { return }
        await save(SCContentFilter(desktopIndependentWindow: shareable), directory.appendingPathComponent(name + ".png"))
    }

    private static func screenshotDisplay(_ name: String) async {
        guard let directory = screenshots, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return }
        await save(SCContentFilter(display: display, excludingWindows: []), directory.appendingPathComponent(name + ".png"))
    }

    private static func save(_ filter: SCContentFilter, _ url: URL) async {
        let info = SCShareableContent.info(for: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(info.contentRect.width * CGFloat(info.pointPixelScale))
        configuration.height = Int(info.contentRect.height * CGFloat(info.pointPixelScale))
        configuration.showsCursor = false
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
            try? ImageFiles.save(ImageFiles.normalized(image), to: url)
        }
    }

    static func fixture() -> CGImage {
        let width = 1120, height = 720
        let context = ImageFiles.context(width: width, height: height)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        func fill(_ hex: UInt32, _ rect: CGRect, radius: CGFloat = 0) {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ hex: UInt32, bold: Bool = false) {
            let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color])
                .draw(at: CGPoint(x: x, y: y))
        }
        fill(0xF4F7FB, CGRect(x: 0, y: 0, width: width, height: height))
        fill(0xFFFFFF, CGRect(x: 0, y: 0, width: width, height: 74))
        fill(0x2563EB, CGRect(x: 29, y: 23, width: 28, height: 28), radius: 14)
        text("Atelier Atlas", 70, 21, 22, 0x0F172A, bold: true)
        text("Projet fictif · Image de vérification", 758, 28, 13, 0x64748B)
        fill(0xFFFFFF, CGRect(x: 0, y: 75, width: 214, height: 645))
        text("Espace de travail", 28, 110, 12, 0x64748B)
        fill(0xE9EFFD, CGRect(x: 18, y: 151, width: 178, height: 44), radius: 7)
        text("Vue d’ensemble", 34, 162, 15, 0x2563EB, bold: true)
        for (index, label) in ["Tâches", "Documents", "Équipe"].enumerated() { text(label, 34, 220 + CGFloat(index) * 50, 15, 0x64748B) }
        text("Préparer la mise en ligne", 254, 115, 29, 0x0F172A, bold: true)
        text("Un espace fictif pour tester vos annotations.", 256, 160, 15, 0x64748B)
        fill(0x2563EB, CGRect(x: 255, y: 212, width: 820, height: 124), radius: 12)
        text("Chaque détail compte.", 282, 234, 26, 0xFFFFFF, bold: true)
        text("Validez les dernières étapes avant de partager votre projet.", 284, 280, 16, 0xDBEAFE)
        text("Liste de vérification", 256, 376, 19, 0x0F172A, bold: true)
        for row in 0..<3 {
            let y = 421 + CGFloat(row) * 74
            fill(0xE2E8F0, CGRect(x: 255, y: y, width: 820, height: 62), radius: 8)
            fill(0xFFFFFF, CGRect(x: 256, y: y + 1, width: 818, height: 60), radius: 8)
            fill(row < 2 ? 0xDCFCE7 : 0xE9EFFD, CGRect(x: 273, y: y + 17, width: 27, height: 27), radius: 6)
            text(row < 2 ? "✓" : "3", 280, y + 18, 17, row < 2 ? 0x15803D : 0x2563EB, bold: true)
            text(["Valider la navigation", "Relire les contenus", "Vérifier les images"][row], 318, y + 18, 16, 0x0F172A)
            text(row < 2 ? "Terminé" : "À vérifier", 950, y + 22, 12, row < 2 ? 0x15803D : 0x2563EB)
        }
        text("Données synthétiques. Aucun client, compte ou projet réel.", 256, 674, 12, 0x64748B)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// RGBA bytes, rows top to bottom.
    private static func bytes(_ image: CGImage) throws -> [UInt8] {
        guard let context = ImageFiles.context(width: image.width, height: image.height) else { throw Failure(label: "pixel buffer") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = image.width * 4
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in Array(UnsafeBufferPointer(start: data + y * context.bytesPerRow, count: row)) }
    }

    private static func runDirectory(_ root: URL) -> URL {
        let stamp = L.format("{0:yyyyMMdd-HHmmss}", [Date()])
        let url = root.appendingPathComponent("run-\(stamp)-\(UUID().uuidString.prefix(6).lowercased())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func describe(_ error: Error) -> String {
        (error as? Failure).map { "Check failed: " + $0.label } ?? String(describing: error)
    }

    private static func writeReport(_ passed: [String], _ failure: String?, _ run: URL, _ root: URL) -> Bool {
        let report: [String: Any] = ["success": failure == nil, "checkedAt": JSONDates.string(Date()), "count": passed.count,
                                     "passed": passed, "failure": failure ?? NSNull(), "runDirectory": run.path, "platform": "macOS"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: run.appendingPathComponent("report.json"))
            try? data.write(to: root.appendingPathComponent("latest-report.json"))
        }
        print(failure.map { "FAIL after \(passed.count) checks: \($0)" } ?? "PASS: \(passed.count) checks")
        return failure == nil
    }
}
