import EmVNCCore
import SwiftUI

/// Connect to an address without creating a saved connection (unless "Save" is ticked).
struct QuickConnectView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @ViewState private var address = ""
    @ViewState private var method: AuthenticationMethod = .automatic
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var saveConnection = false
    @ViewState private var name = ""
    @FocusState private var addressFocused: Bool

    private var parsed: HostAddress.Parsed? {
        HostAddress.parse(address)
    }

    private var isValid: Bool {
        parsed != nil && (!method.requiresUsername || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Quick Connect", systemImage: "bolt.horizontal.fill")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Address", text: $address, prompt: Text("host, host:5901, 10.0.0.5 or [fe80::1]:5900"))
                    .focused($addressFocused)
                    .onSubmit(connect)
                Picker("Authentication", selection: $method) {
                    ForEach(AuthenticationMethod.allCases) { Text($0.displayName).tag($0) }
                }
                if method.usesUsername {
                    TextField(method.requiresUsername ? "Username" : "Username (if required)", text: $username)
                }
                if method.usesPassword {
                    SecureField("Password", text: $password, prompt: Text("Asked when needed if left empty"))
                }
                Toggle("Save to connections", isOn: $saveConnection)
                if saveConnection {
                    TextField("Name", text: $name, prompt: Text(parsed?.host ?? "Name"))
                }
            }
            .formStyle(.columns)

            if !address.isEmpty, parsed == nil {
                Text("That doesn't look like a valid address.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text(saveConnection ? "The password is saved in your Keychain." : "Nothing is saved. The password is used once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { addressFocused = true }
    }

    private func connect() {
        guard isValid, let parsed else { return }

        let target = ConnectionTarget(host: parsed.host,
                                      port: parsed.port ?? HostAddress.defaultPort,
                                      authenticationMethod: method)

        appModel.quickConnect(QuickConnectRequest(target: target,
                                                  username: username.trimmingCharacters(in: .whitespaces),
                                                  password: password,
                                                  saveConnection: saveConnection,
                                                  name: name.trimmingCharacters(in: .whitespaces)))
        password = ""
        dismiss()
    }
}
