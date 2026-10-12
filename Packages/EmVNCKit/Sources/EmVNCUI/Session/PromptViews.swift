import EmVNCCore
import SwiftUI

/// Asks for the credentials the negotiated security type needs. The password is handed straight to the
/// session and is not kept in view state after the sheet closes.
struct CredentialPromptView: View {
    let prompt: CredentialPrompt
    let connectionName: String
    let onSubmit: (_ username: String, _ password: String, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var remember = true
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    private var needsUsername: Bool { prompt.request.kind == .usernameAndPassword }

    private var canSubmit: Bool {
        !password.isEmpty && (!needsUsername || !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to “\(connectionName)”").font(.headline)
                    Text("The server requires \(needsUsername ? "a username and password" : "a password") (\(prompt.request.methodName)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let message = prompt.message {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            Form {
                if needsUsername {
                    TextField("Username", text: $username)
                        .focused($focusedField, equals: .username)
                }
                SecureField("Password", text: $password)
                    .focused($focusedField, equals: .password)
                if prompt.canRemember {
                    Toggle("Remember password in Keychain", isOn: $remember)
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    password = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    let submitted = password
                    password = ""
                    onSubmit(username.trimmingCharacters(in: .whitespaces), submitted, prompt.canRemember && remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            username = prompt.username
            remember = prompt.rememberByDefault
            focusedField = needsUsername && username.isEmpty ? .username : .password
        }
    }
}

struct TrustPromptView: View {
    let prompt: TrustPrompt
    let host: String
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The identity of “\(host)” has changed").font(.headline)
                    Text("The server presented a different encryption key than last time. This happens when the server is reinstalled or its key is regenerated — or when someone intercepts the connection. Continue only if you expected this change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Previous key").font(.caption).foregroundStyle(.secondary)
                Text(prompt.previousFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("New key").font(.caption).foregroundStyle(.secondary)
                Text(prompt.newFingerprint).font(.caption.monospaced()).textSelection(.enabled)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Trust New Key") { onDecision(true) }
                Button("Cancel Connection", role: .cancel) { onDecision(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
