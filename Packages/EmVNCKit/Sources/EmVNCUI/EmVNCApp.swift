import AppKit
import EmVNCCore
import SwiftData
import SwiftUI

/// The application. Lives in a library so both the Xcode app target and the SwiftPM launcher can start it
/// with `EmVNCApp.main()`.
public struct EmVNCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var appModel: AppModel
    private let storeError: String?

    public init() {
        let container: ModelContainer
        var storeError: String?

        do {
            container = try Persistence.makeContainer()
        } catch {
            // Keep the app usable; tell the user their saved connections could not be opened
            storeError = error.localizedDescription
            container = try! Persistence.makeContainer(inMemory: true)
        }

        let model = AppModel(container: container)
        _appModel = ViewState(initialValue: model)
        self.storeError = storeError
        AppDelegate.appModel = model
    }

    public var body: some Scene {
        Window("emvnc", id: MainView.windowID) {
            MainView(storeError: storeError)
                .environment(appModel)
                .modelContainer(appModel.container)
        }
        .defaultSize(width: 1000, height: 660)
        .commands {
            AppCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .modelContainer(appModel.container)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run emvnc`); a no-op inside the .app bundle
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Close sessions so they disconnect cleanly and refresh their thumbnails
            for window in NSApp.windows where window.windowController is SessionWindowController {
                window.close()
            }
        }
    }
}

struct AppCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                openWindow(id: MainView.windowID)
                appModel.requestNewConnection()
            }
            .keyboardShortcut("n")

            Button("Quick Connect…") {
                openWindow(id: MainView.windowID)
                appModel.requestQuickConnect()
            }
            .keyboardShortcut("k")
        }

        CommandMenu("Session") {
            let session = appModel.activeSession
            let isConnected = session?.phase.isConnected ?? false

            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("w", modifiers: [ .command, .option ])
                .disabled(!isConnected)

            Button("Reconnect") { session?.reconnect() }
                .keyboardShortcut("r", modifiers: [ .command, .option ])
                .disabled(session == nil)

            Divider()

            Button("Take Screenshot") { _ = session?.captureScreenshot(isAutomatic: false) }
                .keyboardShortcut("s", modifiers: [ .command, .option ])
                .disabled(!isConnected)

            Divider()

            Toggle("Fit to Window", isOn: Binding(
                get: { session?.preferences.scalingMode == .fit },
                set: { if $0 { appModel.setScaling(.fit) } }
            ))
            .keyboardShortcut("1", modifiers: [ .command, .option ])
            .disabled(session == nil)

            Toggle("Actual Size", isOn: Binding(
                get: { session?.preferences.scalingMode == .actualSize },
                set: { if $0 { appModel.setScaling(.actualSize) } }
            ))
            .keyboardShortcut("0", modifiers: [ .command, .option ])
            .disabled(session == nil)

            Button("Enter Full Screen") { appModel.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [ .command, .control ])
                .disabled(session == nil)

            Divider()

            Toggle("Share Clipboard", isOn: Binding(
                get: { session?.preferences.clipboardSync ?? false },
                set: { session?.preferences.clipboardSync = $0 }
            ))
            .disabled(session == nil)

            Toggle("Send ⌘ Shortcuts to Remote", isOn: Binding(
                get: { session?.preferences.shortcutPassthrough ?? false },
                set: { session?.preferences.shortcutPassthrough = $0 }
            ))
            .keyboardShortcut("k", modifiers: [ .command, .option, .control ])
            .disabled(session == nil)

            Picker("Keyboard Mapping", selection: Binding(
                get: { session?.preferences.keyboardProfile ?? .mac },
                set: { session?.preferences.keyboardProfile = $0 }
            )) {
                ForEach(KeyboardProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .disabled(session == nil)

            Menu("Send Keys") {
                ForEach(SpecialKeyCombination.pcCombinations + SpecialKeyCombination.macCombinations) { combination in
                    Button(combination.title) { session?.sendCombination(combination) }
                }
            }
            .disabled(!isConnected)
        }
    }
}
