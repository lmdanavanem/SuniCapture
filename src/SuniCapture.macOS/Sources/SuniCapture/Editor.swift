import AppKit
import Carbon.HIToolbox
import Observation

enum EditorTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, pen, highlight, text, step, pixelate, crop

    var key: String {
        switch self {
        case .select: "V"; case .arrow: "A"; case .rectangle: "R"; case .ellipse: "O"; case .pen: "P"
        case .highlight: "H"; case .text: "T"; case .step: "N"; case .pixelate: "B"; case .crop: "C"
        }
    }

    var labelKey: String { self == .pixelate ? "tool.redact" : "tool.\(rawValue)" }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .ellipse: "circle"
        case .pen: "pencil.tip"; case .highlight: "highlighter"; case .text: "textformat"; case .step: "1.circle"
        case .pixelate: "eye.slash"; case .crop: "crop"
        }
    }

    var hintKey: String {
        switch self {
        case .select: "tool.selectHint"; case .text: "tool.textHint"; case .step: "tool.stepHint"; case .pixelate: "tool.redactionHint"
        case .crop: "tool.cropHint"; case .highlight: "tool.highlightHint"; default: "tool.drawHint"
        }
    }
}

struct Annotation {
    var kind: EditorTool
    var start: CGPoint
    var end: CGPoint
    var color: CGColor
    var thickness: CGFloat
    var textSize: CGFloat
    var text: String
    var number: Int
    var points: [CGPoint]
}

/// Immutable snapshot; identity marks the saved state, like the Windows records.
final class CanvasState {
    let bitmap: CGImage
    let annotations: [Annotation]
    let nextStep: Int
    init(_ bitmap: CGImage, _ annotations: [Annotation], _ nextStep: Int) {
        self.bitmap = bitmap
        self.annotations = annotations
        self.nextStep = nextStep
    }
}

/// Edits in image pixels; the scroll view controls display zoom independently.
final class AnnotationCanvas: NSView {
    private var undoStack: [CanvasState] = []
    private var redoStack: [CanvasState] = []
    private var points: [CGPoint] = []
    private(set) var state: CanvasState?
    private var cleanState: CanvasState?
    private var original: CGImage?
    private var gestureStart: CGPoint?
    private var gestureEnd: CGPoint = .zero

    var onChange: (() -> Void)?
    var tool: EditorTool = .arrow { didSet { cancelGesture(); window?.invalidateCursorRects(for: self) } }
    var inkColor = CGColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
    var maskColor = CGColor(srgbRed: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255, alpha: 1)
    var strokeWidth: CGFloat = 4
    var textValue = "Texte"
    var fontSize: CGFloat = 24

    var image: CGImage? {
        get { state?.bitmap }
        set {
            cancelGesture()
            undoStack.removeAll()
            redoStack.removeAll()
            original = newValue
            state = newValue.map { CanvasState($0, [], 1) }
            cleanState = state
            updateSize()
            notifyChanged()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { state !== cleanState }
    var annotationCount: Int { state?.annotations.count ?? 0 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func markClean() { cleanState = state; notifyChanged() }

    func undo() {
        cancelGesture()
        guard let current = state, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        state = previous
        updateSize()
        notifyChanged()
    }

    func redo() {
        cancelGesture()
        guard let current = state, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        state = next
        updateSize()
        notifyChanged()
    }

    func render() throws -> CGImage {
        guard let state else { throw AppError(L.t("edit.noImage")) }
        return try Self.render(state)
    }

    /// Adds one shape with the current tool properties; also used by the local diagnostics.
    func addShape(_ kind: EditorTool, _ start: CGPoint, _ end: CGPoint) {
        guard let state, kind != .select else { return }
        let start = clamp(start), end = clamp(end)
        if kind == .crop { crop(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))); return }
        if kind == .text, textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        commit(annotation(kind, start, end, number: state.nextStep, points: kind == .pen ? [start, end] : []))
    }

    func crop(_ selection: CGRect) {
        guard let state else { return }
        let bounds = CGRect(x: 0, y: 0, width: state.bitmap.width, height: state.bitmap.height)
        let rect = selection.intersection(bounds)
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return }
        let x = Int(rect.minX.rounded(.down)), y = Int(rect.minY.rounded(.down))
        let width = min(Int(rect.maxX.rounded(.up)) - x, state.bitmap.width - x)
        let height = min(Int(rect.maxY.rounded(.up)) - y, state.bitmap.height - y)
        guard width != state.bitmap.width || height != state.bitmap.height else { return }
        // Flatten first: annotations and opaque masks keep exactly their visible position.
        guard let flat = try? Self.render(state), let cropped = flat.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { return }
        commit(CanvasState(cropped, [], state.nextStep))
    }

