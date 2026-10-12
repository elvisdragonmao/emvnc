import AppKit
import Foundation

/// Decision logic for text clipboard sharing between the Mac and remote sessions.
///
/// Rules:
/// - Local changes go only to the focused session, never to background sessions.
/// - A session that gains focus receives the current Mac clipboard if it has not seen it yet.
/// - Text a session sends back (many servers echo ClientCutText) is ignored, so nothing loops.
/// - Text written to the Mac pasteboard on behalf of a session is not sent back out by the poller.
public struct ClipboardSyncState: Sendable {
    /// How many recently sent texts per session are remembered to recognise late echoes.
    static let echoMemory = 4

    public private(set) var lastObservedChangeCount: Int
    private var ownChangeCounts: Set<Int> = []
    /// Last text known to be on each session's remote clipboard (sent or received).
    private var sessionText: [UUID: String] = [:]
    private var recentlySent: [UUID: [String]] = [:]

    public init(initialChangeCount: Int) {
        self.lastObservedChangeCount = initialChangeCount
    }

    /// The Mac pasteboard was polled. Returns text to send to the focused session, if any.
    public mutating func localPasteboardPolled(changeCount: Int,
                                               text: () -> String?,
                                               focusedSession: UUID?) -> String? {
        guard changeCount != lastObservedChangeCount else { return nil }

        lastObservedChangeCount = changeCount

        guard !ownChangeCounts.contains(changeCount) else { return nil }
        guard let focusedSession, let text = text() else { return nil }

        return recordOutgoing(text, to: focusedSession)
    }

    /// A session became focused (or finished connecting while focused). Returns text to send, if any.
    public mutating func sessionFocused(_ session: UUID, currentText: String?) -> String? {
        guard let currentText else { return nil }

        return recordOutgoing(currentText, to: session)
    }

    /// Clipboard text arrived from a session. Returns true when it should be written to the Mac pasteboard.
    public mutating func remoteTextReceived(_ text: String, from session: UUID, sessionIsFocused: Bool) -> Bool {
        guard !text.isEmpty else { return false }

        // Echo of something we sent (possibly late) or a duplicate notification
        if sessionText[session] == text || recentlySent[session, default: []].contains(text) {
            return false
        }

        sessionText[session] = text

        // Background sessions must not overwrite what the user is doing on the Mac
        return sessionIsFocused
    }

    /// Record a pasteboard write made on behalf of a session so the poller ignores it.
    public mutating func didWritePasteboard(changeCount: Int) {
        ownChangeCounts.insert(changeCount)
        lastObservedChangeCount = changeCount

        if ownChangeCounts.count > 32 {
            ownChangeCounts = Set(ownChangeCounts.sorted().suffix(16))
        }
    }

    public mutating func sessionEnded(_ session: UUID) {
        sessionText.removeValue(forKey: session)
        recentlySent.removeValue(forKey: session)
    }

    private mutating func recordOutgoing(_ text: String, to session: UUID) -> String? {
        guard !text.isEmpty, sessionText[session] != text else { return nil }

        sessionText[session] = text

        var recent = recentlySent[session, default: []]
        recent.removeAll { $0 == text }
        recent.append(text)
        recentlySent[session] = Array(recent.suffix(Self.echoMemory))

        return text
    }
}

/// Minimal pasteboard interface so the coordinator can be tested without touching the real clipboard.
@MainActor
public protocol TextPasteboard: AnyObject {
    var changeCount: Int { get }
    func readText() -> String?
    /// Writes text and returns the new change count.
    func writeText(_ text: String) -> Int
}

@MainActor
public final class SystemTextPasteboard: TextPasteboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    public func writeText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        return pasteboard.changeCount
    }
}

/// A session that participates in clipboard sharing.
@MainActor
public protocol ClipboardParticipant: AnyObject {
    var clipboardSessionID: UUID { get }
    var isClipboardSyncEnabled: Bool { get }
    var isReadyForClipboard: Bool { get }
    func sendClipboardTextToRemote(_ text: String)
}

