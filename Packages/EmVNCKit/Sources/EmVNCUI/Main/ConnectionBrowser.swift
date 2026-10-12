import EmVNCCore
import SwiftUI

struct ConnectionBrowser: View {
    let connections: [SavedConnection]
    let emptyState: BrowserEmptyState
    let viewMode: BrowserViewMode
    @Binding var selection: Set<UUID>
    let onConnect: (SavedConnection) -> Void
    let onDelete: ([SavedConnection]) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if connections.isEmpty {
            emptyView
        } else {
            switch viewMode {
                case .grid:
                    ConnectionGrid(connections: connections,
                                   selection: $selection,
                                   onConnect: onConnect,
                                   onDelete: onDelete)
                case .list:
                    ConnectionTable(connections: connections,
                                    selection: $selection,
                                    onConnect: onConnect,
                                    onDelete: onDelete)
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        switch emptyState {
            case .noConnections:
                ContentUnavailableView {
                    Label("No Connections", systemImage: "display.2")
                } description: {
                    Text("Add a computer to connect to it with one double-click, or use Quick Connect for a one-off session.")
                } actions: {
                    HStack {
                        Button("Add Connection…") { appModel.requestNewConnection() }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                        Button("Quick Connect…") { appModel.requestQuickConnect() }
                            .fixedSize()
                    }
                }
            case .noFavorites:
                ContentUnavailableView("No Favorites",
                                       systemImage: "star",
                                       description: Text("Mark connections as favorites from their context menu."))
            case .noRecents:
                ContentUnavailableView("No Recent Connections",
                                       systemImage: "clock",
                                       description: Text("Connections you open appear here."))
            case .search(let text):
                ContentUnavailableView.search(text: text)
        }
    }
}

// MARK: - Grid
private struct ConnectionGrid: View {
    let connections: [SavedConnection]
    @Binding var selection: Set<UUID>
    let onConnect: (SavedConnection) -> Void
    let onDelete: ([SavedConnection]) -> Void

    @Environment(AppModel.self) private var appModel

    @FocusState private var isFocused: Bool
    @ViewState private var columnCount = 3

    private static let minimumWidth: CGFloat = 230
    private static let spacing: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: [ GridItem(.adaptive(minimum: Self.minimumWidth, maximum: 360), spacing: Self.spacing) ],
                          spacing: Self.spacing) {
                    ForEach(connections) { connection in
                        ConnectionCard(connection: connection, isSelected: selection.contains(connection.id))
                            .onTapGesture(count: 2) { onConnect(connection) }
                            .simultaneousGesture(TapGesture().onEnded {
                                select(connection)
                                isFocused = true
                            })
                            .contextMenu { ConnectionContextMenu(connection: connection, appModel: appModel, onDelete: onDelete) }
                    }
                }
                .padding(20)
            }
            .onAppear { updateColumns(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in updateColumns(width: width) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand(perform: move)
        .onKeyPress(.return) {
            guard let connection = selectedConnection else { return .ignored }

            onConnect(connection)

            return .handled
        }
        .onDeleteCommand {
            let selected = connections.filter { selection.contains($0.id) }

            if !selected.isEmpty {
                onDelete(selected)
            }
        }
        .background {
            // Clicking empty space clears the selection
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = []
                    isFocused = true
                }
        }
    }

    private var selectedConnection: SavedConnection? {
        connections.first { selection.contains($0.id) }
    }

    private func select(_ connection: SavedConnection) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(connection.id) {
                selection.remove(connection.id)
            } else {
                selection.insert(connection.id)
            }
        } else {
            selection = [ connection.id ]
        }
    }

    private func updateColumns(width: CGFloat) {
        let usable = width - 40 + Self.spacing
        columnCount = max(1, Int(usable / (Self.minimumWidth + Self.spacing)))
    }

    private func move(_ direction: MoveCommandDirection) {
        guard !connections.isEmpty else { return }

        let currentIndex = connections.firstIndex { selection.contains($0.id) }

        guard let currentIndex else {
            selection = [ connections[0].id ]
            return
        }

        var index = currentIndex

        switch direction {
            case .left: index -= 1
            case .right: index += 1
            case .up: index -= columnCount
            case .down: index += columnCount
            @unknown default: break
        }

        index = min(max(0, index), connections.count - 1)
        selection = [ connections[index].id ]
    }
}

