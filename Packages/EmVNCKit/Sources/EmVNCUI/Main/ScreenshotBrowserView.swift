import EmVNCCore
import SwiftData
import SwiftUI

/// Screenshot history of one connection: view, reveal, copy, delete.
struct ScreenshotBrowserView: View {
    let connectionID: UUID

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    private let recordsQuery = Query<ScreenshotRecord, [ScreenshotRecord]>(sort: \.capturedAt, order: .reverse)
    private var allRecords: [ScreenshotRecord] { recordsQuery.wrappedValue }
    @ViewState private var selection: UUID?
    @ViewState private var pendingDeletion: ScreenshotRecord?

    private var records: [ScreenshotRecord] {
        allRecords.filter { $0.connectionID == connectionID }
    }

    private var connection: SavedConnection? {
        appModel.context.connection(withID: connectionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Screenshots").font(.title3.weight(.semibold))
                    Text(connection?.name ?? "").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(appModel.screenshotStore.folder(for: connectionID))
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(records.isEmpty)
            }
            .padding()

            Divider()

            if records.isEmpty {
                ContentUnavailableView("No Screenshots",
                                       systemImage: "camera",
                                       description: Text("Screenshots are captured automatically after connecting, or with the camera button in the session toolbar."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [ GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14) ], spacing: 14) {
                        ForEach(records) { record in
                            ScreenshotTile(record: record,
                                           url: appModel.screenshotStore.fileURL(for: record),
                                           isSelected: selection == record.id,
                                           isThumbnail: connection?.lastScreenshotFileName == record.fileName)
                                .onTapGesture(count: 2) { open(record) }
                                .simultaneousGesture(TapGesture().onEnded { selection = record.id })
                                .contextMenu {
                                    Button("Open") { open(record) }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([ appModel.screenshotStore.fileURL(for: record) ])
                                    }
                                    Button("Copy Image") { copy(record) }
                                    Button("Use as Thumbnail") {
                                        connection?.lastScreenshotFileName = record.fileName
                                        try? appModel.context.save()
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { pendingDeletion = record }
                                }
                        }
                    }
                    .padding()
                }
                .onDeleteCommand {
                    if let id = selection, let record = records.first(where: { $0.id == id }) {
                        pendingDeletion = record
                    }
                }
            }

            Divider()

            HStack {
                Text(records.count == 1 ? "1 screenshot" : "\(records.count) screenshots")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 720, height: 520)
        .confirmationDialog("Delete this screenshot?",
                            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let record = pendingDeletion {
                    appModel.screenshotStore.delete(record, in: appModel.context)
                    try? appModel.context.save()
                }
                pendingDeletion = nil
            }
        }
    }

    private func open(_ record: ScreenshotRecord) {
        NSWorkspace.shared.open(appModel.screenshotStore.fileURL(for: record))
    }

    private func copy(_ record: ScreenshotRecord) {
        guard let image = NSImage(contentsOf: appModel.screenshotStore.fileURL(for: record)) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ image ])
    }
}

private struct ScreenshotTile: View {
    let record: ScreenshotRecord
    let url: URL
    let isSelected: Bool
    let isThumbnail: Bool

    @ViewState private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.secondary.opacity(0.15)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }

            HStack(spacing: 4) {
                Text(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                if isThumbnail {
                    Image(systemName: "photo.badge.checkmark").font(.caption).foregroundStyle(.secondary)
                        .help("Shown on the connection card")
                }
                Spacer()
                Text(record.isAutomatic ? "Auto" : "Manual")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(record.width) × \(record.height)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: url) {
            image = await ThumbnailLoader.shared.load(at: url, maxPixelSize: 560)
        }
    }
}
