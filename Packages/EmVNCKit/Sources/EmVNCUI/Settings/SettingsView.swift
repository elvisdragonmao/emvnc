import EmVNCCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.showUnencryptedWarningKey) private var showUnencryptedWarning = true
    @AppStorage(AppSettings.defaultScalingKey) private var defaultScaling: ScalingMode = .fit
    @AppStorage(AppSettings.defaultKeyboardProfileKey) private var defaultKeyboardProfile: KeyboardProfile = .mac
    @AppStorage(AppSettings.defaultClipboardSyncKey) private var defaultClipboardSync = true
    @AppStorage(AppSettings.defaultAutoScreenshotKey) private var defaultAutoScreenshot = true

    var body: some View {
        Form {
            Section("Security") {
                Toggle("Warn when a session is not encrypted", isOn: $showUnencryptedWarning)
                Text("VNC Password, Apple Remote Desktop, UltraVNC MS-Logon II and “No Authentication” sessions send the screen and keystrokes unencrypted. RSA-AES encrypts the whole session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("New Connections") {
                Picker("Scaling", selection: $defaultScaling) {
                    ForEach(ScalingMode.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Keyboard", selection: $defaultKeyboardProfile) {
                    ForEach(KeyboardProfile.allCases.filter { $0 != .custom }) { Text($0.displayName).tag($0) }
                }
                Toggle("Share clipboard text", isOn: $defaultClipboardSync)
                Toggle("Capture thumbnails automatically", isOn: $defaultAutoScreenshot)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
    }
}

private struct DataSettingsView: View {
    @Environment(AppModel.self) private var appModel
    private let screenshotsQuery = Query<ScreenshotRecord, [ScreenshotRecord]>()
    private var screenshots: [ScreenshotRecord] { screenshotsQuery.wrappedValue }
    @ViewState private var confirmDelete = false

    var body: some View {
        Form {
            Section("Screenshots") {
                LabeledContent("Stored screenshots", value: "\(screenshots.count)")
                HStack {
                    Button("Show in Finder") {
                        let folder = appModel.screenshotStore.directory
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                    Spacer()
                    Button("Delete All Screenshots…", role: .destructive) { confirmDelete = true }
                        .disabled(screenshots.isEmpty)
                }
            }

            Section("Storage") {
                LabeledContent("Connections & history") {
                    Text(AppPaths.storeURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("Passwords") {
                    Text("macOS Keychain (login), service “\(KeychainCredentialStore.defaultService)”")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical)
        .confirmationDialog("Delete all screenshots?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                let context = appModel.context
                let connectionIDs = Set(screenshots.map(\.connectionID))

                for id in connectionIDs {
                    appModel.screenshotStore.deleteAll(for: id, in: context)
                    context.connection(withID: id)?.lastScreenshotFileName = nil
                }

                try? context.save()
            }
        } message: {
            Text("Connection thumbnails will be empty until the next connection.")
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String

        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("emvnc").font(.title2.weight(.semibold))
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("Open-source VNC viewer for macOS. Licensed under the Apache License 2.0.")
                }

                Divider()

                Text("Acknowledgements").font(.headline)

                notice("RoyalVNCKit", "Copyright © 2025 Royal Apps. MIT License. emvnc uses a patched fork; see Packages/RoyalVNCKit/PATCHES.md.")
                notice("CryptoSwift", "Copyright © 2014-3099 Marcin Krzyżanowski. This product includes software developed by the \"Marcin Krzyzanowski\" (http://krzyzanowskim.com/).")
                notice("D3DES", "D3DES (V5.09) by Richard Outerbridge, public domain; VNC changes Copyright © 1998 Olivetti & Oracle Research Laboratory.")
                notice("zlib", "Provided by macOS.")

                Text("Full license texts are in THIRD_PARTY_NOTICES.md in the source repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .textSelection(.enabled)
        }
        .frame(height: 360)
    }

    private func notice(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
