import AppKit
import Carbon.HIToolbox
import SwiftUI

enum MacApp {
    /// Bundle version, or the Windows project version when running from the source checkout.
    static let version: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return value }
        guard let project = AppResources.url("SuniCapture.csproj"), let text = try? String(contentsOf: project, encoding: .utf8),
              let start = text.range(of: "<Version>"), let end = text.range(of: "</Version>", range: start.upperBound..<text.endIndex) else { return "dev" }
        return String(text[start.upperBound..<end.lowerBound])
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let arguments = Array(CommandLine.arguments.dropFirst())
    private var dataRoot: URL?
    private var isQA = false
    private var model: AppModel?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let hotkeys = GlobalHotkeys()
    private var pendingFiles: [URL] = []
    private var quitting = false
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            dataRoot = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        }
        isQA = arguments.contains { ["--qa", "--self-test", "--ui-self-test"].contains($0) }
        if isQA, dataRoot == nil {
            dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SuniCapture-QA/\(UUID().uuidString)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if arguments.contains("--version") { print(MacApp.version); exit(0) }
        if arguments.contains("--self-test"), let dataRoot { exit(Diagnostics.runCore(dataRoot) ? 0 : 1) }
        if !isQA, let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0 != .current }) {
            other.activate()
            message(L.t("app.alreadyOpen"))
            exit(0)
        }
        let store: LibraryStore
        do { store = try LibraryStore(root: dataRoot) } catch {
            message(L.t("app.startFailed") + error.localizedDescription, style: .critical)
            exit(1)
        }
        let model = AppModel(store: store, isQA: isQA)
        self.model = model
        createWindow(model)
        model.onLanguageChanged = { [weak self] in self?.buildMenus() }
        model.onQuit = { [weak self] in self?.quit() }
        buildMenus()
        if !isQA {
            hotkeys.pressed = { [weak model] number in model?.handleHotkey(number) }
            let warnings = hotkeys.register()
            if !warnings.isEmpty { model.setStatus(warnings.joined(separator: " ")) }
        }
        if let warning = store.loadWarning { model.setStatus(warning) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKey(event) ?? event }
        model.showMain()
        // AppKit would otherwise focus the search field, which captures the tool shortcuts.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.window?.makeFirstResponder(nil)
        }

        let files = arguments.filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { url in
            var directory: ObjCBool = false
            return url != dataRoot && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
        }
        if !(files + pendingFiles).isEmpty { model.importFiles(files + pendingFiles) }
        pendingFiles.removeAll()
        if arguments.contains("--qa") { model.seedQAImage() }
        if arguments.contains("--record") { model.showRecordingWorkspace() }
        for (flag, mode) in [("--capture-region", 1), ("--capture-screen", 2), ("--capture-window", 3)] where arguments.contains(flag) {
            Task { await model.capture(mode) }
        }
        if arguments.contains("--ui-self-test"), let dataRoot {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                exit(await Diagnostics.runInterface(model, dataRoot) ? 0 : 1)
            }
        }
    }

    private func createWindow(_ model: AppModel) {
        let area = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 940)
        let size = CGSize(width: min(model.store.settings.windowWidth, area.width - 40), height: min(model.store.settings.windowHeight, area.height - 40))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "SuniCapture"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 1000, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(model: model).ignoresSafeArea())
        window.center()
        model.window = window
        self.window = window
        if !isQA { createStatusItem() }
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? self
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }

    private func buildMenus() {
        let main = NSMenu()
        main.addItem(menu("SuniCapture", [
            item(L.t("about.title"), #selector(showAbout)),
            .separator(),
            item(L.t("mac.preferences"), #selector(showSettings), ","),
            .separator(),
            item(L.t("mac.hide"), #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item(L.t("mac.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item(L.t("mac.showAll"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item(L.t("mac.quit"), #selector(quitAction), "q"),
        ]))
        main.addItem(menu(L.t("mac.menuFile"), [
            item(L.t("capture.region"), #selector(captureRegion), "n"),
            item(L.t("tray.screen"), #selector(captureScreen), "2", [.control, .shift]),
            item(L.t("capture.chooseWindow"), #selector(captureWindow), "3", [.control, .shift]),
            item(L.t("record.title"), #selector(record), "4", [.control, .shift]),
            item(L.t("mac.recordRegion"), #selector(recordRegion)),
            .separator(),
            item(L.t("import.title") + "…", #selector(importImages), "o"),
            .separator(),
            item(L.t("action.save"), #selector(save), "s"),
            item(L.t("action.export"), #selector(export), "e"),
            .separator(),
            item(L.t("mac.closeWindow"), #selector(NSWindow.performClose(_:)), "w", target: nil),
        ]))
        main.addItem(menu(L.t("mac.menuEdit"), [
            item(L.t("mac.undo"), #selector(menuUndo), "z"),
            item(L.t("mac.redo"), #selector(menuRedo), "z", [.command, .shift]),
            .separator(),
            item(L.t("mac.cut"), #selector(NSText.cut(_:)), "x", target: nil),
            item(L.t("action.copy"), #selector(menuCopy), "c"),
            item(L.t("action.paste"), #selector(menuPaste), "v"),
            item(L.t("mac.selectAll"), #selector(NSText.selectAll(_:)), "a", target: nil),
        ]))
        let languages = [("fr", "Français"), ("en", "English")].map { code, name in
            let entry = item(name, #selector(chooseLanguage(_:)))
            entry.representedObject = code
            entry.state = L.language == code ? .on : .off
            return entry
        }
        let languageItem = menu(L.t("mac.language"), languages)
        main.addItem(menu(L.t("mac.menuView"), [
            item(L.t("mac.zoomIn"), #selector(zoomIn), "="),
            item(L.t("mac.zoomOut"), #selector(zoomOut), "-"),
            item(L.t("edit.fit"), #selector(fit), "0"),
            .separator(),
            item(L.t("theme.change"), #selector(toggleTheme)),
            languageItem,
        ]))
        let windowMenu = menu(L.t("mac.menuWindow"), [
            item(L.t("mac.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item(L.t("mac.zoomWindow"), #selector(NSWindow.performZoom(_:)), target: nil),
            .separator(),
            item(L.t("mac.bringAll"), #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
        ])
        main.addItem(windowMenu)
        let helpMenu = menu(L.t("mac.menuHelp"), [item(L.t("help.title"), #selector(showHelp), "?"), item(L.t("about.title"), #selector(showAbout))])
        main.addItem(helpMenu)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.helpMenu = helpMenu.submenu
        updateStatusItem()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Brand.icon.copy() as? NSImage ?? NSImage()
        icon.size = CGSize(width: 20, height: 20)
        statusItem?.button?.image = icon
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem else { return }
        statusItem.button?.toolTip = L.t("tray.hint")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt at each opening: the video entries follow the recording state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        let hotkey: NSEvent.ModifierFlags = [.control, .shift]
        let video = model?.recording == true
            ? [item(L.t("record.stopVideo"), #selector(record), "4", hotkey)]
            : [item(L.t("mac.recordRegion"), #selector(recordRegion)), item(L.t("mac.recordScreen"), #selector(record), "4", hotkey)]
        menu.removeAllItems()
        for entry in [item(L.t("tray.open"), #selector(openMain)), .separator(),
                      item(L.t("capture.region"), #selector(captureRegion), "1", hotkey),
                      item(L.t("tray.screen"), #selector(captureScreen), "2", hotkey),
                      item(L.t("capture.chooseWindow") + "…", #selector(captureWindow), "3", hotkey), .separator()]
            + video + [.separator(), item(L.t("settings.title"), #selector(showSettings)), item(L.t("about.title"), #selector(showAbout)),
                       .separator(), item(L.t("action.quit"), #selector(quitAction))] {
            menu.addItem(entry)
        }
    }

    // MARK: Actions

    private var idle: Bool { model.map { $0.sheet == nil && $0.modalDepth == 0 } ?? false }
    private var textResponder: NSText? { NSApp.keyWindow?.firstResponder as? NSText }

    @objc private func openMain() { model?.showMain() }
    @objc private func showAbout() { model?.showMain(); model?.sheet = .about }
    @objc private func showSettings() { model?.showMain(); model?.sheet = .settings }
    @objc private func showHelp() { model?.showMain(); model?.sheet = .help }
    @objc private func captureRegion() { if idle, let model { model.showMain(); Task { await model.capture(1) } } }
    @objc private func captureScreen() { if idle, let model { model.showMain(); Task { await model.capture(2) } } }
    @objc private func captureWindow() { if idle, let model { model.showMain(); Task { await model.capture(3) } } }
    @objc private func record() { if idle { model?.handleHotkey(4) } }
    @objc private func recordRegion() { if idle, let model { model.showRecordingWorkspace(); Task { await model.startRecording(region: true) } } }
    @objc private func importImages() { if idle { model?.importPanel() } }
    @objc private func save() { if idle { model?.saveCurrent(announce: true) } }
    @objc private func export() { if idle { model?.screen == .video ? model?.exportVideo() : model?.exportImage() } }
    @objc private func zoomIn() { if let editor = model?.editor { editor.setZoom(editor.zoom * 1.25) } }
    @objc private func zoomOut() { if let editor = model?.editor { editor.setZoom(editor.zoom / 1.25) } }
    @objc private func fit() { model?.editor.fitImage() }
    @objc private func toggleTheme() { model?.toggleTheme() }
    @objc private func chooseLanguage(_ sender: NSMenuItem) { if let code = sender.representedObject as? String { model?.changeLanguage(code) } }
    @objc private func quitAction() { quit() }

    /// Text fields keep their own editing commands; elsewhere the commands act on the image.
    @objc private func menuUndo(_ sender: Any?) { if let text = textResponder { text.undoManager?.undo() } else if idle { model?.undo() } }
    @objc private func menuRedo(_ sender: Any?) { if let text = textResponder { text.undoManager?.redo() } else if idle { model?.redo() } }
    @objc private func menuCopy(_ sender: Any?) { if let text = textResponder { text.copy(sender) } else if idle { model?.copyImage() } }
    @objc private func menuPaste(_ sender: Any?) { if let text = textResponder { text.paste(sender) } else if idle { model?.paste() } }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if Int(event.keyCode) == kVK_F1, modifiers.isEmpty { showHelp(); return nil }
        guard event.window === window, idle, !model.busy, textResponder == nil else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, key == "y" { model.redo(); return nil }
        guard modifiers.isEmpty, model.screen == .editor, let tool = EditorTool.allCases.first(where: { $0.key.lowercased() == key }) else { return event }
        model.editor.tool = tool
        return nil
    }

    private func quit() {
        quitting = true
        // AppKit ignores terminate while a sheet is attached: close it first.
        guard model?.sheet != nil || window?.attachedSheet != nil else { NSApp.terminate(nil); return }
        model?.sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.terminate(nil)
        }
    }

    private func message(_ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = "SuniCapture"
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    // MARK: Lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        if model.recording || model.stoppingRecording {
            model.exitAfterRecording = true
            model.stopRecording()
            return false
        }
        guard model.saveCurrent() else { return false }
        if !quitting, !isQA, model.store.settings.minimizeToTray, statusItem != nil {
            model.hideMain()
            model.setStatus(L.t("tray.available"))
            return false
        }
        quit()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.recording || model.stoppingRecording {
            model.exitAfterRecording = true
            model.stopRecording()
            return .terminateCancel
        }
        guard model.saveCurrent() else { return .terminateCancel }
        if let window {
            model.store.settings.windowWidth = window.frame.width
            model.store.settings.windowHeight = window.frame.height
            model.trySaveSettings()
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showMain()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.importFiles(urls) } else { pendingFiles += urls }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
