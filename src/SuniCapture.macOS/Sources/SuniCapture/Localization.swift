import Foundation
import Observation

/// Shared FR/EN catalog of the Windows client, completed by the macOS overrides.
/// Views reading `L.t` observe `L.state`, so a language change refreshes them in place.
@Observable
final class LanguageState {
    var code = "fr"
}

enum L {
    static let state = LanguageState()
    private static let catalog = loadCatalog()

    static var language: String { state.code }
    static var locale: Locale { Locale(identifier: language == "en" ? "en_GB" : "fr_CH") }
    static var keys: Set<String> { Set(catalog.keys) }

    static func normalize(_ value: String?) -> String { value?.lowercased() == "en" ? "en" : "fr" }
    static func setLanguage(_ value: String?) {
        let code = normalize(value)
        if state.code != code { state.code = code }
    }

    static func t(_ key: String) -> String { catalog[key]?[state.code] ?? key }
    static func f(_ key: String, _ arguments: Any...) -> String { format(t(key), arguments) }

    static func translateSource(_ source: String) -> String {
        for key in ["source.region", "source.desktop", "capture.window", "source.imported", "source.clipboard", "record.primary", "capture.name"] {
            if let entry = catalog[key], entry.values.contains(source) { return t(key) }
        }
        return source
    }

    /// Composite formatting compatible with the .NET resources: `{0}`, `{0:0}`, `{1:dd MMMM yyyy 'at' HH:mm}`.
    static func format(_ template: String, _ arguments: [Any]) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if (character == "{" || character == "}"), next < template.endIndex, template[next] == character {
                output.append(character)
                index = template.index(after: next)
                continue
            }
            if character == "{", let close = template[next...].firstIndex(of: "}") {
                let spec = template[next..<close].split(separator: ":", maxSplits: 1)
                if let number = Int(spec.first ?? ""), number < arguments.count {
                    output += render(arguments[number], spec.count > 1 ? String(spec[1]) : nil)
                    index = template.index(after: close)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    private static func render(_ value: Any, _ format: String?) -> String {
        switch value {
        case let date as Date:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateFormat = format ?? "dd.MM.yyyy HH:mm"
            return formatter.string(from: date)
        case let number as Double where format == "0":
            return String(Int(number.rounded()))
        case let number as Double:
            return number.formatted(.number.locale(locale))
        default:
            return "\(value)"
        }
    }

    private static func loadCatalog() -> [String: [String: String]] {
        func read(_ name: String) -> [String: [String: String]] {
            guard let url = AppResources.url(name), let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
            return value
        }
        var catalog = read("strings.json").mapValues { $0.mapValues(macShortcuts) }
        catalog.merge(read("strings.macos.json")) { _, override in override }
        return catalog
    }

    /// Global shortcuts stay on Control+Shift (⌘⇧3/4/5 belong to macOS); editing shortcuts use Command.
    static func macShortcuts(_ text: String) -> String {
        text.replacingOccurrences(of: "Ctrl + Shift + ", with: "⌃⇧")
            .replacingOccurrences(of: "Ctrl + Maj + ", with: "⌃⇧")
            .replacingOccurrences(of: "Ctrl+Shift+", with: "⌃⇧")
            .replacingOccurrences(of: "Ctrl+Maj+", with: "⌃⇧")
            .replacingOccurrences(of: "Ctrl+Y", with: "⇧⌘Z")
            .replacingOccurrences(of: "Ctrl+", with: "⌘")
    }
}

/// Files bundled in the .app, or read from the source checkout when running with `swift run`.
enum AppResources {
    private static let sourceLocations = [
        "src/SuniCapture/Localization", "src/SuniCapture.macOS/Resources", "assets/Brand", "src/SuniCapture", "",
    ]

    static func url(_ name: String) -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        while let current = directory, current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("src/SuniCapture.macOS").path) {
                for location in sourceLocations {
                    let candidate = current.appendingPathComponent(location).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                }
                return nil
            }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }
}
