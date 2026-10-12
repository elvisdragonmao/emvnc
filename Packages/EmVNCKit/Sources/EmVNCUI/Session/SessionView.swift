import AppKit
import EmVNCCore
import SwiftUI

struct SessionView: View {
    @Bindable var session: SessionController
    let remoteScreen: RemoteScreenView
    let onToggleFullScreen: () -> Void

    @Environment(AppModel.self) private var appModel
    @AppStorage(AppSettings.showUnencryptedWarningKey) private var showUnencryptedWarning = true
    @ViewState private var warningDismissed = false
    @ViewState private var showingInfo = false
    @ViewState private var toast: String?

    var body: some View {
        RemoteScreenRepresentable(view: remoteScreen)
            .overlay { stateOverlay }
            .overlay(alignment: .top) { banner }
            .overlay(alignment: .bottom) { toastView }
            .toolbar { toolbarContent }
            .navigationTitle(session.displayName)
            .navigationSubtitle(subtitle)
            .sheet(item: $session.credentialPrompt) { prompt in
                CredentialPromptView(prompt: prompt,
                                     connectionName: session.displayName,
                                     onSubmit: { username, password, remember in
                                         session.submitCredentials(username: username, password: password, remember: remember)
                                         refocus()
                                     },
                                     onCancel: {
                                         session.cancelCredentials()
                                     })
            }
            .sheet(item: $session.trustPrompt) { prompt in
                TrustPromptView(prompt: prompt,
                                host: session.target.host,
                                onDecision: { trusted in
                                    session.resolveTrust(trusted)
                                    refocus()
                                })
            }
            .onChange(of: session.notice?.date) { _, _ in
                if let notice = session.notice {
                    showToast(notice.message)
                }
            }
            .onChange(of: session.phase) { _, phase in
                if phase.isConnected {
                    warningDismissed = false
                    refocus()
                } else if remoteScreen.window?.firstResponder === remoteScreen.framebufferView {
                    // Hand keyboard focus to the window so the overlay's default/cancel buttons work
                    remoteScreen.window?.makeFirstResponder(nil)
                }
            }
            .frame(minWidth: 480, minHeight: 300)
    }

    private var subtitle: String {
        let address = HostAddress.display(host: session.target.host, port: session.target.port)

        switch session.phase {
            case .connected:
                let resolution = session.framebufferSize.map { "\(Int($0.width))×\(Int($0.height))" }
                let parts = [ session.displayName == address ? nil : address, resolution ].compactMap { $0 }

                return parts.joined(separator: " — ")
            case .connecting: return "Connecting to \(address)…"
            case .reconnecting: return "Reconnecting…"
            case .failed: return "Not connected"
            case .disconnected: return "Disconnected"
            case .idle: return address
        }
    }

    private func refocus() {
        DispatchQueue.main.async {
            remoteScreen.window?.makeFirstResponder(remoteScreen.framebufferView)
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showingInfo.toggle()
            } label: {
                SecurityBadge(isConnected: session.phase.isConnected, isEncrypted: session.securityInfo.isEncrypted)
            }
            .help(session.securityInfo.isEncrypted ? "Encrypted session — show details" : "Session details")
            .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                SessionInfoView(session: session)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Scaling", selection: scalingBinding) {
                Label("Fit to Window", systemImage: "arrow.down.right.and.arrow.up.left").tag(ScalingMode.fit)
                Label("Actual Size", systemImage: "1.magnifyingglass").tag(ScalingMode.actualSize)
            }
            .pickerStyle(.segmented)
            .help("Fit to window or show at actual size")

            Button {
                takeScreenshot()
            } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .disabled(!session.phase.isConnected)
            .help("Save a screenshot of the remote screen")

            Toggle(isOn: $session.preferences.clipboardSync) {
                Label("Clipboard Sharing", systemImage: session.preferences.clipboardSync ? "doc.on.clipboard.fill" : "doc.on.clipboard")
            }
            .help(session.preferences.clipboardSync ? "Clipboard sharing is on" : "Clipboard sharing is off")

            KeyboardMenu(session: session)

