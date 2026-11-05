import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme (tokens of the Windows client and SuniPDF)

struct Theme {
    let dark: Bool
    var chrome: Color { Color(hex: dark ? 0x191E2E : 0xF8FAFC) }
    var surface: Color { Color(hex: dark ? 0x22283A : 0xFFFFFF) }
    var border: Color { Color(hex: dark ? 0x343C52 : 0xE2E8F0) }
    var text: Color { Color(hex: dark ? 0xF1F5F9 : 0x0F172A) }
    var muted: Color { Color(hex: dark ? 0xA5B4CA : 0x64748B) }
    var accentSoft: Color { Color(hex: dark ? 0x2C3C59 : 0xE9EFFD) }
    var hover: Color { Color(hex: dark ? 0x2A3648 : 0xEEF2F7) }
    var canvas: Color { Color(hex: dark ? 0x0B101A : 0xE5E7EB) }
    var green: Color { Color(hex: dark ? 0x86EFAC : 0x15803D) }
    var accent: Color { Color(hex: 0x2563EB) }
    static let red = Color(hex: 0xDC2626)
    static let brandRed = Color(hex: 0xEF3438)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var theme = Theme(dark: false)
}

struct PrimaryButtonStyle: ButtonStyle {
    var color = Color(hex: 0x2563EB)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(color.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var padding = EdgeInsets(top: 8, leading: 13, bottom: 8, trailing: 13)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.text.opacity(enabled ? 1 : 0.4))
            .padding(padding)
            .background(configuration.isPressed ? theme.hover : theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border))
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering || configuration.isPressed ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct NavButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(active ? theme.accentSoft : configuration.isPressed ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

/// Brand images from the bundle or the source checkout.
enum Brand {
    static let logo = AppResources.url("sunicapture-logo.png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    static let icon = AppResources.url("sunicapture-icon.png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
}

// MARK: - Main window

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            HeaderView(model: model)
            CaptureBar(model: model)
            HStack(spacing: 0) {
                LibraryPanel(model: model).frame(width: 265)
                Rectangle().fill(theme.border).frame(width: 1)
                Group {
                    switch model.screen {
                    case .home: HomeView(model: model)
                    case .editor: EditorView(model: model)
                    case .video: VideoView(model: model)
                    case .recorder: RecorderView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            StatusBar(model: model)
        }
        .background(theme.chrome)
        .foregroundStyle(theme.text)
        .environment(\.theme, theme)
        .environment(\.locale, L.locale)
        .preferredColorScheme(theme.dark ? .dark : .light)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
                }
                if !urls.isEmpty { model.importFiles(urls) }
            }
            return true
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .about: AboutDialog(model: model)
                case .settings: SettingsDialog(model: model)
                case .help: HelpDialog(model: model)
                case .rename: RenameDialog(model: model)
                case .windows(let windows): WindowPickerDialog(model: model, windows: windows)
                }
            }
            .environment(\.theme, theme)
            .foregroundStyle(theme.text)
            .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }
}

