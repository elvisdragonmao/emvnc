import EmVNCCore
import SwiftData
import SwiftUI

/// Create or edit a saved connection. The password goes straight to the Keychain on save and is never
/// written to SwiftData.
struct ConnectionEditorView: View {
    let request: EditorRequest

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var portText = String(HostAddress.defaultPort)
    @ViewState private var method: AuthenticationMethod = .automatic
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var rememberPassword = true
    @ViewState private var hasSavedPassword = false
    @ViewState private var isChangingPassword = false
    @ViewState private var removeSavedPassword = false
    @ViewState private var preferences = ConnectionPreferences.default
    @ViewState private var errorMessage: String?
    @ViewState private var loaded = false

    private var existing: SavedConnection? {
        if case .edit(let id) = request {
            return appModel.context.connection(withID: id)
        }

        return nil
    }

    private var parsedAddress: HostAddress.Parsed? {
        HostAddress.parse(address)
    }

    private var port: Int? {
        if let embedded = parsedAddress?.port {
            return embedded
        }

        return Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { HostAddress.isValidPort($0) ? $0 : nil }
    }

    private var isValid: Bool {
        parsedAddress != nil && port != nil && (!method.requiresUsername || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(parsedAddress?.host ?? "Office Mac"))
                    TextField("Address", text: $address, prompt: Text("hostname, 192.168.1.20 or fe80::1"))
                        .textContentType(.URL)
                    if parsedAddress?.port == nil {
                        TextField("Port", text: $portText, prompt: Text("5900"))
                    } else {
                        LabeledContent("Port", value: String(parsedAddress?.port ?? HostAddress.defaultPort))
                    }
                    if !address.isEmpty, parsedAddress == nil {
                        Text("Enter a host name, an IPv4 address, or an IPv6 address (use [addr]:port to include a port).")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Computer")
                }

                Section {
                    Picker("Method", selection: $method) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    Text(method.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if method.usesUsername {
                        TextField(method.requiresUsername ? "Username" : "Username (if required)", text: $username)
                    }

                    if method.usesPassword {
                        passwordFields
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    if !isEncryptedMethod {
                        Label("Unless the server negotiates RSA-AES, this session is not encrypted.", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Display") {
                    Picker("Scaling", selection: $preferences.scalingMode) {
                        ForEach(ScalingMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Colors", selection: $preferences.colorDepth) {
                        ForEach(ColorDepth.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Share the session with other viewers", isOn: $preferences.isShared)
                }

                Section("Keyboard") {
                    Picker("Remote Computer", selection: $preferences.keyboardProfile) {
                        ForEach(KeyboardProfile.allCases) { Text($0.displayName).tag($0) }
                    }
                    if preferences.keyboardProfile == .custom {
                        Picker("⌘ Command sends", selection: $preferences.customKeyboardMapping.command) {
                            ForEach(RemoteModifier.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("⌥ Option sends", selection: $preferences.customKeyboardMapping.option) {
                            ForEach(RemoteModifier.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("⌃ Control sends", selection: $preferences.customKeyboardMapping.control) {
                            ForEach(RemoteModifier.allCases) { Text($0.displayName).tag($0) }
                        }
                    } else {
                        Text(preferences.keyboardProfile.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Send ⌘Q, ⌘H, ⌘M and other Mac shortcuts to the remote computer", isOn: $preferences.shortcutPassthrough)
                }

                Section("Clipboard & Screenshots") {
                    Toggle("Share clipboard text", isOn: $preferences.clipboardSync)
                    Toggle("Capture a thumbnail after connecting", isOn: $preferences.autoScreenshot)
                    Toggle("Refresh the thumbnail when disconnecting", isOn: $preferences.refreshScreenshotOnDisconnect)
                        .disabled(!preferences.autoScreenshot)
                    Toggle("Keep screenshot history", isOn: $preferences.keepScreenshotHistory)
                }

                Section("Reconnect") {
                    Toggle("Reconnect automatically when the connection drops", isOn: $preferences.autoReconnect)
                    Stepper("Up to \(preferences.maxReconnectAttempts) attempts",
                            value: $preferences.maxReconnectAttempts,
                            in: 1...20)
                        .disabled(!preferences.autoReconnect)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 540, minHeight: 420, idealHeight: 580)
        .onAppear(perform: load)
    }

    private var isEncryptedMethod: Bool {
        method == .rsaAES || method == .automatic
    }

    @ViewBuilder
    private var passwordFields: some View {
        if hasSavedPassword && !isChangingPassword && !removeSavedPassword {
            LabeledContent("Password") {
                HStack {
                    Label("Saved in Keychain", systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { isChangingPassword = true }
                    Button("Remove", role: .destructive) { removeSavedPassword = true }
                }
            }
        } else {
            SecureField("Password", text: $password, prompt: Text(removeSavedPassword ? "Will be removed — or enter a new one" : "Optional"))
            Toggle("Remember password in Keychain", isOn: $rememberPassword)
            if !rememberPassword || password.isEmpty {
                Text("You will be asked for the password when connecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hasSavedPassword {
                Button(removeSavedPassword ? "Keep Saved Password" : "Cancel Change") {
                    removeSavedPassword = false
                    isChangingPassword = false
                    password = ""
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }

        loaded = true

        guard let connection = existing else {
            preferences = AppSettings.newConnectionPreferences()
            return
        }

        name = connection.name
        address = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        portText = String(connection.port)
        method = connection.authenticationMethod
        username = connection.username
        hasSavedPassword = connection.hasSavedPassword
        preferences = connection.preferences
    }

    private func save() {
        guard let parsed = parsedAddress, let port else { return }

        let context = appModel.context
        let connection: SavedConnection
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        if let existing {
            connection = existing

            // A different server means a different key; forget the pinned one
            if existing.host != parsed.host || existing.port != port {
                existing.trustedServerKeyFingerprint = nil
            }
        } else {
            connection = SavedConnection(name: "", host: parsed.host)
            context.insert(connection)
        }

        connection.name = trimmedName.isEmpty ? parsed.host : trimmedName
        connection.host = parsed.host
        connection.port = port
        connection.authenticationMethod = method
        connection.username = method.usesUsername ? username.trimmingCharacters(in: .whitespaces) : ""
        connection.preferences = preferences

        do {
            if !method.usesPassword || (removeSavedPassword && password.isEmpty) {
                try CredentialManager.removePassword(for: connection, in: appModel.credentialStore)
            } else if !password.isEmpty {
                if rememberPassword {
                    try CredentialManager.savePassword(password, for: connection, in: appModel.credentialStore)
                } else {
                    try CredentialManager.removePassword(for: connection, in: appModel.credentialStore)
                }
            }

            password = ""
            try context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
