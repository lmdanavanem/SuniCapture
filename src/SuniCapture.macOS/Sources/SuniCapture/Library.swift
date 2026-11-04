import CoreGraphics
import Foundation
import Observation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Same JSON schema as the Windows and Linux clients, so a library can move between them.
struct CaptureItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var name = "Capture"
    var createdAt = Date()
    var kind = "image"
    var originalFile = ""
    var editedFile: String?
    var width = 0
    var height = 0
    var durationSeconds = 0.0
    var source = "Capture"
    var favorite = false
    var isTrashed = false
    var trashedAt: Date?

    var isVideo: Bool { kind == "video" }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", createdAt = "CreatedAt", kind = "Kind", originalFile = "OriginalFile"
        case editedFile = "EditedFile", width = "Width", height = "Height", durationSeconds = "DurationSeconds"
        case source = "Source", favorite = "Favorite", isTrashed = "IsTrashed", trashedAt = "TrashedAt"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        originalFile = try c.decode(String.self, forKey: .originalFile)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? createdAt
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? kind
        editedFile = try c.decodeIfPresent(String.self, forKey: .editedFile)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? source
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        isTrashed = try c.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
    }

    var subtitle: String {
        isVideo ? L.f("library.videoSubtitle", durationSeconds)
            : L.format("{0:dd MMM · HH:mm}", [createdAt]) + "   \(width) × \(height)"
    }
}

struct AppSettings: Codable, Equatable {
    var language = Locale.preferredLanguages.first?.hasPrefix("fr") == false ? "en" : "fr"
    var darkMode = false
    var captureDelay = 0
    var copyAfterCapture = true
    var systemAudio = false
    var minimizeToTray = true
    var windowWidth = 1440.0
    var windowHeight = 940.0

    enum CodingKeys: String, CodingKey {
        case language = "Language", darkMode = "DarkMode", captureDelay = "CaptureDelay", copyAfterCapture = "CopyAfterCapture"
        case systemAudio = "SystemAudio", minimizeToTray = "MinimizeToTray", windowWidth = "WindowWidth", windowHeight = "WindowHeight"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = L.normalize(try c.decodeIfPresent(String.self, forKey: .language) ?? language)
        darkMode = try c.decodeIfPresent(Bool.self, forKey: .darkMode) ?? false
        captureDelay = min(10, max(0, try c.decodeIfPresent(Int.self, forKey: .captureDelay) ?? 0))
        copyAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .copyAfterCapture) ?? true
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
        minimizeToTray = try c.decodeIfPresent(Bool.self, forKey: .minimizeToTray) ?? true
        windowWidth = min(3000, max(960, try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? 1440))
        windowHeight = min(2000, max(620, try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? 940))
    }
}

/// ISO 8601 with offset, as written by .NET `DateTimeOffset` (7 fractional digits) and Python (6).
nonisolated enum JSONDates {
    static func parse(_ text: String) -> Date? {
        var value = text
        if let dot = value.firstIndex(of: ".") {
            let digits = value[value.index(after: dot)...].prefix { $0.isNumber }
            if digits.count > 3 { value.replaceSubrange(digits.startIndex..<digits.endIndex, with: digits.prefix(3)) }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
            }
            return date
        }
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(date))
        }
        return encoder
    }
}

/// One damaged entry must not hide the rest of the library.
private struct LossyItem: Decodable {
    let item: CaptureItem?
    init(from decoder: Decoder) throws { item = try? CaptureItem(from: decoder) }
}

@Observable
final class LibraryStore {
    let root: URL
    var items: [CaptureItem] = []
    var settings = AppSettings()
    @ObservationIgnored private(set) var loadWarning: String?

