import AppKit
import EmVNCCore
import SwiftUI

/// One window per remote session. AppKit owns the window so the viewer gets precise control over focus
/// (key release on focus loss, clipboard scoping), full screen and closing; the content is SwiftUI.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let session: SessionController
    let remoteScreen: RemoteScreenView
    private weak var appModel: AppModel?
    private var hasSizedToRemote = false
    private var observation: NSObjectProtocol?

    init(session: SessionController, appModel: AppModel) {
        self.session = session
        self.appModel = appModel
        self.remoteScreen = RemoteScreenView(session: session)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [ .titled, .closable, .miniaturizable, .resizable ],
                              backing: .buffered,
                              defer: false)
        window.title = session.displayName
        window.subtitle = HostAddress.display(host: session.target.host, port: session.target.port)
        window.collectionBehavior = [ .fullScreenPrimary, .managed ]
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .line
        window.setFrameAutosaveName("EmVNCSession-\(session.connectionID?.uuidString ?? "quick")")

        super.init(window: window)

        session.renderer = remoteScreen.framebufferView
        remoteScreen.scalingMode = session.preferences.scalingMode

        let rootView = SessionView(session: session,
                                   remoteScreen: remoteScreen,
                                   onToggleFullScreen: { [weak window] in window?.toggleFullScreen(nil) })
            .environment(appModel)

        let hosting = NSHostingController(rootView: rootView)
        hosting.sceneBridgingOptions = [ .toolbars, .title ]
        // The window size follows the remote screen and the user, not SwiftUI's ideal content size
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // Installing the content view controller resizes the window to the hosting view's initial size
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.delegate = self

        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }

        observation = NotificationCenter.default.addObserver(forName: FramebufferView.framebufferSizeDidChange,
                                                             object: remoteScreen.framebufferView,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sizeWindowToRemoteIfNeeded()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    func showAndConnect() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusRemoteScreen()
        session.connect()
    }

    func focusRemoteScreen() {
        window?.makeFirstResponder(remoteScreen.framebufferView)
    }

    func setScalingMode(_ mode: ScalingMode) {
        session.preferences.scalingMode = mode
        remoteScreen.scalingMode = mode
    }

    /// On first connect, size a window that has no saved frame to the remote aspect ratio within the screen.
    private func sizeWindowToRemoteIfNeeded() {
        guard !hasSizedToRemote,
              let window,
              !window.styleMask.contains(.fullScreen),
              let size = session.framebufferSize,
              size.width > 0, size.height > 0,
              let screen = window.screen ?? NSScreen.main else {
            return
        }

        hasSizedToRemote = true

        // Respect a frame the user chose in an earlier session
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(window.frameAutosaveName)") != nil,
           window.frame.width != 1280 || window.frame.height != 800 {
            return
        }

        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maxContent = CGSize(width: visible.width, height: visible.height - chrome)
        let scale = min(1, maxContent.width / size.width, maxContent.height / size.height)
        let content = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: NSWindowDelegate
    func windowDidBecomeKey(_ notification: Notification) {
        session.windowDidBecomeKey()
        appModel?.sessionWindowDidBecomeKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        session.windowDidResignKey()
        appModel?.sessionWindowDidResignKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        session.close()
        appModel?.sessionWindowWillClose(self)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        focusRemoteScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        focusRemoteScreen()
    }
}
