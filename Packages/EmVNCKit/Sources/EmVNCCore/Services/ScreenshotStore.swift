import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftData

/// Saves remote-framebuffer screenshots as PNG files and tracks them with `ScreenshotRecord`s.
/// Files live in `<data>/Screenshots/<connection UUID>/`.
@MainActor
public final class ScreenshotStore {
    public static let historyLimit = 30

    public let directory: URL

    public init(directory: URL = AppPaths.screenshotsDirectory) {
        self.directory = directory
    }

    public func folder(for connectionID: UUID) -> URL {
        directory.appendingPathComponent(connectionID.uuidString, isDirectory: true)
    }

    public func fileURL(for record: ScreenshotRecord) -> URL {
        folder(for: record.connectionID).appendingPathComponent(record.fileName)
    }

    public func fileURL(connectionID: UUID, fileName: String) -> URL {
        folder(for: connectionID).appendingPathComponent(fileName)
    }

    /// Writes the image, records it, points the connection's thumbnail at it and prunes old history.
    @discardableResult
    public func save(_ image: CGImage,
                     for connection: SavedConnection,
                     isAutomatic: Bool,
                     in context: ModelContext) throws -> ScreenshotRecord {
        let folder = folder(for: connection.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let date = Date()
        let fileName = Self.fileName(for: date)

        try ScreenshotWriter.writePNG(image, to: folder.appendingPathComponent(fileName))

        let keepHistory = connection.preferences.keepScreenshotHistory

        // Without history only the latest automatic thumbnail is kept; manual captures are always kept
        if !keepHistory {
            for old in context.screenshots(for: connection.id) where old.isAutomatic {
                delete(old, in: context)
            }
        }

        let record = ScreenshotRecord(connectionID: connection.id,
                                      fileName: fileName,
                                      capturedAt: date,
                                      width: image.width,
                                      height: image.height,
                                      isAutomatic: isAutomatic)
        context.insert(record)

        connection.lastScreenshotFileName = fileName
        invalidateThumbnail(connectionID: connection.id)

        prune(connectionID: connection.id, in: context)
        try context.save()

        return record
    }

    public func delete(_ record: ScreenshotRecord, in context: ModelContext) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
        ThumbnailLoader.shared.removeAll()
        context.delete(record)

        if let connection = context.connection(withID: record.connectionID),
           connection.lastScreenshotFileName == record.fileName {
            let remaining = context.screenshots(for: record.connectionID).filter { $0.id != record.id }
            connection.lastScreenshotFileName = remaining.first?.fileName
            invalidateThumbnail(connectionID: record.connectionID)
        }
    }

    /// Removes every screenshot of a connection (used when the connection is deleted).
    public func deleteAll(for connectionID: UUID, in context: ModelContext) {
        for record in context.screenshots(for: connectionID) {
            context.delete(record)
        }

        try? FileManager.default.removeItem(at: folder(for: connectionID))
        invalidateThumbnail(connectionID: connectionID)
    }

    /// Copies the latest screenshot to a duplicated connection so it starts with a preview.
    public func copyLatest(from source: SavedConnection, to destination: SavedConnection) {
        guard let fileName = source.lastScreenshotFileName else { return }

        let sourceURL = fileURL(connectionID: source.id, fileName: fileName)
        let destinationFolder = folder(for: destination.id)

        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationFolder.appendingPathComponent(fileName))
            destination.lastScreenshotFileName = fileName
        } catch {
            destination.lastScreenshotFileName = nil
        }
    }

    public func latestScreenshotURL(for connection: SavedConnection) -> URL? {
        connection.lastScreenshotFileName.map { fileURL(connectionID: connection.id, fileName: $0) }
    }

    private func invalidateThumbnail(connectionID: UUID) {
        // Cache keys embed the file path; deleted files must not linger in the cache
        ThumbnailLoader.shared.removeAll()
    }

    private func prune(connectionID: UUID, in context: ModelContext) {
        let records = context.screenshots(for: connectionID)

        guard records.count > Self.historyLimit else { return }

        for record in records.dropFirst(Self.historyLimit) {
            try? FileManager.default.removeItem(at: fileURL(for: record))
            context.delete(record)
        }
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"

        return "screenshot-\(formatter.string(from: date)).png"
    }
}
