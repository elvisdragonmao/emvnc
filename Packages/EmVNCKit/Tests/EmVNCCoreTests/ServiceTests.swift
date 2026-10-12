import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import EmVNCCore

@Suite("Credentials")
struct CredentialTests {
    @Test func keychainSaveReadUpdateDelete() throws {
        // A unique service keeps the test away from real emvnc items; everything is removed at the end.
        let store = KeychainCredentialStore(service: "dev.emvnc.tests.\(UUID().uuidString)")
        let reference = UUID().uuidString
        defer { try? store.deletePassword(reference: reference) }

        #expect(try store.password(reference: reference) == nil)

        try store.savePassword("first pässwörd 🔑", reference: reference, label: "emvnc test")
        #expect(try store.password(reference: reference) == "first pässwörd 🔑")

        try store.savePassword("second", reference: reference, label: "emvnc test")
        #expect(try store.password(reference: reference) == "second")

        try store.deletePassword(reference: reference)
        #expect(try store.password(reference: reference) == nil)

        // Deleting something that is not there is not an error
        try store.deletePassword(reference: reference)
    }

    @Test @MainActor func managerKeepsOnlyAReferenceInTheModel() async throws {
        let store = InMemoryCredentialStore()
        let connection = SavedConnection(name: "Box", host: "box.local")

        #expect(!connection.hasSavedPassword)

        try CredentialManager.savePassword("secret", for: connection, in: store)

        #expect(connection.credentialReference == connection.id.uuidString)
        #expect(store.passwords[connection.id.uuidString] == "secret")
        #expect(try await CredentialManager.loadPassword(reference: connection.id.uuidString, from: store) == "secret")

        try CredentialManager.removePassword(for: connection, in: store)

        #expect(connection.credentialReference == nil)
        #expect(store.passwords.isEmpty)
    }
}

@Suite("Screenshots")
@MainActor
struct ScreenshotStoreTests {
    static func makeImage(width: Int = 64, height: Int = 40) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()!
    }

    @Test func saveRecordsFileAndThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ScreenshotStore(directory: directory)
        let container = try Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let connection = SavedConnection(name: "Box", host: "box.local")
        context.insert(connection)

        let record = try store.save(Self.makeImage(), for: connection, isAutomatic: true, in: context)
        let url = store.fileURL(for: record)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(connection.lastScreenshotFileName == record.fileName)
        #expect(record.width == 64 && record.height == 40)
        #expect(context.screenshots(for: connection.id).count == 1)

        // Opaque PNG without alpha and without any metadata about the connection
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])

        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        #expect(properties[kCGImagePropertyIPTCDictionary] == nil)
        // ImageIO itself records the pixel size in EXIF; nothing else may be there
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let allowedExif: Set<String> = [ kCGImagePropertyExifPixelXDimension as String,
                                         kCGImagePropertyExifPixelYDimension as String,
                                         kCGImagePropertyExifColorSpace as String ]
        #expect(Set(exif.keys.map { $0 as String }).isSubset(of: allowedExif))

        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("box.local".utf8)) == nil)
    }

    @Test func historyIsPrunedAndDeletionMovesTheThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ScreenshotStore(directory: directory)
        let container = try Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let connection = SavedConnection(name: "Box", host: "box.local")
        context.insert(connection)

        for _ in 0..<(ScreenshotStore.historyLimit + 3) {
            try store.save(Self.makeImage(), for: connection, isAutomatic: false, in: context)
            Thread.sleep(forTimeInterval: 0.002)
        }

        let records = context.screenshots(for: connection.id)
        #expect(records.count == ScreenshotStore.historyLimit)

        let newest = records[0]
        store.delete(newest, in: context)
        try context.save()

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: newest).path))
        #expect(connection.lastScreenshotFileName == context.screenshots(for: connection.id).first?.fileName)
    }

    @Test func withoutHistoryOnlyTheLatestAutomaticCaptureIsKept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ScreenshotStore(directory: directory)
        let container = try Persistence.makeContainer(inMemory: true)
        let context = container.mainContext
        var preferences = ConnectionPreferences()
        preferences.keepScreenshotHistory = false
        let connection = SavedConnection(name: "Box", host: "box.local", preferences: preferences)
        context.insert(connection)

        try store.save(Self.makeImage(), for: connection, isAutomatic: false, in: context)
        Thread.sleep(forTimeInterval: 0.002)
        try store.save(Self.makeImage(), for: connection, isAutomatic: true, in: context)
        Thread.sleep(forTimeInterval: 0.002)
        try store.save(Self.makeImage(), for: connection, isAutomatic: true, in: context)

        let records = context.screenshots(for: connection.id)

        #expect(records.filter(\.isAutomatic).count == 1)
        #expect(records.filter { !$0.isAutomatic }.count == 1)
    }
}

@Suite("Clipboard sync rules")
struct ClipboardSyncStateTests {
    let a = UUID()
    let b = UUID()

    @Test func localChangesGoOnlyToTheFocusedSession() {
        var state = ClipboardSyncState(initialChangeCount: 1)

        let r1 = state.localPasteboardPolled(changeCount: 1, text: { "x" }, focusedSession: a)
        #expect(r1 == nil)
        let r2 = state.localPasteboardPolled(changeCount: 2, text: { "hello" }, focusedSession: a)
        #expect(r2 == "hello")
        let r3 = state.localPasteboardPolled(changeCount: 3, text: { "unfocused" }, focusedSession: nil)
        #expect(r3 == nil)
    }

