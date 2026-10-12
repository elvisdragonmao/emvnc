// vncprobe — headless integration harness for emvnc's VNC engine.
//
// Connects with the same engine the app uses, authenticates, waits for a rendered framebuffer, optionally
// exercises input and clipboard, writes a PNG of the remote framebuffer, and exits non-zero on failure.
//
//   VNC_PASSWORD=secret vncprobe --host 10.0.0.2 --port 5900 --auth rsaAES --user me --screenshot out.png
//
// The password is read from the VNC_PASSWORD environment variable so it never appears in `ps` output.

import AppKit
import EmVNCCore
import Foundation

struct Options {
    var host = ""
    var port = HostAddress.defaultPort
    var auth = AuthenticationMethod.automatic
    var username = ""
    var screenshot: String?
    var timeout: TimeInterval = 20
    var typeText: String?
    var sendClipboard: String?
    var expectClipboard = false
    var holdSeconds: TimeInterval = 0
    var clickAt: CGPoint?

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
                case "--host": options.host = iterator.next() ?? ""
                case "--port": options.port = Int(iterator.next() ?? "") ?? HostAddress.defaultPort
                case "--auth":
                    guard let method = AuthenticationMethod(rawValue: iterator.next() ?? "") else { return nil }
                    options.auth = method
                case "--user": options.username = iterator.next() ?? ""
                case "--screenshot": options.screenshot = iterator.next()
                case "--timeout": options.timeout = TimeInterval(iterator.next() ?? "") ?? 20
                case "--type": options.typeText = iterator.next()
                case "--send-clipboard": options.sendClipboard = iterator.next()
                case "--expect-clipboard": options.expectClipboard = true
                case "--hold": options.holdSeconds = TimeInterval(iterator.next() ?? "") ?? 0
                case "--click":
                    let parts = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
                    guard parts.count == 2 else { return nil }
                    options.clickAt = CGPoint(x: parts[0], y: parts[1])
                default:
                    return nil
            }
        }

        return options.host.isEmpty ? nil : options
    }
}

@MainActor
final class Probe: RemoteDesktopEngineDelegate {
    let options: Options
    let engine: RoyalVNCEngine
    var sawFramebufferUpdate = false
    var receivedClipboard: String?
    var finished = false

    init(options: Options) {
        self.options = options
        self.engine = RoyalVNCEngine(target: ConnectionTarget(host: options.host,
                                                              port: options.port,
                                                              authenticationMethod: options.auth))
        engine.delegate = self
    }