private struct HeaderView: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: Brand.icon).resizable().interpolation(.high).frame(width: 40, height: 40).padding(.trailing, 6)
            (Text("Suni").fontWeight(.semibold) + Text(L.t("capture.name")).fontWeight(.semibold).foregroundColor(Theme.brandRed))
                .font(.system(size: 21))
            Text(MacApp.version).font(.system(size: 10)).foregroundStyle(theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2).background(theme.hover, in: RoundedRectangle(cornerRadius: 4)).padding(.leading, 10)
            Spacer()
            Circle().fill(theme.green).frame(width: 6, height: 6).padding(.trailing, 7)
            Text(L.t("header.local")).font(.system(size: 12)).foregroundStyle(theme.muted).padding(.trailing, 22)
            Button(L.t("action.import"), action: model.importPanel).buttonStyle(SecondaryButtonStyle()).help(L.t("action.importHint")).padding(.trailing, 8)
            Button(L.t("action.paste"), action: model.paste).buttonStyle(SecondaryButtonStyle()).help(L.t("action.pasteHint")).padding(.trailing, 12)
            Menu {
                Picker(L.t("language.choose"), selection: Binding(get: { L.language }, set: { model.changeLanguage($0) })) {
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) { Image(systemName: "globe"); Text(L.language.uppercased()).font(.system(size: 11)) }
            }
            .menuStyle(.button).buttonStyle(QuietButtonStyle()).fixedSize().help(L.t("language.choose")).accessibilityLabel(L.t("language.choose"))
            Button { model.sheet = .about } label: { Text("?").font(.system(size: 19)).frame(width: 22) }
                .buttonStyle(QuietButtonStyle()).help(L.t("about.title")).accessibilityLabel(L.t("about.title"))
            Button(action: model.toggleTheme) { Image(systemName: theme.dark ? "sun.max" : "moon").frame(width: 22) }
                .buttonStyle(QuietButtonStyle()).help(theme.dark ? L.t("theme.light") : L.t("theme.dark"))
                .accessibilityLabel(theme.dark ? L.t("theme.light") : L.t("theme.dark"))
            Button { model.sheet = .settings } label: { Image(systemName: "gearshape").frame(width: 22) }
                .buttonStyle(QuietButtonStyle()).help(L.t("settings.hint")).accessibilityLabel(L.t("settings.hint"))
        }
        .padding(.leading, 84).padding(.trailing, 20)
        .frame(height: 64)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

private struct CaptureBar: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            Button { Task { await model.capture(1) } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 15))
                    Text(L.t("capture.region"))
                    Text(L.t("shortcut.region")).font(.system(size: 11)).foregroundStyle(Color(hex: 0xCBDBFF)).padding(.leading, 9)
                }
            }
            .buttonStyle(PrimaryButtonStyle()).help(L.t("capture.regionHint"))
            Button { Task { await model.capture(2) } } label: { Label(L.t("capture.screen"), systemImage: "display") }
                .buttonStyle(SecondaryButtonStyle()).help(L.t("capture.screenHint"))
            Button { Task { await model.capture(3) } } label: { Label(L.t("capture.window"), systemImage: "macwindow") }
                .buttonStyle(SecondaryButtonStyle()).help(L.t("capture.windowHint"))
            Button(action: model.toggleRecordButton) {
                HStack(spacing: 8) { Circle().fill(Theme.red).frame(width: 8, height: 8); Text(model.recordButtonText) }
            }
            .buttonStyle(SecondaryButtonStyle()).help(L.t("record.hint")).disabled(model.stoppingRecording || model.busy)
            .accessibilityLabel(L.t("record.title"))
            Spacer()
            Text(L.t("capture.delay")).foregroundStyle(theme.muted)
            Picker("", selection: Binding(get: { model.store.settings.captureDelay }, set: { model.setDelay($0) })) {
                Text(L.t("delay.none")).tag(0)
                Text(L.t("delay.3")).tag(3)
                Text(L.t("delay.5")).tag(5)
                Text(L.t("delay.10")).tag(10)
            }
            .labelsHidden().frame(width: 120).accessibilityLabel(L.t("capture.delayHint"))
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

