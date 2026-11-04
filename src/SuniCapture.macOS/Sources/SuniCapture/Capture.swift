import AppKit
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit

/// Frozen image of every display, in the global CoreGraphics space (points, origin top-left of the main display).
struct DesktopSnapshot {
    let image: CGImage
    let frame: CGRect
    let scale: CGFloat
}

struct WindowTarget: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func content() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw AppError(L.t("desktop.failed")) }
    }

    /// All displays composed at the highest pixel density, like the Windows virtual desktop.
    static func desktop() async throws -> DesktopSnapshot {
        let content = try await content()
        let ownApplications = content.applications.filter { $0.processID == getpid() }
        let displays = content.displays
        guard !displays.isEmpty else { throw AppError(L.t("engine.noDisplay")) }
        let filters = displays.map { SCContentFilter(display: $0, excludingApplications: ownApplications, exceptingWindows: []) }
        let scale = filters.map { CGFloat(SCShareableContent.info(for: $0).pointPixelScale) }.max() ?? 1
        let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
        let width = Int((union.width * scale).rounded()), height = Int((union.height * scale).rounded())
        guard width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 160_000_000,
              let context = ImageFiles.context(width: width, height: height) else { throw AppError(L.t("desktop.tooLarge")) }
        context.setFillColor(.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (display, filter) in zip(displays, filters) {
            let configuration = SCStreamConfiguration()
            configuration.width = Int((display.frame.width * scale).rounded())
            configuration.height = Int((display.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image: CGImage
            do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
            catch { throw AppError(L.t("desktop.failed")) }
            // CoreGraphics bitmaps grow upwards; the global display space grows downwards.
            context.draw(image, in: CGRect(x: (display.frame.minX - union.minX) * scale,
                                           y: (union.maxY - display.frame.maxY) * scale,
                                           width: CGFloat(configuration.width), height: CGFloat(configuration.height)))
        }
        guard let image = context.makeImage() else { throw AppError(L.t("desktop.failed")) }
        return DesktopSnapshot(image: image, frame: union, scale: scale)
    }

    static func windows() async throws -> [WindowTarget] {
        try await content().windows.compactMap { window -> WindowTarget? in
            guard window.isOnScreen, window.windowLayer == 0, window.frame.width > 40, window.frame.height > 40,
                  let application = window.owningApplication, application.processID != getpid() else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = application.applicationName
            guard !name.isEmpty || !title.isEmpty else { return nil }
            return WindowTarget(id: window.windowID, title: title.isEmpty || title == name ? name : "\(name) — \(title)")
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Captures the window's own pixels at native resolution, even when other windows cover it.
    static func window(_ target: WindowTarget) async throws -> CGImage {
        guard let window = try await content().windows.first(where: { $0.windowID == target.id }) else {
            throw AppError(L.t("desktop.closed"))
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        guard configuration.width > 1, configuration.height > 1 else { throw AppError(L.t("desktop.offscreen")) }
        do { return try ImageFiles.normalized(await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)) }
        catch { throw AppError(L.t("desktop.failed")) }
    }
}

// MARK: - Region selection

/// Opaque, snapshot-backed picker spanning every display. The selection reveals the frozen original.
final class RegionSelector {
    private let snapshot: DesktopSnapshot
    private var windows: [NSPanel] = []
    private var continuation: CheckedContinuation<CGImage?, Never>?
    var start: CGPoint?
    var end: CGPoint = .zero
    /// The picker on screen, for the interface self-test.
    private(set) static weak var active: RegionSelector?

    private init(_ snapshot: DesktopSnapshot) { self.snapshot = snapshot }

    static func select(_ snapshot: DesktopSnapshot) async -> CGImage? {
        let selector = RegionSelector(snapshot)
        active = selector
        return await withCheckedContinuation { continuation in
            selector.continuation = continuation
            selector.show()
        }
    }

    /// Global CoreGraphics rectangle in points.
    var selection: CGRect? {
        guard let start else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        return rect.width * snapshot.scale >= 2 && rect.height * snapshot.scale >= 2 ? rect : nil
    }

    func pixelSize(_ rect: CGRect) -> (Int, Int) {
        (Int((rect.width * snapshot.scale).rounded()), Int((rect.height * snapshot.scale).rounded()))
    }

    /// Global CoreGraphics point of an event, or of the pointer when no event is given.
    static func globalMouse(_ event: NSEvent? = nil) -> CGPoint {
        let location = event.flatMap { event in event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } } ?? NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: mainHeight - location.y)
    }

    func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, snapshot.frame.minX), snapshot.frame.maxX),
                y: min(max(point.y, snapshot.frame.minY), snapshot.frame.maxY))
    }

    private func show() {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let frame = CGDisplayBounds(number)
            let crop = CGRect(x: (frame.minX - snapshot.frame.minX) * snapshot.scale, y: (frame.minY - snapshot.frame.minY) * snapshot.scale,
                              width: frame.width * snapshot.scale, height: frame.height * snapshot.scale).integral
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.setFrame(screen.frame, display: false)
            window.acceptsMouseMovedEvents = true
            let view = SelectionView(selector: self, screenFrame: frame, background: snapshot.image.cropping(to: crop))
            window.contentView = view
            // Escape, Return and pointer moves are delivered to the first responder.
            window.initialFirstResponder = view
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate()
        for window in windows { window.makeKeyAndOrderFront(nil) }
        if let underMouse = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { underMouse.makeKeyAndOrderFront(nil) }
        redraw()
    }

    func redraw() { for window in windows { window.contentView?.needsDisplay = true } }

    func finish(_ confirm: Bool) {
        var result: CGImage?
        if confirm, let rect = selection {
            let pixels = CGRect(x: (rect.minX - snapshot.frame.minX) * snapshot.scale, y: (rect.minY - snapshot.frame.minY) * snapshot.scale,
                                width: rect.width * snapshot.scale, height: rect.height * snapshot.scale).integral
            result = snapshot.image.cropping(to: pixels)
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Non-activating: it takes the keyboard even when a global shortcut fired from another application,
/// which macOS's cooperative activation would otherwise keep in front.
private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let selector: RegionSelector
    private let screenFrame: CGRect
    private let background: CGImage?
    private static let accent = NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
    private static let panel = NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.96)

    init(selector: RegionSelector, screenFrame: CGRect, background: CGImage?) {
        self.selector = selector
        self.screenFrame = screenFrame
        self.background = background
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseMoved(with event: NSEvent) { selector.redraw() }

    override func mouseDown(with event: NSEvent) {
        selector.start = selector.clamped(RegionSelector.globalMouse(event))
        selector.end = selector.start!
        selector.redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard selector.start != nil else { return }
        selector.end = selector.clamped(RegionSelector.globalMouse(event))
        selector.redraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard selector.start != nil else { return }
        selector.end = selector.clamped(RegionSelector.globalMouse(event))
        if selector.selection != nil { selector.finish(true) } else { selector.start = nil; selector.redraw() }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: selector.finish(false)
        case kVK_Return, kVK_ANSI_KeypadEnter: if selector.selection != nil { selector.finish(true) }
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let background {
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(background, in: bounds)
            context.restoreGState()
        }
        let shade = NSColor(srgbRed: 9 / 255, green: 15 / 255, blue: 28 / 255, alpha: 130 / 255)
        if let rect = selector.selection {
            let local = rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: local))
            outside.windingRule = .evenOdd
            shade.setFill()
            outside.fill()
            Self.accent.setStroke()
            let border = NSBezierPath(rect: local)
            border.lineWidth = 2
            border.stroke()
            for corner in [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                           CGPoint(x: local.minX, y: local.maxY), CGPoint(x: local.maxX, y: local.maxY)] {
                let handle = NSBezierPath(rect: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6))
                NSColor.white.setFill()
                handle.fill()
                handle.lineWidth = 1
                handle.stroke()
            }
            let (width, height) = selector.pixelSize(rect)
            let label = "\(width) × \(height) px"
            let y = local.maxY + 12 + 30 < bounds.height ? local.maxY + 12 : max(0, local.minY - 38)
            pill(label, size: 12, origin: CGPoint(x: local.minX, y: y), height: 28, radius: 5)
        } else {
            shade.setFill()
            bounds.fill()
        }
        if screenFrame.contains(RegionSelector.globalMouse()) {
            let text = L.t("region.instruction") as NSString
            let width = text.size(withAttributes: attributes(13)).width + 36
            pill(text as String, size: 13, origin: CGPoint(x: (bounds.width - width) / 2, y: 26), height: 38, radius: 8)
        }
    }

    private func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white]
    }

    private func pill(_ text: String, size: CGFloat, origin: CGPoint, height: CGFloat, radius: CGFloat) {
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes(size))
        let padding = height > 30 ? 18.0 : 10.0
        let rect = CGRect(x: min(max(origin.x, 8), max(8, bounds.width - textSize.width - padding * 2 - 8)),
                          y: min(max(origin.y, 4), max(4, bounds.height - height - 4)),
                          width: textSize.width + padding * 2, height: height)
        Self.panel.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        string.draw(at: CGPoint(x: rect.minX + padding, y: rect.midY - textSize.height / 2), withAttributes: attributes(size))
    }
}

// MARK: - Countdown

enum Countdown {
    static func run(_ seconds: Int) async {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        let box = NSView(frame: panel.contentLayoutRect)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.9).cgColor
        box.layer?.cornerRadius = 20
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 44, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 22, width: 100, height: 56)
        box.addSubview(label)
        panel.contentView = box
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.frame { panel.setFrameOrigin(CGPoint(x: frame.midX - 50, y: frame.midY - 50)) }
        panel.orderFrontRegardless()
        for remaining in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(remaining)"
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }
}

// MARK: - Global shortcuts

/// Owns only the four SuniCapture shortcuts ⌃⇧1–4. Carbon hot keys need no Accessibility permission.
final class GlobalHotkeys {
    var pressed: ((Int) -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register() -> [String] {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard let context else { return noErr }
            let number = Int(identifier.id)
            let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.pressed?(number) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        var warnings: [String] = []
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (offset, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x534E_4350), id: UInt32(offset + 1))
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | shiftKey), identifier,
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { references.append(reference) } else { warnings.append(L.f("hotkey.conflict", offset + 1)) }
        }
        return warnings
    }
}
