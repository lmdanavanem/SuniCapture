import SwiftUI

/// Header with icon and close button, scrolling body, fixed footer — the SuniPDF dialog layout.
private struct ShellDialog<Content: View, Footer: View>: View {
    let titleKey: String
    let symbol: String
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                Text(L.t(titleKey)).font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Text("×").font(.system(size: 22)).frame(width: 24, height: 24) }
                    .buttonStyle(QuietButtonStyle()).help(L.t("action.close")).accessibilityLabel(L.t("action.close"))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(theme.chrome)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { footer }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(theme.chrome)
                .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        }
        .frame(width: width, height: min(height, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        .background(theme.surface)
    }
}

private struct SectionTitle: View {
    let key: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(L.t(key)).font(.system(size: 17, weight: .semibold))
            .padding(.top, 16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            .padding(.top, 20).padding(.bottom, 10)
    }
}

private struct Muted: View {
    let text: String
    var size: CGFloat = 13
    @Environment(\.theme) private var theme
    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(theme.muted).lineSpacing(size * 0.4).fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutDialog: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShellDialog(titleKey: "about.title", symbol: "info.circle", width: 700, height: 820) {
            VStack(spacing: 0) {
                Image(nsImage: Brand.logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 170, height: 152)
                Text(L.f("about.version", MacApp.version)).font(.system(size: 14))
                    .padding(.horizontal, 15).padding(.vertical, 5).background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 7).padding(.bottom, 14)
                Text(L.t("about.tagline")).font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                Muted(text: L.t("about.subtitle"), size: 14).multilineTextAlignment(.center).padding(.top, 10).padding(.bottom, 14)
                HStack(spacing: 8) {
                    badge("about.offline", "wifi.slash")
                    badge("about.telemetry", "eye.slash")
                    badge("about.account", "person.crop.circle.badge.xmark")
                }
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(theme.accent).frame(width: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("about.privacyTitle")).font(.system(size: 17, weight: .semibold))
                    Text(L.t("about.privacy")).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Muted(text: L.t("about.privacyNote"), size: 12)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border))
            SectionTitle(key: "about.storage")
            Muted(text: L.t("about.storageHint"))
            Text(model.store.root.path).font(.system(size: 12)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.chrome, in: RoundedRectangle(cornerRadius: 6)).padding(.vertical, 10)
                .accessibilityLabel(L.t("about.storage"))
            Button(L.t("action.openFolder"), action: model.openFolder).buttonStyle(SecondaryButtonStyle())
            SectionTitle(key: "settings.personalization")
            HStack {
                Text(L.f("about.preferences", L.language == "en" ? "English" : "Français",
                         L.t(model.store.settings.darkMode ? "theme.darkName" : "theme.lightName")))
                Spacer()
                Button(L.t("settings.open")) { model.sheet = .settings }.buttonStyle(SecondaryButtonStyle())
            }
            SectionTitle(key: "about.updates")
            Text(L.t("about.updateStatus")).font(.system(size: 13))
            Muted(text: L.t("about.updateHint"), size: 12).padding(.top, 7)
            SectionTitle(key: "about.credits")
            Text(L.t("about.developer")).font(.system(size: 13, weight: .semibold))
            Muted(text: L.t("about.engine"), size: 12).padding(.top, 6).padding(.bottom, 10)
            Button(L.t("about.licenses"), action: model.openLicenses).buttonStyle(SecondaryButtonStyle())
        } footer: {
            Button(L.t("help.open")) { model.sheet = .help }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button { dismiss() } label: { Text(L.t("action.close")).frame(minWidth: 80) }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            Button("", action: { dismiss() }).keyboardShortcut(.cancelAction).hidden().frame(width: 0)
        }
    }

    private func badge(_ key: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(theme.accent)
            Text(L.t(key)).font(.system(size: 13))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.accentSoft, in: Capsule())
        .overlay(Capsule().stroke(theme.border))
    }
}