private struct LibraryPanel: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.t("library.title")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.libraryCount)").foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 9).padding(.bottom, 13)
            TextField(L.t("library.search"), text: $model.search)
                .textFieldStyle(.roundedBorder).controlSize(.large).help(L.t("library.searchHint"))
                .accessibilityLabel(L.t("library.search")).padding(.horizontal, 3).padding(.bottom, 12)
            nav("record.title", "record.circle", Theme.red, active: model.screen == .recorder, bold: true) { model.showRecordingWorkspace() }
                .help(L.t("record.createHint"))
            nav("library.all", "square.grid.2x2", nil, active: model.filter == .all && model.screen != .recorder) { model.setFilter(.all) }
            nav("library.favorites", "star", nil, active: model.filter == .favorite && model.screen != .recorder) { model.setFilter(.favorite) }
            nav("library.recordings", "video", nil, active: model.filter == .video && model.screen != .recorder) { model.setFilter(.video) }
            nav("library.trash", "trash", nil, active: model.filter == .trash && model.screen != .recorder) { model.setFilter(.trash) }
            Text(model.sectionTitle).font(.system(size: 11)).foregroundStyle(theme.muted).padding(.leading, 11).padding(.top, 20).padding(.bottom, 8)
            let items = model.visibleItems
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in LibraryRow(model: model, item: item) }
                }
            }
            .overlay(alignment: .topLeading) {
                if items.isEmpty { Text(model.emptyLibraryText).font(.system(size: 12)).foregroundStyle(theme.muted).padding(12) }
            }
            .accessibilityLabel(L.t("library.list"))
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("library.onComputer")).font(.system(size: 12, weight: .semibold))
                Text(L.t("library.originals")).font(.system(size: 11)).foregroundStyle(theme.muted)
                Button(L.t("action.openFolder"), action: model.openFolder).buttonStyle(SecondaryButtonStyle()).font(.system(size: 12)).padding(.top, 5)
            }
            .padding(.horizontal, 7).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        }
        .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)
        .background(theme.surface)
    }

    private func nav(_ key: String, _ symbol: String, _ tint: Color?, active: Bool, bold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).foregroundStyle(tint ?? theme.accent).frame(width: 18)
                Text(L.t(key)).fontWeight(bold ? .semibold : .regular)
            }
        }
        .buttonStyle(NavButtonStyle(active: active))
    }
}

private struct LibraryRow: View {
    let model: AppModel
    let item: CaptureItem
    @Environment(\.theme) private var theme

    var body: some View {
        Button { model.select(item) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(theme.hover)
                    if let thumbnail = model.thumbnails[item.id] {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(theme.muted)
                    }
                }
                .frame(width: 54, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.favorite { Text("★").foregroundStyle(Color(hex: 0xD97706)) }
            }
            .padding(5)
            .background(item.id == model.currentID ? theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { model.loadThumbnail(item) }
    }
}

private struct StatusBar: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(model.status).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 20)
            Text(L.t("shortcut.regionHint")).font(.system(size: 10))
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 17)
        .frame(height: 30)
        .background(theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

// MARK: - Home

private struct HomeView: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    Image(nsImage: Brand.logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 124, height: 124)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.t("home.welcome")).font(.system(size: 27, weight: .semibold))
                        Text(L.t("home.subtitle")).font(.system(size: 15)).foregroundStyle(theme.muted)
                    }
                }
                .padding(.bottom, 20)
                Button { Task { await model.capture(1) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 21)).frame(width: 40, height: 40)
                            .background(Color(hex: 0x407AFF), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L.t("capture.region")).font(.system(size: 20, weight: .semibold))
                            Text(L.t("home.startHint")).font(.system(size: 13)).foregroundStyle(Color(hex: 0xE0EAFF))
                        }
                        Spacer()
                        Text(L.t("shortcut.region")).foregroundStyle(Color(hex: 0xD6E3FF))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 13)
                }
                .buttonStyle(PrimaryButtonStyle())
                Text(L.t("home.quick")).font(.system(size: 17, weight: .semibold)).padding(.top, 30).padding(.bottom, 17)
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        card("display", theme.accent, "home.screen", "home.screenHint") { Task { await model.capture(2) } }
                        card("macwindow", Color(hex: 0x8B5CF6), "home.window", "home.windowHint") { Task { await model.capture(3) } }
                    }
                    GridRow {
                        card("record.circle", Theme.red, "record.title", "home.recordHint") { model.showRecordingWorkspace() }
                        card("photo.on.rectangle", Color(hex: 0x159660), "home.image", "home.imageHint") { model.importPanel() }
                    }
                }
                Text(L.t("home.footer")).font(.system(size: 12)).foregroundStyle(theme.muted).lineSpacing(5)
                    .padding(.top, 18).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
                    .padding(.top, 30)
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 38).padding(.top, 30).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ symbol: String, _ tint: Color, _ title: String, _ hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint).padding(.bottom, 5)
                Text(L.t(title)).font(.system(size: 15, weight: .semibold))
                Text(L.t(hint)).font(.system(size: 12)).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)))
    }
}