    // MARK: Mouse and keyboard

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard state != nil, tool != .select else { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        if tool == .text || tool == .step { addShape(tool, point, point); return }
        gestureStart = point
        gestureEnd = point
        points = [point]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard gestureStart != nil else { return }
        gestureEnd = clamp(convert(event.locationInWindow, from: nil))
        if tool == .pen, let last = points.last, hypot(gestureEnd.x - last.x, gestureEnd.y - last.y) >= 0.75 { points.append(gestureEnd) }
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = gestureStart else { return }
        gestureEnd = clamp(convert(event.locationInWindow, from: nil))
        let gesture = annotation(tool, start, gestureEnd, number: 0, points: tool == .pen ? points : [])
        let selection = CGRect(x: min(start.x, gestureEnd.x), y: min(start.y, gestureEnd.y),
                               width: abs(gestureEnd.x - start.x), height: abs(gestureEnd.y - start.y))
        let current = tool
        cancelGesture()
        if current == .crop { crop(selection) }
        else if hypot(gesture.end.x - gesture.start.x, gesture.end.y - gesture.start.y) >= 2 || (current == .pen && gesture.points.count > 1) {
            commit(gesture)
        }
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape, gestureStart != nil { cancelGesture() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state, let context = NSGraphicsContext.current?.cgContext else { return }
        Self.draw(state, in: context)
        guard let start = gestureStart else { return }
        if tool == .crop {
            let rect = CGRect(x: min(start.x, gestureEnd.x), y: min(start.y, gestureEnd.y),
                              width: abs(gestureEnd.x - start.x), height: abs(gestureEnd.y - start.y))
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: rect))
            outside.windingRule = .evenOdd
            NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 120 / 255).setFill()
            outside.fill()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1).setStroke()
            border.stroke()
        } else {
            Self.draw(annotation(tool, start, gestureEnd, number: 0, points: tool == .pen ? points : []), in: context)
        }
    }

    // MARK: State

    private func annotation(_ kind: EditorTool, _ start: CGPoint, _ end: CGPoint, number: Int, points: [CGPoint]) -> Annotation {
        Annotation(kind: kind, start: start, end: end, color: (kind == .pixelate ? maskColor : inkColor).copy(alpha: 1) ?? inkColor,
                   thickness: min(50, max(1, strokeWidth)), textSize: min(200, max(10, fontSize)), text: textValue,
                   number: number, points: points)
    }

    private func commit(_ annotation: Annotation) {
        guard let state else { return }
        commit(CanvasState(state.bitmap, state.annotations + [annotation], state.nextStep + (annotation.kind == .step ? 1 : 0)))
    }

    private func commit(_ next: CanvasState) {
        if let state { undoStack.append(state) }
        redoStack.removeAll()
        state = next
        trimHistory()
        updateSize()
        notifyChanged()
    }

    /// Bounds both the number of steps and the distinct image pixels retained by undo.
    private func trimHistory() {
        while undoStack.count > 60 { undoStack.removeFirst() }
        while undoStack.count > 1 {
            var seen = Set<ObjectIdentifier>()
            var pixels = 0
            for bitmap in undoStack.map(\.bitmap) + [state!.bitmap] where seen.insert(ObjectIdentifier(bitmap)).inserted {
                pixels += bitmap.width * bitmap.height
            }
            if pixels <= 128_000_000 { break }
            undoStack.removeFirst()
        }
    }

    private func cancelGesture() {
        gestureStart = nil
        points.removeAll()
        needsDisplay = true
    }

    private func updateSize() {
        let size = CGSize(width: state?.bitmap.width ?? 0, height: state?.bitmap.height ?? 0)
        if frame.size != size { setFrameSize(size) }
        window?.invalidateCursorRects(for: self)
    }

    private func notifyChanged() {
        needsDisplay = true
        onChange?()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard let state else { return .zero }
        return CGPoint(x: min(max(point.x, 0), CGFloat(state.bitmap.width)), y: min(max(point.y, 0), CGFloat(state.bitmap.height)))
    }

    // MARK: Rendering (shared by the view and the flattened export)

    static func render(_ state: CanvasState) throws -> CGImage {
        let width = state.bitmap.width, height = state.bitmap.height
        guard width * height <= ImageFiles.maxPixels, let context = ImageFiles.context(width: width, height: height) else {
            throw AppError(L.t("edit.imageLimit"))
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(state, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw AppError(L.t("edit.imageLimit")) }
        return image
    }

    /// Draws into a top-left origin context whose NSGraphicsContext is flipped.
    static func draw(_ state: CanvasState, in context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: state.bitmap.width, height: state.bitmap.height)
        context.saveGState()
        context.clip(to: rect)
        context.saveGState()
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(state.bitmap, in: rect)
        context.restoreGState()
        for annotation in state.annotations { draw(annotation, in: context) }
        context.restoreGState()
    }

    static func draw(_ a: Annotation, in context: CGContext) {
        let color = NSColor(cgColor: a.color) ?? .systemBlue
        let bounds = CGRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y), width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y))
        func stroke(_ path: NSBezierPath) {
            path.lineWidth = a.thickness
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
        switch a.kind {
        case .arrow:
            let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
            let length = hypot(dx, dy)
            guard length >= 0.1 else { break }
            let ux = dx / length, uy = dy / length
            let head = min(max(13, a.thickness * 3.5), length * 0.65)
            let normal = CGPoint(x: -uy, y: ux)
            let base = CGPoint(x: a.end.x - ux * head, y: a.end.y - uy * head)
            let line = NSBezierPath()
            line.move(to: a.start)
            line.line(to: CGPoint(x: a.end.x - ux * head * 0.3, y: a.end.y - uy * head * 0.3))
            stroke(line)
            let triangle = NSBezierPath()
            triangle.move(to: a.end)
            triangle.line(to: CGPoint(x: base.x + normal.x * head * 0.45, y: base.y + normal.y * head * 0.45))
            triangle.line(to: CGPoint(x: base.x - normal.x * head * 0.45, y: base.y - normal.y * head * 0.45))
            triangle.close()
            color.setFill()
            triangle.fill()
        case .rectangle:
            stroke(NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3))
        case .ellipse:
            stroke(NSBezierPath(ovalIn: bounds))
        case .pen:
            guard a.points.count > 1 else { break }
            let path = NSBezierPath()
            path.move(to: a.points[0])
            for point in a.points.dropFirst() { path.line(to: point) }
            stroke(path)
        case .highlight:
            color.withAlphaComponent(85 / 255).setFill()
            bounds.fill(using: .sourceOver)
        case .pixelate:
            // Solid opaque redaction is intentional: the export contains no recoverable source pixels.
            color.setFill()
            bounds.fill()
        case .text:
            guard !a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            let text = NSAttributedString(string: a.text, attributes: [.font: NSFont.systemFont(ofSize: a.textSize, weight: .semibold), .foregroundColor: color])
            let size = text.size()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: a.start.x - 7, y: a.start.y - 4, width: size.width + 14, height: size.height + 8), xRadius: 4, yRadius: 4).fill()
            text.draw(at: a.start)
        case .step:
            let radius = max(17, a.textSize * 0.7)
            let circle = NSBezierPath(ovalIn: CGRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2))
            color.setFill()
            circle.fill()
            circle.lineWidth = max(2, radius * 0.12)
            NSColor.white.setStroke()
            circle.stroke()
            let number = NSAttributedString(string: "\(a.number)", attributes: [.font: NSFont.systemFont(ofSize: radius * 1.13, weight: .semibold), .foregroundColor: NSColor.white])
            let size = number.size()
            number.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
        case .select, .crop:
            break
        }
    }
}