/// App-wide owner of the Mac pasteboard side of clipboard sharing. Polls only while at least one
/// connected session has sharing enabled.
@MainActor
public final class ClipboardCoordinator {
    public static let pollInterval: TimeInterval = 0.4
    /// Remote text arriving this soon after the session lost focus is still accepted (copy, then ⌘Tab).
    public static let focusGracePeriod: TimeInterval = 3

    private let pasteboard: TextPasteboard
    private var state: ClipboardSyncState
    private var participants: [UUID: WeakParticipant] = [:]
    private var focusedSession: UUID?
    private var lastFocusLoss: (session: UUID, date: Date)?
    private var timer: Timer?

    public init(pasteboard: TextPasteboard) {
        self.pasteboard = pasteboard
        self.state = ClipboardSyncState(initialChangeCount: pasteboard.changeCount)
    }

    public func register(_ participant: ClipboardParticipant) {
        participants[participant.clipboardSessionID] = WeakParticipant(participant)
        updatePolling()
    }

    public func unregister(_ participant: ClipboardParticipant) {
        let id = participant.clipboardSessionID

        participants.removeValue(forKey: id)
        state.sessionEnded(id)

        if focusedSession == id {
            focusedSession = nil
        }

        updatePolling()
    }

    /// Call when a session window becomes key, when it connects, and when sharing is switched on.
    public func sessionFocused(_ participant: ClipboardParticipant) {
        focusedSession = participant.clipboardSessionID
        updatePolling()

        guard participant.isClipboardSyncEnabled, participant.isReadyForClipboard else { return }

        // Pick up anything copied on the Mac while no session was focused
        _ = state.localPasteboardPolled(changeCount: pasteboard.changeCount, text: { nil }, focusedSession: nil)

        if let text = state.sessionFocused(participant.clipboardSessionID, currentText: pasteboard.readText()) {
            participant.sendClipboardTextToRemote(text)
        }
    }

    public func sessionUnfocused(_ participant: ClipboardParticipant) {
        guard focusedSession == participant.clipboardSessionID else { return }

        focusedSession = nil
        lastFocusLoss = (participant.clipboardSessionID, Date())
    }

    public func remoteTextReceived(_ text: String, from participant: ClipboardParticipant) {
        guard participant.isClipboardSyncEnabled else { return }

        let id = participant.clipboardSessionID
        let recentlyFocused = lastFocusLoss.map { $0.session == id && Date().timeIntervalSince($0.date) < Self.focusGracePeriod } ?? false
        let isFocused = focusedSession == id || recentlyFocused

        guard state.remoteTextReceived(text, from: id, sessionIsFocused: isFocused) else { return }
        guard pasteboard.readText() != text else { return }

        state.didWritePasteboard(changeCount: pasteboard.writeText(text))
    }

    /// Exposed for tests; normally driven by the timer.
    public func poll() {
        guard let focusedSession,
              let participant = participants[focusedSession]?.value,
              participant.isClipboardSyncEnabled,
              participant.isReadyForClipboard else {
            // Still track the change count so a later focus does not resend stale content as "new"
            return
        }

        let pasteboard = self.pasteboard

        if let text = state.localPasteboardPolled(changeCount: pasteboard.changeCount,
                                                  text: { pasteboard.readText() },
                                                  focusedSession: focusedSession) {
            participant.sendClipboardTextToRemote(text)
        }
    }

    private func updatePolling() {
        participants = participants.filter { $0.value.value != nil }

        let shouldPoll = !participants.isEmpty

        if shouldPoll, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldPoll {
            timer?.invalidate()
            timer = nil
        }
    }

    private struct WeakParticipant {
        weak var value: ClipboardParticipant?

        init(_ value: ClipboardParticipant) {
            self.value = value
        }
    }
}