// MARK: - Editor

private struct CanvasHost: NSViewRepresentable {
    let editor: EditorController
    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

private struct EditorView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @State private var hex = "#2563EB"
    private static let palette: [UInt32] = [0x2563EB, 0xDC2626, 0x16A34A, 0xF59E0B, 0x8B5CF6, 0x0F172A, 0xFFFFFF, 0xE11D48]

    var body: some View {
        let editor = model.editor
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.current?.name ?? L.t("capture.name")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let item = model.current {
                        Text(L.f("library.sourceDate", L.translateSource(item.source), item.createdAt)).font(.system(size: 10)).foregroundStyle(theme.muted)
                    }
                }
                Spacer()
                Button(action: model.toggleFavorite) { Text(model.current?.favorite == true ? "★" : "☆").font(.system(size: 19)) }
                    .buttonStyle(QuietButtonStyle()).help(model.current?.favorite == true ? L.t("favorite.remove") : L.t("favorite.add"))
                Button(L.t("action.rename")) { model.sheet = .rename }.buttonStyle(QuietButtonStyle())
                Button(model.current?.isTrashed == true ? L.t("action.restore") : L.t("library.trash"), action: model.toggleTrash).buttonStyle(QuietButtonStyle())
                Button(L.t("action.home"), action: model.goHome).buttonStyle(QuietButtonStyle()).padding(.leading, 8)
            }
            .padding(.horizontal, 18).frame(height: 56).background(theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            HStack(spacing: 4) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    Button { editor.tool = tool } label: { Image(systemName: tool.symbol).font(.system(size: 15)).frame(width: 22, height: 20) }
                        .buttonStyle(ToolButtonStyle(active: editor.tool == tool))
                        .help(tool == .pixelate ? L.t("tool.redactHint") : "\(L.t(tool.labelKey)) (\(tool.key))")
                        .accessibilityLabel(L.t(tool.labelKey))
                }
                Spacer()
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.buttonStyle(SecondaryButtonStyle()).disabled(!editor.canUndo).help(L.t("edit.undo"))
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.buttonStyle(SecondaryButtonStyle()).disabled(!editor.canRedo).help(L.t("edit.redo"))
            }
            .padding(.horizontal, 12).frame(height: 52).background(theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            HStack(spacing: 0) {
                CanvasHost(editor: editor).accessibilityLabel(L.t("edit.canvas")).help(L.t("edit.canvasHint"))
                Rectangle().fill(theme.border).frame(width: 1)
                properties(editor).frame(width: 225).background(theme.surface)
            }
            HStack {
                Text(dimensions(editor)).font(.system(size: 11)).foregroundStyle(theme.muted)
                Spacer()
                Button("−") { editor.setZoom(editor.zoom / 1.25) }.buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 2, leading: 9, bottom: 2, trailing: 9)))
                Text("\(Int((editor.zoom * 100).rounded())) %").font(.system(size: 11)).frame(width: 62)
                Button("+") { editor.setZoom(editor.zoom * 1.25) }.buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 2, leading: 9, bottom: 2, trailing: 9)))
                Button(L.t("edit.fit")) { editor.fitImage() }.buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 2, leading: 11, bottom: 2, trailing: 11))).padding(.leading, 10)
            }
            .padding(.horizontal, 18).frame(height: 40).background(theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        }
        .onAppear { hex = editor.colorHex }
    }

    private func dimensions(_ editor: EditorController) -> String {
        guard editor.pixelSize.width > 0 else { return "" }
        let format = IntegerFormatStyle<Int>.number.locale(L.locale)
        return "\(Int(editor.pixelSize.width).formatted(format)) × \(Int(editor.pixelSize.height).formatted(format)) px · "
            + (editor.isDirty ? L.t("status.saving") : L.t("status.saved"))
    }

    @ViewBuilder
    private func properties(_ editor: EditorController) -> some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.t("edit.properties")).font(.system(size: 14, weight: .semibold))
                    Text(L.t(editor.tool.labelKey)).foregroundStyle(theme.muted).padding(.top, 6).padding(.bottom, 20)
                    if ![.select, .crop, .pixelate].contains(editor.tool) {
                        Text(L.t("edit.color")).font(.system(size: 12, weight: .semibold)).padding(.bottom, 10)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                            ForEach(Self.palette, id: \.self) { value in
                                Button {
                                    let text = String(format: "#%06X", value)
                                    _ = editor.setColor(text)
                                    hex = text
                                } label: {
                                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: value)).frame(width: 22, height: 18)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
                                }
                                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)))
                                .help(String(format: "#%06X", value))
                            }
                        }
                        TextField(L.t("edit.hex"), text: $hex)
                            .textFieldStyle(.roundedBorder).help(L.t("edit.hex")).accessibilityLabel(L.t("edit.hex"))
                            .onSubmit { applyHex(editor) }
                            .padding(.top, 11).padding(.bottom, 20)
                        if ![.text, .step].contains(editor.tool) {
                            HStack {
                                Text(L.t("edit.thickness")).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(Int(editor.stroke)) px").font(.system(size: 11)).foregroundStyle(theme.muted)
                            }
                            Slider(value: $editor.stroke, in: 1...20).padding(.top, 8).padding(.bottom, 20)
                                .accessibilityLabel(L.t("edit.stroke"))
                        }
                    }
                    if editor.tool == .text {
                        Text(L.t("edit.textPlace")).font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $editor.text).font(.system(size: 13)).frame(minHeight: 58, maxHeight: 120)
                            .scrollContentBackground(.hidden).padding(4)
                            .background(theme.chrome, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
                            .accessibilityLabel(L.t("edit.annotation")).padding(.top, 10).padding(.bottom, 12)
                        Text(L.t("edit.textSize")).font(.system(size: 12))
                        Slider(value: $editor.fontSize, in: 12...80).padding(.top, 8).padding(.bottom, 20)
                            .accessibilityLabel(L.t("edit.textSize"))
                    }
                    Text(L.t(editor.tool.hintKey)).font(.system(size: 11)).foregroundStyle(theme.muted).lineSpacing(3)
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.chrome, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(.horizontal, 18).padding(.vertical, 20)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.saveCurrent(announce: true) } label: { Text(L.t("action.save")).frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5)))
                        .disabled(!editor.isDirty).help(L.t("edit.saveHint"))
                    Button(action: model.copyImage) { Text(L.t("action.copy")).frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5)))
                        .help(L.t("edit.copyHint"))
                }
                .font(.system(size: 11))
                Button(action: model.exportImage) { Text(L.t("action.export")).frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle()).help(L.t("edit.exportHint"))
                Button(action: model.restoreOriginal) { Text(L.t("edit.original")).font(.system(size: 11)) }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        }
    }

    private func applyHex(_ editor: EditorController) {
        if !editor.setColor(hex) {
            hex = editor.colorHex
            model.setStatus(L.t("color.hint"))
        } else {
            hex = editor.colorHex
        }
    }
}