struct ConnectionCard: View {
    let connection: SavedConnection
    let isSelected: Bool

    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(url: appModel.screenshotStore.latestScreenshotURL(for: connection))
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if connection.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                            .accessibilityLabel("Favorite")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let phase = appModel.liveStatus[connection.id] {
                        LiveStatusBadge(phase: phase).padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(connection: connection, livePhase: appModel.liveStatus[connection.id])
                    Text(connection.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(connection.displayAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(lastConnectedText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [ .isSelected, .isButton ] : .isButton)
        .accessibilityHint("Double-click to connect")
    }

    private var lastConnectedText: String {
        guard let date = connection.lastConnectedAt else {
            return "Never connected"
        }

        return "Connected \(date.formatted(.relative(presentation: .named)))"
    }
}

/// Takes its file URL explicitly: it is also used inside `Table` cells, whose hosting views do not always
/// receive `@Observable` environment objects.
struct ThumbnailView: View {
    let url: URL?

    @ViewState private var image: CGImage?

    var body: some View {
        // The gradient takes the proposed size; the screenshot is an overlay so its aspect ratio never
        // changes the card's layout
        LinearGradient(colors: [ Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12) ],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "display")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }

            image = await ThumbnailLoader.shared.load(at: url, maxPixelSize: 720)
        }
    }
}

struct StatusDot: View {
    let connection: SavedConnection
    let livePhase: SessionController.Phase?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        if let livePhase {
            switch livePhase {
                case .connected: return .green
                case .connecting, .reconnecting: return .orange
                case .failed: return .red
                default: break
            }
        }

        switch connection.lastOutcome {
            case .authenticationFailed, .failed: return .red
            case .connected: return .gray.opacity(0.6)
            default: return .gray.opacity(0.3)
        }
    }

    private var label: String {
        if livePhase == .connected { return "Connected" }

        switch connection.lastOutcome {
            case .authenticationFailed: return "Last attempt: authentication failed"
            case .failed: return "Last attempt failed"
            case .connected: return "Last connection succeeded"
            default: return "Not connected yet"
        }
    }
}

private struct LiveStatusBadge: View {
    let phase: SessionController.Phase

    var body: some View {
        let (text, color): (String, Color) = switch phase {
            case .connected: ("Connected", .green)
            case .connecting: ("Connecting…", .orange)
            case .reconnecting: ("Reconnecting…", .orange)
            case .failed: ("Failed", .red)
            case .disconnected, .idle: ("Open", .gray)
        }

        Label(text, systemImage: "circle.fill")
            .labelStyle(BadgeLabelStyle(color: color))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private struct BadgeLabelStyle: LabelStyle {
        let color: Color

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.foregroundStyle(color).font(.system(size: 7))
                configuration.title
            }
        }
    }
}

// MARK: - List
private struct ConnectionTable: View {
    let connections: [SavedConnection]
    @Binding var selection: Set<UUID>
    let onConnect: (SavedConnection) -> Void
    let onDelete: ([SavedConnection]) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Read the environment here, not inside cell or menu closures: those run in hosting views that may lack it
        let appModel = appModel
        let liveStatus = appModel.liveStatus
        let screenshotStore = appModel.screenshotStore

        Table(connections, selection: $selection) {
            TableColumn("Name") { connection in
                HStack(spacing: 8) {
                    ThumbnailView(url: screenshotStore.latestScreenshotURL(for: connection))
                        .frame(width: 48, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    StatusDot(connection: connection, livePhase: liveStatus[connection.id])
                    Text(connection.name)
                    if connection.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            .accessibilityLabel("Favorite")
                    }
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Address") { connection in
                Text(connection.displayAddress).foregroundStyle(.secondary)
            }

            TableColumn("Authentication") { connection in
                Text(connection.authenticationMethod.displayName).foregroundStyle(.secondary)
            }

            TableColumn("Last Connected") { connection in
                Text(connection.lastConnectedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let connection = connections.first(where: { ids.contains($0.id) }) {
                if ids.count == 1 {
                    ConnectionContextMenu(connection: connection, appModel: appModel, onDelete: onDelete)
                } else {
                    Button("Delete \(ids.count) Connections…", role: .destructive) {
                        onDelete(connections.filter { ids.contains($0.id) })
                    }
                }
            }
        } primaryAction: { ids in
            for connection in connections where ids.contains(connection.id) {
                onConnect(connection)
            }
        }
        .onDeleteCommand {
            let selected = connections.filter { selection.contains($0.id) }

            if !selected.isEmpty {
                onDelete(selected)
            }
        }
    }
}

/// Menus are hosted outside the view tree, so the app model is passed in rather than read from the environment.
struct ConnectionContextMenu: View {
    let connection: SavedConnection
    let appModel: AppModel
    let onDelete: ([SavedConnection]) -> Void

    var body: some View {
        Button("Connect") { appModel.connect(to: connection) }
        Divider()
        Button("Edit…") { appModel.requestEdit(connectionID: connection.id) }
        Button("Duplicate") { appModel.duplicate(connection) }
        Button(connection.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            appModel.toggleFavorite(connection)
        }
        Divider()
        Button("Screenshots…") { appModel.screenshotBrowserConnectionID = connection.id }
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(connection.displayAddress, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { onDelete([ connection ]) }
    }
}
