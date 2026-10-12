import Foundation
import SwiftData

/// File locations used by emvnc. `EMVNC_DATA_DIR` overrides the root (used by tests and UI automation so
/// they never touch the user's real data).
public enum AppPaths {
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["EMVNC_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        return base.appendingPathComponent("emvnc", isDirectory: true)
    }

    public static var storeURL: URL {
        dataDirectory.appendingPathComponent("emvnc.store")
    }

    public static var screenshotsDirectory: URL {
        dataDirectory.appendingPathComponent("Screenshots", isDirectory: true)
    }
}

public enum Persistence {
    public static let schema = Schema([ SavedConnection.self, ScreenshotRecord.self ])

    public static func makeContainer(inMemory: Bool = false, url: URL = AppPaths.storeURL) throws -> ModelContainer {
        let configuration: ModelConfiguration

        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url)
        }

        return try ModelContainer(for: schema, configurations: configuration)
    }
}

public extension ModelContext {
    func connection(withID id: UUID) -> SavedConnection? {
        // Predicates need the Foundation macro plugin, which the Command Line Tools lack; the list is small.
        (try? fetch(FetchDescriptor<SavedConnection>()))?.first { $0.id == id }
    }

    func screenshots(for connectionID: UUID) -> [ScreenshotRecord] {
        let descriptor = FetchDescriptor<ScreenshotRecord>(sortBy: [ SortDescriptor(\.capturedAt, order: .reverse) ])

        return ((try? fetch(descriptor)) ?? []).filter { $0.connectionID == connectionID }
    }
}