    func run() async -> Int32 {
        let started = Date()
        log("connecting to \(HostAddress.display(host: options.host, port: options.port)) using \(options.auth.displayName)")
        engine.connect()

        // Wait for connection + first framebuffer update
        while !(engine.status == .connected && sawFramebufferUpdate) {
            if case .disconnected(let error) = engine.status {
                log("FAILED: \(error?.message ?? "disconnected") [\(error.map { "\($0.kind)" } ?? "-")]")
                printSecurity()
                return 2
            }

            if Date().timeIntervalSince(started) > options.timeout {
                log("FAILED: timed out waiting for framebuffer")
                engine.disconnect()
                return 3
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        log("connected in \(elapsed)s, framebuffer \(Int(engine.framebufferSize?.width ?? 0))x\(Int(engine.framebufferSize?.height ?? 0))")
        printSecurity()

        if let click = options.clickAt {
            engine.sendPointer(at: click, buttons: [])
            try? await Task.sleep(nanoseconds: 100_000_000)
            engine.sendPointer(at: click, buttons: .left)
            try? await Task.sleep(nanoseconds: 50_000_000)
            engine.sendPointer(at: click, buttons: [])
            log("clicked at \(Int(click.x)),\(Int(click.y))")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if let text = options.typeText {
            for scalar in text.unicodeScalars {
                let keysym = KeySymbols.keysym(for: scalar)
                engine.sendKey(keysym, isDown: true)
                engine.sendKey(keysym, isDown: false)
            }
            // Let the send queue drain before anything disconnects
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("typed \(text.count) characters")
        }

        if let text = options.sendClipboard {
            engine.sendClipboardText(text)
            log("sent clipboard text (\(text.count) characters, extended clipboard: \(engine.securityInfo.usesExtendedClipboard))")
        }

        if options.holdSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(options.holdSeconds * 1_000_000_000))
        }

        if options.expectClipboard {
            let deadline = Date().addingTimeInterval(options.timeout)

            while receivedClipboard == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard let text = receivedClipboard else {
                log("FAILED: no clipboard text received from server")
                engine.disconnect()
                return 4
            }

            log("received clipboard text: \(text.debugDescription)")
        }

        if let path = options.screenshot {
            guard let image = engine.captureFramebuffer() else {
                log("FAILED: framebuffer capture returned nil")
                engine.disconnect()
                return 5
            }

            do {
                try ScreenshotWriter.writePNG(image, to: URL(fileURLWithPath: path))
                log("wrote \(path) (\(image.width)x\(image.height))")
            } catch {
                log("FAILED: \(error.localizedDescription)")
                return 5
            }
        }

        engine.disconnect()

        let deadline = Date().addingTimeInterval(5)

        while engine.status.isActive && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        log("disconnected cleanly: \(!engine.status.isActive)")

        return 0
    }

    func printSecurity() {
        let info = engine.securityInfo
        log("server offered: \(info.offeredMethods.joined(separator: ", "))")
        log("negotiated: \(info.negotiatedMethod ?? "-"), session encrypted: \(info.isEncrypted)")

        if let fingerprint = info.serverKeyFingerprint {
            log("server key SHA-256: \(fingerprint)")
        }
    }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("[vncprobe] \(message)\n".utf8))
    }

    // MARK: RemoteDesktopEngineDelegate
    func engine(_ engine: RemoteDesktopEngine, didChangeStatus status: EngineStatus) {
        log("status: \(status)")
    }

    func engine(_ engine: RemoteDesktopEngine, needsCredentialsFor request: CredentialRequest) async -> SessionCredentials? {
        log("server requested \(request.kind == .password ? "a password" : "username + password") for \(request.methodName)")

        guard let password = ProcessInfo.processInfo.environment["VNC_PASSWORD"] else {
            log("VNC_PASSWORD is not set")
            return nil
        }

        return SessionCredentials(username: options.username, password: password)
    }

    func engine(_ engine: RemoteDesktopEngine, shouldTrustServerKey fingerprint: String) async -> Bool {
        true
    }

    func engine(_ engine: RemoteDesktopEngine, didResizeFramebuffer size: CGSize) {
        log("framebuffer size: \(Int(size.width))x\(Int(size.height))")
    }

    func engineDidUpdateFramebuffer(_ engine: RemoteDesktopEngine) {
        sawFramebufferUpdate = true
    }

    func engine(_ engine: RemoteDesktopEngine, didUpdateCursor cursor: NSCursor) {}

    func engine(_ engine: RemoteDesktopEngine, didReceiveClipboardText text: String) {
        receivedClipboard = text
        log("clipboard from server: \(text.debugDescription)")
    }
}

guard let options = Options.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("""
    usage: vncprobe --host HOST [--port N] [--auth automatic|none|vncPassword|appleRemoteDesktop|rsaAES|ultraVNCMSLogonII]
                    [--user NAME] [--screenshot FILE.png] [--timeout SEC] [--click X,Y] [--type TEXT]
                    [--send-clipboard TEXT] [--expect-clipboard] [--hold SEC]
    Password: VNC_PASSWORD environment variable.

    """.utf8))
    exit(64)
}

Task { @MainActor in
    let probe = Probe(options: options)
    let code = await probe.run()
    exit(code)
}

RunLoop.main.run()