    var originalDirectory: URL { root.appendingPathComponent("originals") }
    var editedDirectory: URL { root.appendingPathComponent("edited") }
    var videoDirectory: URL { root.appendingPathComponent("videos") }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuniCapture")
    }

    init(root: URL? = nil) throws {
        let base = (root ?? Self.defaultRoot).standardizedFileURL
        for name in ["originals", "edited", "videos"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        self.root = URL(fileURLWithPath: Self.realPath(base), isDirectory: true)
        settings = readRecoverable(AppSettings.self, "settings.json") ?? AppSettings()
        L.setLanguage(settings.language)
        let entries = readRecoverable([LossyItem].self, "library.json") ?? []
        items = entries.compactMap(\.item).filter { item in
            item.id.count == 32 && item.id.allSatisfy(\.isHexDigit)
                && (try? resolve(item.originalFile)) != nil
                && (item.editedFile == nil || (try? resolve(item.editedFile!)) != nil)
        }
        items.sort { $0.createdAt > $1.createdAt }
    }

    func resolve(_ relative: String) throws -> URL {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains(":"), !normalized.contains("\0"),
              !normalized.split(separator: "/").contains("..") else { throw AppError(L.t("store.invalidPath")) }
        let url = root.appendingPathComponent(normalized).standardizedFileURL
        guard Self.realPath(url).hasPrefix(root.path + "/") else { throw AppError(L.t("store.outside")) }
        return url
    }

    /// realpath(3) of the deepest existing ancestor; `resolvingSymlinksInPath` drops `/private` inconsistently.
    private static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buffer) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return (realPath(parent) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    func item(_ id: String?) -> CaptureItem? { items.first { $0.id == id } }
    func currentFile(_ item: CaptureItem) throws -> URL { try resolve(item.editedFile ?? item.originalFile) }

    func save() throws { try writeAtomic("library.json", JSONDates.encoder.encode(items)) }
    func saveSettings() throws { try writeAtomic("settings.json", JSONDates.encoder.encode(settings)) }

    /// Applies a change to one item and persists it; the in-memory item is restored if saving fails.
    func update(_ id: String, _ change: (inout CaptureItem) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items[index]
        change(&items[index])
        do { try save() } catch { items[index] = previous; throw error }
    }

    func addImage(_ image: CGImage, source: String, name: String? = nil) throws -> CaptureItem {
        var item = CaptureItem()
        item.name = name ?? L.f("library.captureName", Date())
        item.width = image.width
        item.height = image.height
        item.source = source
        item.originalFile = "originals/\(item.id).png"
        try ImageFiles.save(image, to: resolve(item.originalFile))
        items.insert(item, at: 0)
        do { try save() } catch { items.removeFirst(); throw error }
        return item
    }

    func addVideo(_ path: URL, duration: Double, width: Int, height: Int) throws -> CaptureItem {
        var item = CaptureItem()
        item.name = L.f("library.recordingName", Date())
        item.kind = "video"
        item.durationSeconds = duration
        item.width = width
        item.height = height
        item.source = L.t("record.primary")
        item.originalFile = "videos/\(item.id).mp4"
        let destination = try resolve(item.originalFile)
        let moved = path.standardizedFileURL != destination
        if moved { try FileManager.default.moveItem(at: path, to: destination) }
        items.insert(item, at: 0)
        do { try save() } catch {
            items.removeFirst()
            if moved {
                do { try FileManager.default.moveItem(at: destination, to: path) }
                catch { throw AppError(L.f("library.videoRecovery", destination.path)) }
            }
            throw error
        }
        return item
    }

    func saveEdited(_ id: String, _ image: CGImage) throws {
        let relative = "edited/\(id).png"
        let final = try resolve(relative)
        let temporary = editedDirectory.appendingPathComponent("\(id).writing.png")
        try ImageFiles.save(image, to: temporary)
        guard rename(temporary.path, final.path) == 0 else { throw AppError(String(cString: strerror(errno))) }
        try update(id) {
            $0.editedFile = relative
            $0.width = image.width
            $0.height = image.height
        }
    }

    private func readRecoverable<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let path = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do { return try JSONDates.decoder.decode(T.self, from: Data(contentsOf: path)) } catch {
            loadWarning = L.f("library.loadWarning", name)
            // Keep the damaged file for recovery, then fall back to the last valid index.
            let stamp = L.format("{0:yyyyMMdd-HHmmss}", [Date()])
            try? FileManager.default.copyItem(at: path, to: root.appendingPathComponent(name + ".unreadable-" + stamp))
            return try? JSONDates.decoder.decode(T.self, from: Data(contentsOf: root.appendingPathComponent(name + ".bak")))
        }
    }

    private func writeAtomic(_ name: String, _ data: Data) throws {
        let path = root.appendingPathComponent(name)
        let temporary = root.appendingPathComponent(name + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: path.path) {
            let backup = root.appendingPathComponent(name + ".bak")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: path, to: backup)
        }
        guard rename(temporary.path, path.path) == 0 else { throw AppError(String(cString: strerror(errno))) }
    }
}