/// Keeps a smaller image centered in the scroll view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Owns the canvas and its scroll view; exposes the editor state to SwiftUI.
@Observable
final class EditorController {
    @ObservationIgnored let canvas = AnnotationCanvas()
    @ObservationIgnored let scrollView = NSScrollView()
    @ObservationIgnored var onChange: (() -> Void)?
    var tool: EditorTool = .arrow { didSet { canvas.tool = tool } }
    var colorHex = "#2563EB"
    var stroke = 4.0 { didSet { canvas.strokeWidth = stroke } }
    var text = "" { didSet { canvas.textValue = text } }
    var fontSize = 28.0 { didSet { canvas.fontSize = fontSize } }
    var zoom = 1.0
    var fit = true
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var isDirty = false
    private(set) var pixelSize = CGSize.zero

    init() {
        canvas.fontSize = fontSize
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 6
        scrollView.drawsBackground = true
        scrollView.postsFrameChangedNotifications = true
        canvas.onChange = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fit = false
                self.zoom = self.scrollView.magnification * self.backingScale
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.fit == true { self?.fitImage() } }
        }
    }

    /// 100 % shows one image pixel per physical screen pixel.
    private var backingScale: CGFloat { scrollView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func setColor(_ hex: String) -> Bool {
        guard let color = Self.color(hex) else { return false }
        canvas.inkColor = color
        colorHex = hex.uppercased().hasPrefix("#") ? hex.uppercased() : "#" + hex.uppercased()
        return true
    }

    static func color(_ hex: String) -> CGColor? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 8 { value = String(value.dropFirst(2)) }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }

    func setZoom(_ value: Double, manual: Bool = true) {
        if manual { fit = false }
        zoom = min(6, max(0.03, value))
        scrollView.magnification = zoom / backingScale
    }

    func fitImage() {
        fit = true
        guard canvas.image != nil, canvas.frame.width > 0, canvas.frame.height > 0 else { return }
        let available = scrollView.contentSize
        let ratio = min(max(10, available.width - 76) / canvas.frame.width, max(10, available.height - 76) / canvas.frame.height)
        setZoom(min(1, ratio * backingScale), manual: false)
    }

    func refresh() {
        canUndo = canvas.canUndo
        canRedo = canvas.canRedo
        isDirty = canvas.isDirty
        pixelSize = CGSize(width: canvas.image?.width ?? 0, height: canvas.image?.height ?? 0)
        onChange?()
    }
}