    @Test func echoesFromTheServerAreIgnored() {
        var state = ClipboardSyncState(initialChangeCount: 1)
        _ = state.localPasteboardPolled(changeCount: 2, text: { "copied on mac" }, focusedSession: a)

        // Many servers send the text straight back, sometimes twice
        let r4 = state.remoteTextReceived("copied on mac", from: a, sessionIsFocused: true)
        #expect(!r4)
        let r5 = state.remoteTextReceived("copied on mac", from: a, sessionIsFocused: true)
        #expect(!r5)
    }

    @Test func lateEchoAfterANewerCopyIsStillIgnored() {
        var state = ClipboardSyncState(initialChangeCount: 1)
        _ = state.localPasteboardPolled(changeCount: 2, text: { "first" }, focusedSession: a)
        _ = state.localPasteboardPolled(changeCount: 3, text: { "second" }, focusedSession: a)

        let r6 = state.remoteTextReceived("first", from: a, sessionIsFocused: true)
        #expect(!r6)
    }

    @Test func remoteTextIsWrittenOnceAndNotSentBack() {
        var state = ClipboardSyncState(initialChangeCount: 1)

        let r7 = state.remoteTextReceived("from remote", from: a, sessionIsFocused: true)
        #expect(r7)
        state.didWritePasteboard(changeCount: 2)

        // Our own write is not picked up as a local change
        let r8 = state.localPasteboardPolled(changeCount: 2, text: { "from remote" }, focusedSession: a)
        #expect(r8 == nil)
        // Duplicate notification
        let r9 = state.remoteTextReceived("from remote", from: a, sessionIsFocused: true)
        #expect(!r9)
    }

    @Test func backgroundSessionsDoNotOverwriteTheMacClipboard() {
        var state = ClipboardSyncState(initialChangeCount: 1)

        let r10 = state.remoteTextReceived("background", from: b, sessionIsFocused: false)
        #expect(!r10)
    }

    @Test func focusingASessionSendsTheCurrentClipboardOnce() {
        var state = ClipboardSyncState(initialChangeCount: 1)

        let r11 = state.sessionFocused(a, currentText: "mac text")
        #expect(r11 == "mac text")
        let r12 = state.sessionFocused(a, currentText: "mac text")
        #expect(r12 == nil)
        let r13 = state.sessionFocused(b, currentText: "mac text")
        #expect(r13 == "mac text")
        let r14 = state.sessionFocused(a, currentText: nil)
        #expect(r14 == nil)
    }

    @Test func unicodeAndMultilineTextPassUnchanged() {
        var state = ClipboardSyncState(initialChangeCount: 1)
        let text = "第一行 ✓\n第二行 🚀\r\nthird"

        let r15 = state.localPasteboardPolled(changeCount: 2, text: { text }, focusedSession: a)
        #expect(r15 == text)
    }
}

@MainActor
final class FakePasteboard: TextPasteboard {
    var changeCount = 1
    var text: String?

    func readText() -> String? { text }

    func writeText(_ text: String) -> Int {
        self.text = text
        changeCount += 1

        return changeCount
    }

    func userCopies(_ text: String) {
        self.text = text
        changeCount += 1
    }
}

@MainActor
final class FakeParticipant: ClipboardParticipant {
    let clipboardSessionID = UUID()
    var isClipboardSyncEnabled = true
    var isReadyForClipboard = true
    var sent: [String] = []

    func sendClipboardTextToRemote(_ text: String) {
        sent.append(text)
    }
}

@Suite("Clipboard coordinator")
@MainActor
struct ClipboardCoordinatorTests {
    @Test func endToEndBetweenTwoSessions() {
        let pasteboard = FakePasteboard()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard)
        let first = FakeParticipant()
        let second = FakeParticipant()

        coordinator.register(first)
        coordinator.register(second)

        // Copy on the Mac while the first session is focused
        coordinator.sessionFocused(first)
        pasteboard.userCopies("mac → first")
        coordinator.poll()
        #expect(first.sent == [ "mac → first" ])
        #expect(second.sent.isEmpty)

        // The first remote copies something: lands on the Mac, is not echoed back
        coordinator.remoteTextReceived("remote one", from: first)
        #expect(pasteboard.text == "remote one")
        coordinator.poll()
        #expect(first.sent == [ "mac → first" ])

        // Switching to the second session hands it the current Mac clipboard
        coordinator.sessionUnfocused(first)
        coordinator.sessionFocused(second)
        #expect(second.sent == [ "remote one" ])
    }

    @Test func disabledSessionsNeitherSendNorReceive() {
        let pasteboard = FakePasteboard()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard)
        let participant = FakeParticipant()
        participant.isClipboardSyncEnabled = false

        coordinator.register(participant)
        coordinator.sessionFocused(participant)
        pasteboard.userCopies("secret")
        coordinator.poll()
        coordinator.remoteTextReceived("from remote", from: participant)

        #expect(participant.sent.isEmpty)
        #expect(pasteboard.text == "secret")
    }

    @Test func remoteTextShortlyAfterFocusLossIsAccepted() {
        let pasteboard = FakePasteboard()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard)
        let participant = FakeParticipant()

        coordinator.register(participant)
        coordinator.sessionFocused(participant)
        coordinator.sessionUnfocused(participant)
        coordinator.remoteTextReceived("copied then ⌘Tab", from: participant)

        #expect(pasteboard.text == "copied then ⌘Tab")
    }
}
