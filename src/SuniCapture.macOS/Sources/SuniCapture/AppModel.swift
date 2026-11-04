import AppKit
import AVFoundation
import Observation
import OSLog
import UniformTypeIdentifiers

enum Screen { case home, editor, video, recorder }
enum LibraryFilter: String { case all, favorite, video, trash }

enum Sheet: Identifiable {
    case about, settings, help, rename, windows([WindowTarget])
    var id: String {
        switch self {
        case .about: "about"; case .settings: "settings"; case .help: "help"; case .rename: "rename"; case .windows: "windows"
        }
    }
}

/// Port of the Windows MainWindow logic: library, capture, editing, recording and preferences.
@Observable
final class AppModel {
    let store: LibraryStore
    let editor = EditorController()
    let isQA: Bool
    var screen: Screen = .home
    var filter: LibraryFilter = .all
    var search = ""
    var currentID: String?
    var status: String
    var sheet: Sheet?
    var thumbnails: [String: NSImage] = [:]
    var busy = false
    var recording = false
    var recordingRequested = false
    var stoppingRecording = false
    var lastRecordingFailure: String?
    var recordingElapsed: TimeInterval = 0
    var player: AVPlayer?
    var playing = false
    var modalDepth = 0

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onLanguageChanged: (() -> Void)?
    @ObservationIgnored var onQuit: (() -> Void)?
    @ObservationIgnored var exitAfterRecording = false
    @ObservationIgnored private var recorder: VideoRecorder?
    @ObservationIgnored private var recordingBar: RecordingBar?
    @ObservationIgnored private var recordingStart = Date()
    @ObservationIgnored private var recordingTimer: Timer?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var loadingCanvas = false
    @ObservationIgnored private var playerObserver: NSObjectProtocol?

    init(store: LibraryStore, isQA: Bool) {
        self.store = store
        self.isQA = isQA
        status = L.t("status.ready")
        editor.text = L.t("edit.defaultText")
        editor.onChange = { [weak self] in self?.canvasChanged() }
        applyTheme()
    }

    var theme: Theme { Theme(dark: store.settings.darkMode) }
    var current: CaptureItem? { store.item(currentID) }
    var libraryCount: Int { store.items.count { !$0.isTrashed } }

    var visibleItems: [CaptureItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter { item in
            if !query.isEmpty, item.name.range(of: query, options: .caseInsensitive, locale: L.locale) == nil { return false }
            switch filter {
            case .trash: return item.isTrashed
            case .favorite: return !item.isTrashed && item.favorite
            case .video: return !item.isTrashed && item.isVideo
            case .all: return !item.isTrashed
            }
        }
    }

    var emptyLibraryText: String {
        !search.isEmpty ? L.t("library.noMatch") : filter == .trash ? L.t("library.emptyTrash")
            : filter == .video ? L.t("library.emptyVideo") : L.t("library.empty")
    }

    var sectionTitle: String {
        switch filter {
        case .favorite: L.t("library.yourFavorites"); case .video: L.t("library.yourRecordings")
        case .trash: L.t("library.toRestore"); case .all: L.t("library.recent")
        }
    }

    // MARK: Library

    func loadThumbnail(_ item: CaptureItem) {
        guard !item.isVideo, thumbnails[item.id] == nil, let url = try? store.currentFile(item) else { return }
        let id = item.id
        Task {
            let image = await Task.detached(priority: .utility) { ImageFiles.thumbnail(url) }.value
            if let image { thumbnails[id] = NSImage(cgImage: image, size: .zero) }
        }
    }

    func select(_ item: CaptureItem) {
        guard item.id != currentID || screen == .home || screen == .recorder else { return }
        guard saveCurrent() else { return }
        open(item)
    }