struct SettingsDialog: View {
    let model: AppModel
    @State private var draft: AppSettings
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.store.settings)
    }

    var body: some View {
        ShellDialog(titleKey: "settings.title", symbol: "gearshape", width: 660, height: 720) {
            Text(L.t("settings.heading")).font(.system(size: 22, weight: .semibold))
            Muted(text: L.t("settings.immediate")).padding(.top, 8)
            SectionTitle(key: "settings.personalization")
            row("language.label") {
                Picker("", selection: $draft.language) { Text("Français").tag("fr"); Text("English").tag("en") }
                    .labelsHidden().frame(width: 185).accessibilityLabel(L.t("language.label"))
            }
            row("theme.label") {
                Picker("", selection: $draft.darkMode) { Text(L.t("theme.lightName")).tag(false); Text(L.t("theme.darkName")).tag(true) }
                    .labelsHidden().frame(width: 185).accessibilityLabel(L.t("theme.label"))
            }
            SectionTitle(key: "settings.capture")
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L.t("settings.copy"), isOn: $draft.copyAfterCapture)
                Toggle(L.t("settings.tray"), isOn: $draft.minimizeToTray)
                Toggle(L.t("settings.audio"), isOn: $draft.systemAudio)
            }
            .toggleStyle(.checkbox).padding(.vertical, 4)
            SectionTitle(key: "help.globalShortcuts")
            Muted(text: L.t("help.shortcutList"), size: 12)
            Muted(text: L.t("settings.storageHint"), size: 12).padding(.top, 18)
        } footer: {
            Button(L.t("action.cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            Spacer()
            Button(L.t("settings.save")) { if model.applySettings(draft) { dismiss() } }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ key: String, @ViewBuilder control: () -> some View) -> some View {
        HStack { Text(L.t(key)); Spacer(); control() }.padding(.vertical, 5)
    }
}

struct HelpDialog: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShellDialog(titleKey: "help.title", symbol: "questionmark.circle", width: 700, height: 760) {
            ForEach([("help.captureTitle", "help.captureBody"), ("help.editTitle", "help.editBody"),
                     ("help.videoTitle", "help.videoBody"), ("help.storageTitle", "help.storageBody")], id: \.0) { title, body in
                SectionTitle(key: title)
                Muted(text: L.t(body))
            }
            SectionTitle(key: "help.globalShortcuts")
            Text(L.t("help.shortcutList")).font(.system(size: 13)).lineSpacing(8)
            SectionTitle(key: "help.editorShortcuts")
            Muted(text: L.t("help.editorShortcutList"), size: 12)
        } footer: {
            Spacer()
            Button { dismiss() } label: { Text(L.t("action.close")).frame(minWidth: 80) }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            Button("", action: { dismiss() }).keyboardShortcut(.cancelAction).hidden().frame(width: 0)
        }
    }
}

struct RenameDialog: View {
    let model: AppModel
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _name = State(initialValue: model.current?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.t("rename.title")).font(.system(size: 17, weight: .semibold))
            TextField("", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                .onChange(of: name) { if name.count > 140 { name = String(name.prefix(140)) } }
                .onSubmit(save)
            HStack {
                Button(L.t("action.cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.t("rename.save"), action: save).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.rename(name)
        dismiss()
    }
}

struct WindowPickerDialog: View {
    let model: AppModel
    let windows: [WindowTarget]
    @State private var selection: CGWindowID?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, windows: [WindowTarget]) {
        self.model = model
        self.windows = windows
        _selection = State(initialValue: windows.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(L.t("capture.chooseWindow")).font(.system(size: 17, weight: .semibold))
            Text(L.t("capture.windowDescription")).fixedSize(horizontal: false, vertical: true)
            List(windows, selection: $selection) { window in
                Text(window.title).lineLimit(1).tag(window.id)
            }
            .contextMenu(forSelectionType: CGWindowID.self) { _ in } primaryAction: { _ in confirm() }
            .overlay { if windows.isEmpty { Text(L.t("mac.noWindows")).foregroundStyle(.secondary) } }
            HStack {
                Button(L.t("action.cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.t("capture.confirmWindow"), action: confirm).buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(22)
        .frame(width: 560, height: 440)
    }

    private func confirm() {
        guard let target = windows.first(where: { $0.id == selection }) else { return }
        model.captureWindow(target)
    }
}
