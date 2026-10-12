import EmVNCCore
import SwiftData
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case all, favorites, recent

    var id: String { rawValue }

    var title: String {
        switch self {
            case .all: "All Connections"
            case .favorites: "Favorites"
            case .recent: "Recent"
        }
    }

    var systemImage: String {
        switch self {
            case .all: "display.2"
            case .favorites: "star"
            case .recent: "clock"
        }
    }
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid, list

    var id: String { rawValue }
}

enum BrowserSortOrder: String, CaseIterable, Identifiable {
    case name, lastConnected

    var id: String { rawValue }

    var title: String {
        switch self {
            case .name: "Name"
            case .lastConnected: "Last Connected"
        }
    }
}

struct MainView: View {
    static let windowID = "main"
    static let recentLimit = 20

    let storeError: String?

    @Environment(AppModel.self) private var appModel
    private let connectionsQuery = Query<SavedConnection, [SavedConnection]>(sort: \.name)
    private var connections: [SavedConnection] { connectionsQuery.wrappedValue }

    @ViewState private var sidebarSelection: SidebarItem? = .all
    @ViewState private var searchText = ""
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var pendingDeletion: [SavedConnection] = []
    @ViewState private var showStoreError = false
    @AppStorage(AppSettings.viewModeKey) private var viewMode: BrowserViewMode = .grid
    @AppStorage(AppSettings.sortOrderKey) private var sortOrder: BrowserSortOrder = .name

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $sidebarSelection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(count(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            ConnectionBrowser(connections: visibleConnections,
                              emptyState: emptyState,
                              viewMode: viewMode,
                              selection: $selection,
                              onConnect: connect,
                              onDelete: { pendingDeletion = $0 })
                .navigationTitle(sidebarSelection?.title ?? "Connections")
                .navigationSubtitle(subtitle)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search Connections")
                .toolbar { toolbar }
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $appModel.editorRequest) { request in
            ConnectionEditorView(request: request)
        }
        .sheet(isPresented: $appModel.quickConnectRequested) {
            QuickConnectView()
        }
        .sheet(item: Binding(
            get: { appModel.screenshotBrowserConnectionID.map(IdentifiedUUID.init) },
            set: { appModel.screenshotBrowserConnectionID = $0?.id }
        )) { item in
            ScreenshotBrowserView(connectionID: item.id)
        }
        .confirmationDialog(deletionTitle,
                            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for connection in pendingDeletion {
                    selection.remove(connection.id)
                    appModel.delete(connection)
                }
                pendingDeletion = []
            }
        } message: {
            Text("The saved password and screenshots are deleted too. This cannot be undone.")
        }
        .alert("Saved connections could not be opened", isPresented: $showStoreError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("emvnc is using a temporary list for this session. \(storeError ?? "")")
        }
        .onAppear {
            showStoreError = storeError != nil
        }
    }

    // MARK: Data
    private var visibleConnections: [SavedConnection] {
        var result: [SavedConnection]

        switch sidebarSelection ?? .all {
            case .all:
                result = connections
            case .favorites:
                result = connections.filter(\.isFavorite)
            case .recent:
                result = connections
                    .filter { $0.lastConnectedAt != nil }
                    .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }

                return Array(filtered(result).prefix(Self.recentLimit))
        }

        result = filtered(result)

        switch sortOrder {
            case .name:
                return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .lastConnected:
                return result.sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        }
    }

    private func filtered(_ list: [SavedConnection]) -> [SavedConnection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)

        guard !query.isEmpty else { return list }

        return list.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
                || String($0.port).contains(query)
        }
    }

    private func count(for item: SidebarItem) -> Int {
        switch item {
            case .all: connections.count
            case .favorites: connections.filter(\.isFavorite).count
            case .recent: min(Self.recentLimit, connections.filter { $0.lastConnectedAt != nil }.count)
        }
    }

    private var subtitle: String {
        let count = visibleConnections.count

        return count == 1 ? "1 connection" : "\(count) connections"
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1
            ? "Delete “\(pendingDeletion[0].name)”?"
            : "Delete \(pendingDeletion.count) connections?"
    }

    private var emptyState: BrowserEmptyState {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return .search(searchText)
        }

        switch sidebarSelection ?? .all {
            case .all: return .noConnections
            case .favorites: return .noFavorites
            case .recent: return .noRecents
        }
    }

    private func connect(_ connection: SavedConnection) {
        appModel.connect(to: connection)
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appModel.requestNewConnection()
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .help("Add a saved connection (⌘N)")

            Button {
                appModel.requestQuickConnect()
            } label: {
                Label("Quick Connect", systemImage: "bolt.horizontal")
            }
            .help("Connect without saving (⌘K)")

            Picker("View", selection: $viewMode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show as grid or list")

            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(BrowserSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort connections")
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

enum BrowserEmptyState {
    case noConnections, noFavorites, noRecents, search(String)
}