    func open(_ item: CaptureItem) {
        do {
            stopPlayer()
            if item.isVideo {
                let url = try store.currentFile(item)
                guard FileManager.default.fileExists(atPath: url.path) else { throw AppError(L.t("video.missing")) }
                currentID = item.id
                let player = AVPlayer(url: url)
                playerObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.playing = false
                        self?.player?.seek(to: .zero)
                    }
                }
                self.player = player
                screen = .video
                setStatus(L.t("video.ready"))
                return
            }
            let image = try ImageFiles.load(store.currentFile(item))
            currentID = item.id
            loadingCanvas = true
            editor.canvas.image = image
            loadingCanvas = false
            screen = .editor
            editor.fit = true
            // The canvas takes keyboard focus so tool letters and Escape reach it.
            Task {
                await Task.yield()
                editor.fitImage()
                editor.canvas.window?.makeFirstResponder(editor.canvas)
            }
            setStatus(item.isTrashed ? L.t("status.trashed") : L.t("status.imageOpen"))
        } catch {
            loadingCanvas = false
            fail("error.openCapture", error)
        }
    }

    func addImage(_ image: CGImage, source: String, name: String? = nil) throws {
        guard saveCurrent() else { return }
        let item = try store.addImage(image, source: source, name: name)
        filter = .all
        search = ""
        loadThumbnail(item)
        open(item)
        if store.settings.copyAfterCapture, !isQA, !Clipboard.write(image) { setStatus(L.t("status.clipboardBusy")) }
    }

    func setFilter(_ value: LibraryFilter) {
        guard saveCurrent() else { return }
        filter = value
    }

    func showRecordings() {
        filter = .video
        search = ""
        setStatus(L.t("record.listHint"))
    }

    func goHome() { if saveCurrent() { showHome() } }

    func showHome() {
        currentID = nil
        stopPlayer()
        screen = .home
        loadingCanvas = true
        editor.canvas.image = nil
        loadingCanvas = false
    }

    // MARK: Capture

    func ensurePermission() -> Bool {
        if ScreenCapture.hasPermission || CGRequestScreenCaptureAccess() { return true }
        if alert(L.t("mac.permissionTitle"), L.t("mac.permission"), buttons: [L.t("mac.openSettings"), L.t("action.cancel")]) == .alertFirstButtonReturn {
            ScreenCapture.openPrivacySettings()
        }
        setStatus(L.t("desktop.failed"))
        return false
    }

    func capture(_ mode: Int, window target: WindowTarget? = nil) async {
        guard !busy, !recording, modalDepth == 0, saveCurrent() else { return }
        if mode == 3, target == nil { await chooseWindow(); return }
        guard isQA || ensurePermission() else { return }
        busy = true
        defer { busy = false; showMain() }
        hideMain()
        if store.settings.captureDelay > 0 { await Countdown.run(store.settings.captureDelay) }
        try? await Task.sleep(for: .milliseconds(200))
        do {
            let image: CGImage?
            switch mode {
            case 1: image = await RegionSelector.select(try await ScreenCapture.desktop())
            case 2: image = try await ScreenCapture.desktop().image
            default: image = try await ScreenCapture.window(target!)
            }
            guard let image else { setStatus(L.t("status.cancelled")); return }
            try addImage(ImageFiles.normalized(image), source: mode == 1 ? L.t("source.region") : mode == 2 ? L.t("source.desktop") : L.t("capture.window"))
        } catch {
            fail("error.capture", error)
        }
    }

    func chooseWindow() async {
        guard ensurePermission() else { return }
        do { sheet = .windows(try await ScreenCapture.windows()) } catch { fail("error.capture", error) }
    }

    func captureWindow(_ target: WindowTarget) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await capture(3, window: target)
        }
    }

    func handleHotkey(_ number: Int) {
        guard !busy, modalDepth == 0, sheet == nil else { return }
        if number == 4 {
            if recording { stopRecording() } else { showRecordingWorkspace(); Task { await startRecording() } }
        } else {
            showMain()
            Task { await capture(number) }
        }
    }

    // MARK: Import, paste, editing

    func importFiles(_ urls: [URL]) {
        guard !busy, saveCurrent() else { return }
        var imported = 0
        var errors: [String] = []
        for url in urls {
            do {
                try addImage(ImageFiles.load(url), source: L.t("source.imported"), name: url.deletingPathExtension().lastPathComponent)
                imported += 1
            } catch { errors.append(url.lastPathComponent + " : " + error.localizedDescription) }
        }
        setStatus(errors.isEmpty ? L.f("import.count", imported) : L.f("import.partialCount", imported, errors.count))
        if !errors.isEmpty { alert(L.t("import.incomplete"), errors.prefix(8).joined(separator: "\n"), style: .warning) }
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.title = L.t("import.title")
        panel.allowedContentTypes = ImageFiles.importTypes
        panel.allowsMultipleSelection = true
        if runModal(panel) == .OK { importFiles(panel.urls) }
    }

    func paste() {
        guard let image = Clipboard.readImage() else { setStatus(L.t("status.noClipboard")); return }
        do {
            try addImage(ImageFiles.normalized(image), source: L.t("source.clipboard"))
            setStatus(L.t("status.pasted"))
        } catch { fail("error.paste", error) }
    }

    @discardableResult
    func saveCurrent(announce: Bool = false) -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let item = current, !item.isVideo, editor.canvas.image != nil, editor.canvas.isDirty else { return true }
        do {
            try store.saveEdited(item.id, editor.canvas.render())
            editor.canvas.markClean()
            thumbnails[item.id] = nil
            if let updated = store.item(item.id) { loadThumbnail(updated) }
            setStatus(announce ? L.t("status.annotationsSaved") : L.t("status.localSaved"))
            return true
        } catch {
            fail("error.saveAnnotations", error)
            return false
        }
    }

    private func canvasChanged() {
        guard !loadingCanvas else { return }
        if editor.isDirty {
            saveTimer?.invalidate()
            saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.saveCurrent() }
            }
            setStatus(L.t("status.savingAnnotations"))
        }
        if editor.fit { Task { await Task.yield(); editor.fitImage() } }
    }

    func undo() { if screen == .editor { editor.canvas.undo() } }
    func redo() { if screen == .editor { editor.canvas.redo() } }

    func copyImage() {
        guard screen == .editor, editor.canvas.image != nil else { return }
        do {
            guard Clipboard.write(try editor.canvas.render()) else { throw AppError(L.t("status.clipboardBusy")) }
            setStatus(L.t("status.copied"))
        } catch { fail("error.copy", error) }
    }

    func exportImage() {
        guard screen == .editor, editor.canvas.image != nil, let item = current else { return }
        let panel = NSSavePanel()
        panel.title = L.t("export.title")
        panel.nameFieldStringValue = Self.safeFileName(item.name) + ".png"
        let picker = FormatPicker(panel: panel)
        panel.accessoryView = picker.view
        // The popup's target is weak; keep the picker alive while the panel runs.
        guard withExtendedLifetime(picker, { runModal(panel) }) == .OK, let url = panel.url else { return }
        do {
            try ImageFiles.save(editor.canvas.render(), to: url)
            saveCurrent()
            setStatus(L.t("export.done") + url.lastPathComponent)
        } catch { fail("error.export", error) }
    }

    func restoreOriginal() {
        guard let item = current, !item.isVideo else { return }
        guard alert(L.t("edit.original"), L.t("original.confirm"), buttons: [L.t("edit.original"), L.t("action.cancel")]) == .alertFirstButtonReturn else { return }
        do {
            saveTimer?.invalidate()
            let image = try ImageFiles.load(store.resolve(item.originalFile))
            try store.update(item.id) {
                $0.editedFile = nil
                $0.width = image.width
                $0.height = image.height
            }
            thumbnails[item.id] = nil
            if let updated = store.item(item.id) { loadThumbnail(updated) }
            loadingCanvas = true
            editor.canvas.image = image
            loadingCanvas = false
            editor.fitImage()
            setStatus(L.t("original.done"))
        } catch {
            loadingCanvas = false
            fail("error.original", error)
        }
    }

    func toggleFavorite() {
        guard let item = current else { return }
        do {
            try store.update(item.id) { $0.favorite.toggle() }
            setStatus(current?.favorite == true ? L.t("favorite.added") : L.t("favorite.removed"))
        } catch { fail("error.favorites", error) }
    }

    func rename(_ name: String) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        guard let item = current, !value.isEmpty else { return }
        do {
            try store.update(item.id) { $0.name = value }
            setStatus(L.t("rename.done"))
        } catch { fail("rename.title", error) }
    }

    func toggleTrash() {
        guard let item = current, saveCurrent() else { return }
        do {
            try store.update(item.id) {
                $0.isTrashed.toggle()
                $0.trashedAt = $0.isTrashed ? Date() : nil
            }
            let trashed = store.item(item.id)?.isTrashed == true
            showHome()
            setStatus(trashed ? L.t("trash.done") : L.t("trash.restored"))
        } catch { fail("error.move", error) }
    }

    // MARK: Preferences

    func setDelay(_ seconds: Int) {
        store.settings.captureDelay = seconds
        trySaveSettings()
    }

    func setSystemAudio(_ value: Bool) {
        guard !recording, !recordingRequested else { return }
        store.settings.systemAudio = value
        trySaveSettings()
    }

    func toggleTheme() {
        store.settings.darkMode.toggle()
        applyTheme()
        trySaveSettings()
    }

    func applyTheme() {
        NSApp.appearance = NSAppearance(named: store.settings.darkMode ? .darkAqua : .aqua)
        editor.scrollView.backgroundColor = NSColor(theme.canvas)
    }

    @discardableResult
    func changeLanguage(_ code: String) -> Bool {
        let previous = store.settings
        store.settings.language = L.normalize(code)
        do { try store.saveSettings() } catch {
            store.settings = previous
            fail("settings.save", error)
            return false
        }
        refreshLanguage()
        setStatus(L.t("language.changed"))
        return true
    }

    @discardableResult
    func applySettings(_ settings: AppSettings) -> Bool {
        let previous = store.settings
        store.settings = settings
        do { try store.saveSettings() } catch {
            store.settings = previous
            fail("settings.save", error)
            alert(L.t("settings.title"), L.t("settings.saveFailed") + "\n" + error.localizedDescription, style: .warning)
            return false
        }
        refreshLanguage()
        applyTheme()
        setStatus(L.t("settings.saved"))
        return true
    }

    private func refreshLanguage() {
        L.setLanguage(store.settings.language)
        window?.title = screen == .recorder ? L.t("record.workspaceTitle") : "SuniCapture"
        onLanguageChanged?()
    }

    func trySaveSettings() {
        do { try store.saveSettings() } catch { fail("settings.save", error) }
    }

    // MARK: Recording

    func showRecordingWorkspace() {
        guard !busy, saveCurrent() else { return }
        showHome()
        screen = .recorder
        if !recording { recordingElapsed = 0 }
        showMain()
        setStatus(L.t("record.workspaceHint"))
    }

    func toggleRecordButton() {
        if recording { stopRecording() } else { showRecordingWorkspace() }
    }

    func startRecording() async {
        guard !busy, !recording, !stoppingRecording, modalDepth == 0, sheet == nil, saveCurrent() else { return }
        guard isQA || ensurePermission() else { return }
        busy = true
        recordingRequested = true
        lastRecordingFailure = nil
        defer { busy = false; recordingRequested = false }
        hideMain()
        await Countdown.run(max(3, store.settings.captureDelay))
        try? await Task.sleep(for: .milliseconds(200))
        let recorder = VideoRecorder()
        recorder.completed = { [weak self] url in self?.recordingCompleted(url) }
        recorder.failed = { [weak self] message in self?.recordingFailed(message) }
        self.recorder = recorder
        let url = store.videoDirectory.appendingPathComponent("recording-\(UUID().uuidString.lowercased()).mp4")
        recordingStart = Date()
        recordingElapsed = 0
        await recorder.start(url, systemAudio: store.settings.systemAudio)
        guard recorder.isRecording else { return }
        recording = true
        stoppingRecording = false
        recordingBar = RecordingBar(model: self)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        setStatus(L.t("record.running"))
    }

    private func tick() { recordingElapsed = Date().timeIntervalSince(recordingStart) }

    func stopRecording() {
        guard !stoppingRecording, let recorder, recorder.isRecording else { return }
        stoppingRecording = true
        recordingTimer?.invalidate()
        tick()
        setStatus(L.t("record.finalizing"))
        recorder.stop()
    }

    private func recordingCompleted(_ url: URL) {
        let size = recorder?.pixelSize ?? .zero
        finishRecordingUI()
        do {
            let item = try store.addVideo(url, duration: recordingElapsed, width: Int(size.width), height: Int(size.height))
            filter = .all
            search = ""
            if saveCurrent() { open(item) }
            setStatus(L.t("record.done"))
        } catch { fail("error.addVideo", error) }
        showMain()
        if exitAfterRecording { onQuit?() }
    }

    private func recordingFailed(_ message: String) {
        lastRecordingFailure = message
        finishRecordingUI()
        showMain()
        setStatus(L.t("record.interrupted") + message)
        if !isQA { alert(L.t("record.failedTitle"), message, style: .warning) }
        exitAfterRecording = false
    }

    private func finishRecordingUI() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        stoppingRecording = false
        recording = false
        recorder?.completed = nil
        recorder?.failed = nil
        recorder = nil
        recordingBar?.close()
        recordingBar = nil
    }

    static func clock(_ seconds: TimeInterval, hours: Bool) -> String {
        let total = Int(seconds)
        return hours ? String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    var barElapsed: String { Self.clock(recordingElapsed, hours: false) }

    var recordingStateText: String {
        stoppingRecording ? L.t("record.savingMp4") : recording ? L.t("record.inProgress")
            : recordingRequested && busy ? L.t("record.preparing") : lastRecordingFailure != nil ? L.t("record.failed") : L.t("record.ready")
    }

    var recordButtonText: String {
        stoppingRecording ? L.t("record.finalizingShort") : recording ? L.t("record.stopVideo") : L.t("record.title")
    }

    var recordingHelpText: String {
        lastRecordingFailure ?? (stoppingRecording ? L.t("record.finalizingHelp") : recording ? L.t("record.runningHelp")
            : L.f("record.countdownHelp", max(3, store.settings.captureDelay)))
    }

    // MARK: Video

    func togglePlay() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    private func stopPlayer() {
        player?.pause()
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        player = nil
        playing = false
    }

    func openVideo() {
        guard let item = current, item.isVideo, let url = try? store.currentFile(item) else { return }
        if !NSWorkspace.shared.open(url) { setStatus(L.t("error.openPath")) }
    }

    func exportVideo() {
        guard let item = current, item.isVideo else { return }
        let panel = NSSavePanel()
        panel.title = L.t("video.exportTitle")
        panel.nameFieldStringValue = Self.safeFileName(item.name) + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard runModal(panel) == .OK, let url = panel.url else { return }
        do {
            let source = try store.currentFile(item)
            if url.standardizedFileURL != source.standardizedFileURL {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: source, to: url)
            }
            setStatus(L.t("video.exported") + url.lastPathComponent)
        } catch { fail("error.exportVideo", error) }
    }

    // MARK: Shell

    func showMain() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hideMain() { window?.orderOut(nil) }

    func openFolder() { NSWorkspace.shared.open(store.root) }

    func openLicenses() {
        if let url = AppResources.url("THIRD-PARTY-NOTICES.md") { NSWorkspace.shared.open(url) } else { setStatus(L.t("about.licensesMissing")) }
    }

    func setStatus(_ text: String) { status = text }
    func fail(_ key: String, _ error: Error) {
        status = L.t(key) + " : " + error.localizedDescription
        Self.log.error("\(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    private static let log = Logger(subsystem: "ch.suniworks.SuniCapture", category: "app")

    @discardableResult
    func alert(_ title: String, _ message: String, style: NSAlert.Style = .informational, buttons: [String] = []) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        modalDepth += 1
        defer { modalDepth -= 1 }
        return alert.runModal()
    }

    private func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        modalDepth += 1
        defer { modalDepth -= 1 }
        return panel.runModal()
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "_" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "SuniCapture" : trimmed
    }

    func seedQAImage() {
        try? addImage(Diagnostics.fixture(), source: "Image synthétique de vérification", name: "Projet de démonstration")
        setStatus("Mode de vérification · bibliothèque isolée · image synthétique.")
    }
}

/// Format menu of the export panel; keeps the extension and the allowed type in step.
final class FormatPicker: NSObject {
    let view: NSView
    private let panel: NSSavePanel
    private let popup = NSPopUpButton()
    private let formats: [(String, UTType)] = [("PNG", .png), ("JPEG", .jpeg), ("BMP", .bmp), ("PDF", .pdf)]

    init(panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: L.t("mac.exportFormat"))
        view = NSStackView(views: [label, popup])
        (view as? NSStackView)?.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        super.init()
        popup.addItems(withTitles: formats.map(\.0))
        popup.target = self
        popup.action = #selector(changed)
        panel.allowedContentTypes = [.png]
    }

    @objc private func changed() {
        let (_, type) = formats[popup.indexOfSelectedItem]
        panel.allowedContentTypes = [type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + (type.preferredFilenameExtension ?? "png")
    }
}