private struct ToolButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? theme.accent : theme.text)
            .padding(6)
            .background(active ? theme.accentSoft : configuration.isPressed ? theme.hover : theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? theme.accent : theme.border))
            .contentShape(Rectangle())
    }
}

// MARK: - Recording workspace

private struct RecorderView: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L.t("record.title")).font(.system(size: 27, weight: .semibold))
                Text(L.t("record.subtitle")).font(.system(size: 14)).foregroundStyle(theme.muted).padding(.top, 10).padding(.bottom, 28)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: "record.circle").font(.system(size: 28)).foregroundStyle(Theme.red)
                            .frame(width: 64, height: 64).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.recordingStateText).font(.system(size: 20, weight: .semibold))
                            Text(AppModel.clock(model.recordingElapsed, hours: true)).font(.system(size: 29, design: .monospaced)).foregroundStyle(theme.muted)
                        }
                    }
                    .padding(.bottom, 24)
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L.t("record.primary")).font(.system(size: 14, weight: .semibold))
                            Text(L.t("record.visibleHint")).font(.system(size: 12)).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        Text(L.t("record.format")).font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                    .padding(16).background(theme.chrome, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 18)
                    Toggle(L.t("record.audio"), isOn: Binding(get: { model.store.settings.systemAudio }, set: { model.setSystemAudio($0) }))
                        .toggleStyle(.checkbox).help(L.t("record.audioHint"))
                        .disabled(model.recording || model.busy || model.stoppingRecording).padding(.bottom, 17)
                    Text(model.recordingHelpText).font(.system(size: 12)).foregroundStyle(theme.muted).lineSpacing(4).padding(.bottom, 24)
                    HStack(spacing: 10) {
                        Button { Task { await model.startRecording() } } label: {
                            HStack(spacing: 10) { Circle().fill(.white).frame(width: 8, height: 8); Text(L.t("record.start")).fontWeight(.semibold) }
                                .padding(.horizontal, 4).padding(.vertical, 2)
                        }
                        .buttonStyle(PrimaryButtonStyle(color: Theme.red))
                        .disabled(model.recording || model.busy || model.stoppingRecording)
                        .opacity(model.recording || model.busy || model.stoppingRecording ? 0.5 : 1)
                        .accessibilityLabel(L.t("record.startName"))
                        Button(L.t("record.stopSave"), action: model.stopRecording).buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.recording || model.stoppingRecording)
                    }
                    .padding(.bottom, 10)
                    Text(L.t("record.shortcut")).font(.system(size: 11)).foregroundStyle(theme.muted).padding(.top, 5)
                }
                .padding(28)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border))
                Button(L.t("record.show"), action: model.showRecordings).buttonStyle(SecondaryButtonStyle()).padding(.top, 20)
            }
            .frame(maxWidth: 850, alignment: .leading)
            .padding(.horizontal, 38).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Video

private struct PlayerHost: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

private struct VideoView: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.current?.name ?? "").font(.system(size: 23, weight: .semibold))
            if let item = model.current {
                Text(L.f("video.info", item.durationSeconds, item.createdAt)).foregroundStyle(theme.muted).padding(.top, 8).padding(.bottom, 20)
            }
            PlayerHost(player: model.player).background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button(action: model.togglePlay) { Text(L.t("video.play")) }.buttonStyle(PrimaryButtonStyle())
                Button(L.t("video.open"), action: model.openVideo).buttonStyle(SecondaryButtonStyle())
                Button(L.t("video.export"), action: model.exportVideo).buttonStyle(SecondaryButtonStyle())
                Button(L.t("action.rename")) { model.sheet = .rename }.buttonStyle(SecondaryButtonStyle())
                Button(L.t("video.favorite"), action: model.toggleFavorite).buttonStyle(SecondaryButtonStyle())
                Button(L.t("video.trash"), action: model.toggleTrash).buttonStyle(SecondaryButtonStyle())
                Button(L.t("action.home"), action: model.goHome).buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 20)
        }
        .padding(38)
    }
}
