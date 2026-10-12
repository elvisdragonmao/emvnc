import Foundation
import Observation
import SwiftData

/// Metadata for a stored remote-framebuffer screenshot. The PNG lives on disk (see `ScreenshotStore`).
/// Hand-written `PersistentModel` conformance, see `SavedConnection` for why.
public final class ScreenshotRecord {
    public var id: UUID {
        get { access(\.id); return getValue(forKey: \.id) }
        set { mutate(\.id) { setValue(forKey: \.id, to: newValue) } }
    }

    public var connectionID: UUID {
        get { access(\.connectionID); return getValue(forKey: \.connectionID) }
        set { mutate(\.connectionID) { setValue(forKey: \.connectionID, to: newValue) } }
    }

    public var fileName: String {
        get { access(\.fileName); return getValue(forKey: \.fileName) }
        set { mutate(\.fileName) { setValue(forKey: \.fileName, to: newValue) } }
    }

    public var capturedAt: Date {
        get { access(\.capturedAt); return getValue(forKey: \.capturedAt) }
        set { mutate(\.capturedAt) { setValue(forKey: \.capturedAt, to: newValue) } }
    }

    public var width: Int {
        get { access(\.width); return getValue(forKey: \.width) }
        set { mutate(\.width) { setValue(forKey: \.width, to: newValue) } }
    }

    public var height: Int {
        get { access(\.height); return getValue(forKey: \.height) }
        set { mutate(\.height) { setValue(forKey: \.height, to: newValue) } }
    }

    public var isAutomatic: Bool {
        get { access(\.isAutomatic); return getValue(forKey: \.isAutomatic) }
        set { mutate(\.isAutomatic) { setValue(forKey: \.isAutomatic, to: newValue) } }
    }

    public init(id: UUID = UUID(),
                connectionID: UUID,
                fileName: String,
                capturedAt: Date = Date(),
                width: Int,
                height: Int,
                isAutomatic: Bool) {
        self.id = id
        self.connectionID = connectionID
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.isAutomatic = isAutomatic
    }

    // MARK: PersistentModel plumbing
    private var _$backingData: any BackingData<ScreenshotRecord> = ScreenshotRecord.createBackingData()
    private let _$observationRegistrar = ObservationRegistrar()

    public var persistentBackingData: any BackingData<ScreenshotRecord> {
        get { _$backingData }
        set { _$backingData = newValue }
    }

    public required init(backingData: any BackingData<ScreenshotRecord>) {
        self.persistentBackingData = backingData
    }

    public static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "id", keypath: \ScreenshotRecord.id, defaultValue: nil, metadata: Schema.Attribute(.unique)),
            .init(name: "connectionID", keypath: \ScreenshotRecord.connectionID),
            .init(name: "fileName", keypath: \ScreenshotRecord.fileName),
            .init(name: "capturedAt", keypath: \ScreenshotRecord.capturedAt),
            .init(name: "width", keypath: \ScreenshotRecord.width),
            .init(name: "height", keypath: \ScreenshotRecord.height),
            .init(name: "isAutomatic", keypath: \ScreenshotRecord.isAutomatic)
        ]
    }

    private func access<Value>(_ keyPath: KeyPath<ScreenshotRecord, Value>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }

    private func mutate<Value>(_ keyPath: KeyPath<ScreenshotRecord, Value>, _ body: () -> Void) {
        _$observationRegistrar.withMutation(of: self, keyPath: keyPath, body)
    }
}

extension ScreenshotRecord: PersistentModel {}
extension ScreenshotRecord: Observable {}