            Button(action: onToggleFullScreen) {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Enter or exit full screen")

            if session.phase.isConnected || session.phase == .connecting {
                Button {
                    session.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
                .help("Disconnect")
            } else {
                Button {
                    session.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .help("Reconnect")
            }
        }
    }

    private var scalingBinding: Binding<ScalingMode> {
        Binding(
            get: { session.preferences.scalingMode },
            set: { mode in
                session.preferences.scalingMode = mode
                remoteScreen.scalingMode = mode
            }
        )
    }

    private func takeScreenshot() {
        session.captureScreenshot(isAutomatic: false)
    }

    // MARK: Overlays
    @ViewBuilder
    private var stateOverlay: some View {
        switch session.phase {
            case .idle, .connected:
                EmptyView()
            case .connecting:
                StatusPanel {
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(session.displayName)…").font(.headline)
                    Text(HostAddress.display(host: session.target.host, port: session.target.port))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { session.disconnect() }
                        .keyboardShortcut(.cancelAction)
                }
            case .reconnecting(let attempt, let maxAttempts, let seconds):
                StatusPanel {
                    ProgressView().controlSize(.large)
                    Text("Connection lost").font(.headline)
                    if let message = session.statusMessage {
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Text("Reconnecting in \(seconds) s (attempt \(attempt) of \(maxAttempts))")
                        .monospacedDigit()
                    HStack {
                        Button("Cancel") { session.disconnect() }
                            .keyboardShortcut(.cancelAction)
                        Button("Reconnect Now") { session.reconnect() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .failed(let error):
                StatusPanel {
                    Image(systemName: error.kind == .authenticationFailed ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    Text(failureTitle(for: error)).font(.headline)
                    Text(error.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let hint = failureHint(for: error) {
                        Text(hint).font(.callout).multilineTextAlignment(.center)
                    }
                    HStack {
                        if let id = session.connectionID {
                            Button("Edit Connection…") { appModel.requestEdit(connectionID: id) }
                        }
                        Button(error.kind == .authenticationFailed ? "Try Again…" : "Try Again") { session.reconnect() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .disconnected:
                StatusPanel {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Disconnected").font(.headline)
                    if let message = session.statusMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button("Reconnect") { session.reconnect() }
                        .keyboardShortcut(.defaultAction)
                }
        }
    }

    private func failureTitle(for error: EngineError) -> String {
        switch error.kind {
            case .authenticationFailed: "Authentication failed"
            case .cancelledByUser: "Connection cancelled"
            case .unsupportedSecurity: "Unsupported security type"
            case .network: "Couldn't connect"
            case .protocolError: "Protocol error"
        }
    }

    private func failureHint(for error: EngineError) -> String? {
        switch error.kind {
            case .unsupportedSecurity:
                if session.securityInfo.offeredMethods.contains("VeNCrypt") {
                    return "emvnc supports None, VNC Password, Apple Remote Desktop, UltraVNC MS-Logon II and RSA-AES. VeNCrypt (TLS) is not supported. Enable one of the supported methods on the server, or choose “Automatic”."
                }

                return "Choose “Automatic” or another authentication method in the connection settings."
            case .authenticationFailed:
                return "Check the username and password. Try Again asks for new credentials."
            default:
                return nil
        }
    }

    @ViewBuilder
    private var banner: some View {
        if session.phase.isConnected, !session.securityInfo.isEncrypted, showUnencryptedWarning, !warningDismissed {
            HStack(spacing: 10) {
                Image(systemName: "lock.open.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This session is not encrypted").font(.callout.weight(.semibold))
                    Text("Screen contents and keystrokes travel over the network in the clear. Use RSA-AES, a VPN or an SSH tunnel on untrusted networks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation { warningDismissed = true }
                    refocus()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss warning")
            }
            .padding(10)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }
}

struct RemoteScreenRepresentable: NSViewRepresentable {
    let view: RemoteScreenView

    func makeNSView(context: Context) -> RemoteScreenView { view }
    func updateNSView(_ nsView: RemoteScreenView, context: Context) {}
}

private struct StatusPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) {
                content
            }
            .padding(24)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
        }
    }
}

struct SecurityBadge: View {
    let isConnected: Bool
    let isEncrypted: Bool

    var body: some View {
        if !isConnected {
            Label("Not connected", systemImage: "network.slash")
        } else if isEncrypted {
            Label("Encrypted", systemImage: "lock.fill")
                .foregroundStyle(.green)
        } else {
            Label("Not encrypted", systemImage: "lock.open.fill")
                .foregroundStyle(.orange)
        }
    }
}

private struct SessionInfoView: View {
    let session: SessionController

    var body: some View {
        let info = session.securityInfo

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Address", HostAddress.display(host: session.target.host, port: session.target.port))
            row("Authentication", info.negotiatedMethod ?? "—")
            row("Encryption", info.isEncrypted ? "Encrypted (AES-EAX)" : "Not encrypted")
            if !info.offeredMethods.isEmpty {
                row("Server offers", info.offeredMethods.joined(separator: ", "))
            }
            if let name = info.desktopName, !name.isEmpty {
                row("Desktop", name)
            }
            if let size = session.framebufferSize {
                row("Resolution", "\(Int(size.width)) × \(Int(size.height))")
            }
            row("Clipboard", info.usesExtendedClipboard ? "Extended (UTF-8)" : "Standard")
            if let fingerprint = info.serverKeyFingerprint {
                row("Server key", fingerprint)
                    .font(.caption.monospaced())
            }
        }
        .textSelection(.enabled)
        .padding()
        .frame(width: 420)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct KeyboardMenu: View {
    @Bindable var session: SessionController

    var body: some View {
        Menu {
            Picker("Keyboard Mapping", selection: $session.preferences.keyboardProfile) {
                ForEach(KeyboardProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }

            Toggle("Send ⌘ Shortcuts to Remote", isOn: $session.preferences.shortcutPassthrough)

            Divider()

            Section("Send Keys") {
                ForEach(SpecialKeyCombination.pcCombinations) { combination in
                    Button(combination.title) { session.sendCombination(combination) }
                }
                Divider()
                ForEach(SpecialKeyCombination.macCombinations) { combination in
                    Button(combination.title) { session.sendCombination(combination) }
                }
            }
            .disabled(!session.phase.isConnected)
        } label: {
            Label("Keyboard", systemImage: "keyboard")
        }
        .help("Keyboard mapping and special keys")
    }
}
