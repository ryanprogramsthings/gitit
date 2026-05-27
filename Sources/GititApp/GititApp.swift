import AppKit
import SwiftUI
import GititFFI

enum UIDefaultsKey {
    static let showSidebar = "ui.showSidebar"
    static let showDiffPane = "ui.showDiffPane"
    static let diffHeight = "ui.diffHeightFraction"
    static let sidebarLocalExpanded = "ui.sidebar.localExpanded"
    static let sidebarRemoteExpanded = "ui.sidebar.remoteExpanded"
    static let sidebarTagsExpanded = "ui.sidebar.tagsExpanded"
    static let refFilters = "filter.refPatterns"
}

/// Vertical split with a draggable separator. The bottom child can be hidden
/// via `bottomVisible`; its size is stored as a fraction of the container
/// height so toggling collapse and resizing the window both preserve the
/// user's chosen ratio.
struct VerticalCollapsibleSplit<Top: View, Bottom: View>: View {
    @Binding var bottomFraction: Double
    let bottomVisible: Bool
    let minTop: CGFloat
    let minBottom: CGFloat
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    @GestureState private var dragDelta: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let dividerH: CGFloat = 6
            let total = geo.size.height
            let maxBottom = max(minBottom, total - minTop - dividerH)
            let target = CGFloat(bottomFraction) * total - dragDelta
            let clamped = min(max(target, minBottom), maxBottom)

            VStack(spacing: 0) {
                top()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if bottomVisible {
                    DragHandle()
                        .gesture(
                            DragGesture(coordinateSpace: .local)
                                .updating($dragDelta) { value, state, _ in
                                    state = value.translation.height
                                }
                                .onEnded { value in
                                    let proposed = CGFloat(bottomFraction) * total - value.translation.height
                                    let final = min(max(proposed, minBottom), maxBottom)
                                    bottomFraction = total > 0 ? Double(final / total) : bottomFraction
                                }
                        )
                    bottom()
                        .frame(maxWidth: .infinity)
                        .frame(height: clamped)
                }
            }
        }
    }
}

private struct DragHandle: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(height: 8)
                .contentShape(Rectangle())
                .onHover { isIn in
                    if isIn { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
            Divider()
        }
    }
}

@main
struct GititApp: App {
    @State private var state = AppState()
    @State private var filterSettings = FilterSettings()

    var body: some Scene {
        WindowGroup("gitit") {
            ContentView()
                .environment(state)
                .environment(filterSettings)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { state.chooseAndOpen() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        // `.environment` on the WindowGroup does not cross into the Settings
        // scene — both stores must be injected here explicitly.
        Settings {
            SettingsView()
                .environment(state)
                .environment(filterSettings)
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @AppStorage(UIDefaultsKey.showSidebar) private var showSidebar: Bool = true
    @AppStorage(UIDefaultsKey.showDiffPane) private var showBottomPanel: Bool = true

    var body: some View {
        Group {
            switch state.state {
            case .empty:
                EmptyStateView { state.chooseAndOpen() }
            case .loading(let url):
                LoadingView(path: url)
            case .loaded(let overview):
                RepoBrowserView(overview: overview)
            case .failed(let url, let message):
                FailedView(path: url, message: message) { state.chooseAndOpen() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!state.isLoaded)
                .help("Toggle Sidebar (⌥⌘S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showBottomPanel.toggle() }
                } label: {
                    Label("Toggle Bottom Panel", systemImage: "square.bottomthird.inset.filled")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!state.isLoaded)
                .help("Toggle Bottom Panel (⌥⌘0)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { state.chooseAndOpen() } label: {
                    Label("Open Repository", systemImage: "folder")
                }
            }
        }
    }
}

/// The app's Settings window — a category `TabView`. New categories are added
/// as one more `.tabItem`.
struct SettingsView: View {
    var body: some View {
        TabView {
            FilteringSettingsView()
                .tabItem {
                    Label("Filtering", systemImage: "line.3.horizontal.decrease.circle")
                }
        }
        .frame(width: 540, height: 480)
    }
}

/// The Filtering category: per-repository regex patterns that scope which refs
/// the sidebar shows. Edits the patterns of the currently-open repository.
struct FilteringSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(FilterSettings.self) private var filterSettings

    private var repoPath: String? {
        if case let .loaded(overview) = state.state { return overview.path.path }
        return nil
    }

    var body: some View {
        if let path = repoPath {
            editor(path: path)
        } else {
            ContentUnavailableView(
                "No Repository Open",
                systemImage: "folder.badge.questionmark",
                description: Text("Open a repository to configure ref filtering.")
            )
        }
    }

    private func editor(path: String) -> some View {
        let patterns = filterSettings.patterns(for: path)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Show only refs whose name matches one of the patterns "
                     + "below. Use * for any text and ? for a single "
                     + "character — \"trunk\" matches only that ref, "
                     + "\"trunk*\" matches every name starting with it. "
                     + "Leave a list empty to show all. Patterns are scoped "
                     + "to this repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PatternSection(title: "Local Branches", patterns: patterns.local) { updated in
                    var next = filterSettings.patterns(for: path)
                    next.local = updated
                    filterSettings.setPatterns(next, for: path)
                }
                PatternSection(title: "Remote Branches", patterns: patterns.remote) { updated in
                    var next = filterSettings.patterns(for: path)
                    next.remote = updated
                    filterSettings.setPatterns(next, for: path)
                }
                PatternSection(title: "Tags", patterns: patterns.tags) { updated in
                    var next = filterSettings.patterns(for: path)
                    next.tags = updated
                    filterSettings.setPatterns(next, for: path)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An editable list of regex patterns for one ref kind. Each edit hands the
/// whole updated array back through `onChange`.
private struct PatternSection: View {
    let title: String
    let patterns: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if patterns.isEmpty {
                Text("No patterns — showing all.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(patterns.indices, id: \.self) { index in
                    PatternRow(
                        text: Binding(
                            get: { patterns[index] },
                            set: { newValue in
                                var copy = patterns
                                copy[index] = newValue
                                onChange(copy)
                            }
                        ),
                        onRemove: {
                            var copy = patterns
                            copy.remove(at: index)
                            onChange(copy)
                        }
                    )
                }
            }
            Button {
                onChange(patterns + [""])
            } label: {
                Label("Add Pattern", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One glob pattern: a monospaced field and a remove button.
private struct PatternRow: View {
    @Binding var text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("name pattern, e.g. release/26.*", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove pattern")
        }
    }
}

private struct EmptyStateView: View {
    let onOpen: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No repository open")
                .font(.title2)
            Button("Open Repository…", action: onOpen)
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadingView: View {
    let path: URL
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(path.path).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedView: View {
    let path: URL
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Could not open \(path.lastPathComponent)").font(.title3)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Another…", action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepoBrowserView: View {
    let overview: RepoOverview
    @Environment(AppState.self) private var appState
    @State private var pager: LogPager
    @State private var diffStore: CommitDiffStore
    @State private var graphStore: GraphStore
    @State private var selectedOid: String?
    @AppStorage(UIDefaultsKey.showSidebar) private var showSidebar: Bool = true
    @AppStorage(UIDefaultsKey.showDiffPane) private var showBottomPanel: Bool = true
    @AppStorage(UIDefaultsKey.diffHeight) private var diffPaneFraction: Double = 0.5

    init(overview: RepoOverview) {
        self.overview = overview
        _pager = State(initialValue: LogPager(repoPath: overview.path))
        _diffStore = State(initialValue: CommitDiffStore(repoPath: overview.path))
        _graphStore = State(initialValue: GraphStore(repoPath: overview.path))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                RepoSidebar(
                    overview: overview,
                    graphStore: graphStore,
                    onCompare: { a, b in diffStore.loadRangeDiff(old: a.refName, new: b.refName) },
                    onUnmergedWork: { a, b in diffStore.loadUnmergedWork(refA: a.refName, refB: b.refName) }
                )
                .frame(width: 260)
                Divider()
            }
            VerticalCollapsibleSplit(
                bottomFraction: $diffPaneFraction,
                bottomVisible: showBottomPanel,
                minTop: 240,
                minBottom: 160
            ) {
                VSplitView {
                    GraphPaneView(store: graphStore, selection: $selectedOid)
                        .frame(minHeight: 140, idealHeight: 220)
                    HSplitView {
                        LogView(pager: pager, selection: $selectedOid)
                            .frame(minWidth: 280, idealWidth: 440)
                        ChangedFilesView(store: diffStore)
                            .frame(minWidth: 240, idealWidth: 320)
                    }
                    .frame(minHeight: 200)
                }
            } bottom: {
                DiffContentView(store: diffStore)
            }
        }
        .task(id: overview.path) {
            graphStore.configure(from: overview)
        }
        .onChange(of: overview.headOid) {
            // A checkout replaced the overview — re-seed the filter to the new
            // HEAD (branch or tag), which cascades a History reload below.
            graphStore.configure(from: overview)
        }
        .onChange(of: graphStore.activeRefs) { _, refs in
            pager.reload(refNames: refs)
        }
        .onChange(of: selectedOid) { _, newValue in
            if let oid = newValue { diffStore.loadDiff(for: oid) }
        }
        .alert(
            "Checkout failed",
            isPresented: Binding(
                get: { appState.checkoutError != nil },
                set: { if !$0 { appState.checkoutError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.checkoutError ?? "")
        }
    }
}

private struct GraphPaneView: View {
    @Bindable var store: GraphStore
    @Binding var selection: String?

    /// The selected commit, if it's a merge currently drawn in the graph.
    private var selectedMerge: GraphCommit? {
        guard let visible = store.visibleGraph,
              let idx = selection.flatMap({ visible.indexByOid[$0] }),
              visible.commits[idx].parents.count >= 2 else { return nil }
        return visible.commits[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Graph").font(.headline)
                Spacer()
                if let merge = selectedMerge {
                    let expanded = store.expandedMerges.contains(merge.oid)
                    Button {
                        store.toggleMerge(merge)
                        if !expanded, let inbound = merge.parents.dropFirst().first {
                            selection = inbound
                        }
                    } label: {
                        Label(
                            expanded ? "Collapse Merge" : "Expand Merge",
                            systemImage: expanded ? "arrow.triangle.merge" : "arrow.triangle.pull"
                        )
                    }
                    .help(expanded
                        ? "Hide the branch merged in by this commit"
                        : "Reveal the branch merged in by this commit")
                }
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else if let visible = store.visibleGraph {
                    Text("\(visible.commits.count) commits • \(visible.laneCount) lanes")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if let visible = store.visibleGraph {
                GraphView(
                    visible: visible,
                    tips: store.snapshot?.tips ?? [],
                    selection: $selection,
                    focusOid: $store.focusOid
                )
            } else if let err = store.error {
                Text(err)
                    .font(.footnote).foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(store.isLoading ? "" : "Pick at least one branch to render")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RepoSidebar: View {
    let overview: RepoOverview
    @Bindable var graphStore: GraphStore
    /// Invoked when the user picks "Compare" with two refs selected.
    let onCompare: (RefSelection, RefSelection) -> Void
    /// Invoked when the user picks "Determine Work Not Merged" with two refs selected.
    let onUnmergedWork: (RefSelection, RefSelection) -> Void
    @Environment(FilterSettings.self) private var filterSettings

    @AppStorage(UIDefaultsKey.sidebarLocalExpanded) private var localExpanded = true
    @AppStorage(UIDefaultsKey.sidebarRemoteExpanded) private var remoteExpanded = false

    /// Branch trees, memoized in `@State`: `buildBranchTree` over thousands of
    /// remote names is too costly to recompute on every body pass. They hold
    /// the filtered ref set (see `rebuildTrees`).
    @State private var localTree: [TreeNode<BranchInfo>] = []
    @State private var remoteTree: [TreeNode<BranchInfo>] = []
    /// Tag folder tree, memoized alongside the branch trees.
    @State private var tagTree: [TreeNode<String>] = []
    /// Counts of the refs surviving the filter — drive the section headers.
    @State private var localCount = 0
    @State private var remoteCount = 0
    @State private var tagCount = 0

    /// This repository's ref-filter patterns. Reading it registers an
    /// observation dependency, so the `.onChange` below fires when it changes.
    private var currentPatterns: RepoFilterPatterns {
        filterSettings.patterns(for: overview.path.path)
    }
    /// Expanded folder paths. Folders start collapsed so expanding a section
    /// materializes only its top-level rows, not the whole subtree.
    @State private var expandedFolders: Set<String> = []
    /// Expanded tag-folder paths — kept separate from `expandedFolders` so a
    /// branch folder and a tag folder of the same name never collide.
    @State private var expandedTagFolders: Set<String> = []
    /// Refs picked for comparison, in selection order. Capped at two.
    @State private var selectedRefs: [RefSelection] = []

    /// Plain click replaces the selection; Cmd-click adds (or toggles off) a
    /// second ref, dropping the oldest once two are already selected.
    private func selectRef(_ ref: RefSelection, additive: Bool) {
        if additive {
            if let i = selectedRefs.firstIndex(of: ref) {
                selectedRefs.remove(at: i)
            } else if selectedRefs.count < 2 {
                selectedRefs.append(ref)
            } else {
                selectedRefs = [selectedRefs[1], ref]
            }
        } else {
            selectedRefs = [ref]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.path.lastPathComponent)
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.middle)
                Text(overview.path.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            Divider()

            Toggle(isOn: Binding(
                get: { graphStore.showMergedBranches },
                set: { graphStore.setShowMergedBranches($0) }
            )) {
                Text("Show merged branches")
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sidebarRows) { row in
                        sidebarRowView(row)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            CollapsibleSection(
                title: "Tags",
                systemImage: "tag",
                count: tagCount,
                total: overview.tags.count,
                storageKey: UIDefaultsKey.sidebarTagsExpanded,
                defaultExpanded: false
            ) {
                if tagTree.isEmpty {
                    Text(overview.tags.isEmpty ? "No tags" : "No tags match the filter")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tagRows) { row in
                                tagRowView(row)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: overview.headOid, initial: true) { rebuildTrees() }
        .onChange(of: currentPatterns) { rebuildTrees() }
    }

    /// Rebuilds the memoized branch/tag trees from the repo's refs, scoped by
    /// this repository's filter patterns. The current branch and detached-HEAD
    /// tag are always kept, even when they don't match a pattern.
    private func rebuildTrees() {
        let patterns = currentPatterns
        let localFilter = RefFilter(patterns: patterns.local)
        let remoteFilter = RefFilter(patterns: patterns.remote)
        let tagFilter = RefFilter(patterns: patterns.tags)

        let locals = overview.branches.filter {
            $0.name == overview.headName || localFilter.matches($0.name)
        }
        let remotes = overview.remoteBranches.filter { remoteFilter.matches($0.name) }
        let tags = overview.tags.filter {
            $0 == overview.headTag || tagFilter.matches($0)
        }

        localTree = buildTree(locals.map { ($0.name, $0) })
        remoteTree = buildTree(remotes.map { ($0.name, $0) })
        tagTree = buildTree(tags.map { ($0, $0) })
        localCount = locals.count
        remoteCount = remotes.count
        tagCount = tags.count
    }

    /// The branch area flattened to one list: section headers, then — for each
    /// expanded section — the visible folder/branch rows under expanded folders
    /// only. Cheap to recompute, and lets the enclosing `LazyVStack` virtualize.
    private var sidebarRows: [SidebarRow] {
        var rows: [SidebarRow] = [.header(.local)]
        if localExpanded {
            if !overview.headTag.isEmpty {
                rows.append(.currentTag(overview.headTag))
            }
            if localTree.isEmpty {
                rows.append(.empty("local", "No local branches"))
            } else {
                appendTree(localTree, depth: 0, into: &rows)
            }
        }
        rows.append(.header(.remote))
        if remoteExpanded {
            if remoteTree.isEmpty {
                rows.append(.empty("remote", "No remote branches"))
            } else {
                appendTree(remoteTree, depth: 0, into: &rows)
            }
        }
        return rows
    }

    private func appendTree(_ nodes: [TreeNode<BranchInfo>], depth: Int, into rows: inout [SidebarRow]) {
        for node in nodes {
            if let branch = node.leaf {
                rows.append(.branch(branch, node.name, depth))
            } else {
                rows.append(.folder(node, depth))
                if expandedFolders.contains(node.path) {
                    appendTree(node.children, depth: depth + 1, into: &rows)
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRowView(_ row: SidebarRow) -> some View {
        switch row {
        case .header(let section):
            sectionHeader(section)
        case .currentTag(let tag):
            currentTagRow(tag)
        case .folder(let node, let depth):
            folderRow(node, depth: depth)
        case .branch(let branch, let displayName, let depth):
            BranchRow(
                branch: branch,
                displayName: displayName,
                headName: overview.headName,
                graphStore: graphStore,
                selectedRefs: selectedRefs,
                onSelect: selectRef,
                onCompare: onCompare,
                onUnmergedWork: onUnmergedWork
            )
            .padding(.leading, CGFloat(depth) * 14)
        case .empty(_, let label):
            Text(label)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ section: SidebarRow.Section) -> some View {
        let isExpanded = section == .local ? localExpanded : remoteExpanded
        let shown = section == .local ? localCount : remoteCount
        let total = section == .local ? overview.branches.count : overview.remoteBranches.count
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if section == .local { localExpanded.toggle() } else { remoteExpanded.toggle() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Label(section.title, systemImage: section.systemImage).font(.headline)
                Spacer()
                FilteredCountBadge(shown: shown, total: total)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The detached-HEAD-on-a-tag indicator, shown atop the Local section: a
    /// current marker, a tag glyph, and the tag name — no branch is current.
    private func currentTagRow(_ tag: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Image(systemName: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tag)
                .fontDesign(.monospaced)
                .fontWeight(.semibold)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .help("Detached HEAD — checked out tag \(tag)")
    }

    private func folderRow(_ node: TreeNode<BranchInfo>, depth: Int) -> some View {
        let isExpanded = expandedFolders.contains(node.path)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if !expandedFolders.insert(node.path).inserted {
                    expandedFolders.remove(node.path)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(node.children.count)")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The tag tree flattened to one virtualized list: visible folder/tag rows
    /// under expanded folders only — mirrors `sidebarRows` for branches.
    private var tagRows: [TagRowKind] {
        var rows: [TagRowKind] = []
        appendTagTree(tagTree, depth: 0, into: &rows)
        return rows
    }

    private func appendTagTree(_ nodes: [TreeNode<String>], depth: Int, into rows: inout [TagRowKind]) {
        for node in nodes {
            if let tag = node.leaf {
                rows.append(.tag(tag, node.name, depth))
            } else {
                rows.append(.folder(node, depth))
                if expandedTagFolders.contains(node.path) {
                    appendTagTree(node.children, depth: depth + 1, into: &rows)
                }
            }
        }
    }

    @ViewBuilder
    private func tagRowView(_ row: TagRowKind) -> some View {
        switch row {
        case .folder(let node, let depth):
            tagFolderRow(node, depth: depth)
        case .tag(let tag, let displayName, let depth):
            TagRow(
                tag: tag,
                displayName: displayName,
                selectedRefs: selectedRefs,
                onSelect: selectRef,
                onCompare: onCompare,
                onUnmergedWork: onUnmergedWork
            )
            .padding(.leading, CGFloat(depth) * 14)
        }
    }

    private func tagFolderRow(_ node: TreeNode<String>, depth: Int) -> some View {
        let isExpanded = expandedTagFolders.contains(node.path)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if !expandedTagFolders.insert(node.path).inserted {
                    expandedTagFolders.remove(node.path)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(node.children.count)")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14 + CGFloat(depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A branch or tag the user has picked in the sidebar for comparison.
/// `refName` is the plain ref string Rust resolution expects: `main`,
/// `origin/main`, or a tag's short name.
struct RefSelection: Equatable, Hashable {
    enum Kind { case branch, tag }
    let kind: Kind
    let refName: String
}

/// One flattened row of the sidebar's branch area: a section header, a folder,
/// a branch leaf, or an empty-state label. Drives a single virtualized list.
private enum SidebarRow: Identifiable {
    enum Section {
        case local, remote
        var title: String { self == .local ? "Local" : "Remote" }
        var systemImage: String { self == .local ? "arrow.triangle.branch" : "cloud" }
    }
    case header(Section)
    case currentTag(String)
    case folder(TreeNode<BranchInfo>, Int)
    case branch(BranchInfo, String, Int)
    case empty(String, String)

    var id: String {
        switch self {
        case .header(let s):       return "header:\(s.title)"
        case .currentTag(let t):   return "currenttag:\(t)"
        case .folder(let n, _):    return "folder:\(n.path)"
        case .branch(let b, _, _): return "branch:\(b.id)"
        case .empty(let key, _):   return "empty:\(key)"
        }
    }
}

/// One flattened row of the Tags pane: a folder or a tag leaf.
private enum TagRowKind: Identifiable {
    case folder(TreeNode<String>, Int)
    case tag(String, String, Int)   // full tag, display segment, depth

    var id: String {
        switch self {
        case .folder(let n, _): return "tagfolder:\(n.path)"
        case .tag(let t, _, _): return "tag:\(t)"
        }
    }
}

/// A node in a sidebar tree: a leaf (carries a `leaf` payload) or a folder
/// (`children`, `leaf == nil`) formed from a slash-delimited name.
private struct TreeNode<Leaf>: Identifiable {
    let name: String              // segment shown in the row or folder header
    let path: String              // full segment path — stable view identity
    let leaf: Leaf?               // non-nil for a leaf
    let children: [TreeNode<Leaf>]
    var id: String { path }
}

/// A compiled set of ref-name glob patterns. `*` matches any run of
/// characters, `?` matches exactly one; every other character is literal and
/// the match is anchored to the whole name. So `trunk` matches only the ref
/// named exactly `trunk`, while `trunk*` matches every name starting with
/// `trunk` — the behaviour a glob, not a regex, implies. Patterns compile once
/// at init and are reused across every ref, so filtering thousands of names
/// stays cheap. Blank patterns are dropped. No patterns => `matches` is always
/// true (no filtering).
struct RefFilter {
    private let regexes: [NSRegularExpression]

    init(patterns: [String]) {
        regexes = patterns.compactMap { pattern in
            pattern.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : Self.compileGlob(pattern)
        }
    }

    var isActive: Bool { !regexes.isEmpty }

    func matches(_ name: String) -> Bool {
        guard isActive else { return true }
        let range = NSRange(name.startIndex..., in: name)
        return regexes.contains { $0.firstMatch(in: name, range: range) != nil }
    }

    /// Translates a glob (`*`, `?`) into an anchored regular expression, with
    /// every other character escaped so it matches literally.
    private static func compileGlob(_ glob: String) -> NSRegularExpression? {
        var pattern = "^"
        for ch in glob {
            switch ch {
            case "*": pattern += ".*"
            case "?": pattern += "."
            default:  pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern)
    }
}

/// Splits slash-delimited keys (`feat/foo`, `origin/feat/bar`, `release/1.0`)
/// into a nested folder tree, preserving input order (leaves before folders
/// per level). Each leaf carries its `Leaf` payload.
private func buildTree<Leaf>(_ items: [(String, Leaf)]) -> [TreeNode<Leaf>] {
    func group(
        _ entries: [(ArraySlice<String>, String, Leaf)],
        prefix: String
    ) -> [TreeNode<Leaf>] {
        var leaves: [TreeNode<Leaf>] = []
        var folderOrder: [String] = []
        var folderEntries: [String: [(ArraySlice<String>, String, Leaf)]] = [:]
        for (segments, key, leaf) in entries {
            if segments.count <= 1 {
                let seg = segments.first ?? key
                leaves.append(TreeNode(name: seg, path: prefix + seg, leaf: leaf, children: []))
            } else {
                let head = segments.first!
                if folderEntries[head] == nil { folderOrder.append(head) }
                folderEntries[head, default: []].append((segments.dropFirst(), key, leaf))
            }
        }
        var nodes = leaves
        for folder in folderOrder {
            let childPrefix = prefix + folder + "/"
            let children = group(folderEntries[folder] ?? [], prefix: childPrefix)
            nodes.append(TreeNode(name: folder, path: childPrefix, leaf: nil, children: children))
        }
        return nodes
    }
    let entries = items.map {
        (ArraySlice($0.0.split(separator: "/").map(String.init)), $0.0, $0.1)
    }
    return group(entries, prefix: "")
}

/// A section-header count: the visible ref count, plus `/ total` and a funnel
/// glyph when a filter is hiding refs.
private struct FilteredCountBadge: View {
    let shown: Int
    let total: Int

    private var isFiltered: Bool { shown != total }

    var body: some View {
        HStack(spacing: 3) {
            if isFiltered {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("\(shown)")
                .foregroundStyle(.secondary).monospacedDigit()
            if isFiltered {
                Text("/ \(total)")
                    .font(.caption)
                    .foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .help(isFiltered ? "\(shown) of \(total) shown — filtered" : "")
    }
}

/// A sidebar section with a tappable header (chevron + title + count) whose
/// expanded state persists in `@AppStorage` under `storageKey`.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    let total: Int
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String,
        count: Int,
        total: Int,
        storageKey: String,
        defaultExpanded: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.total = total
        self.content = content
        _expanded = AppStorage(wrappedValue: defaultExpanded, storageKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Label(title, systemImage: systemImage).font(.headline)
                    Spacer()
                    FilteredCountBadge(shown: count, total: total)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One branch in the sidebar: current-branch indicator, name, ahead/behind
/// badges, a graph/history filter button, and double-click to check out.
private struct BranchRow: View {
    let branch: BranchInfo
    /// The segment shown in the row — the leaf name when nested in a folder.
    let displayName: String
    let headName: String
    @Bindable var graphStore: GraphStore
    let selectedRefs: [RefSelection]
    let onSelect: (RefSelection, Bool) -> Void
    let onCompare: (RefSelection, RefSelection) -> Void
    let onUnmergedWork: (RefSelection, RefSelection) -> Void
    @Environment(AppState.self) private var appState

    private var isCurrent: Bool { !branch.isRemote && branch.name == headName }
    private var isFiltered: Bool { graphStore.enabledBranchIDs.contains(branch.id) }
    private var myRef: RefSelection { RefSelection(kind: .branch, refName: branch.name) }
    private var isSelected: Bool { selectedRefs.contains(myRef) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.clear)

            Text(displayName)
                .fontDesign(.monospaced)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1).truncationMode(.middle)

            if !branch.isRemote && !branch.isTracked {
                Text("local-only")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
            }

            Spacer(minLength: 4)

            if branch.ahead > 0 {
                divergenceBadge(systemImage: "arrow.up", count: branch.ahead)
            }
            if branch.behind > 0 {
                divergenceBadge(systemImage: "arrow.down", count: branch.behind)
            }

            Button {
                graphStore.setBranchEnabled(branch, enabled: !isFiltered)
            } label: {
                Image(systemName: isFiltered ? "eye.fill" : "eye")
                    .font(.caption)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isFiltered ? "Hide from graph and history" : "Show in graph and history")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !branch.isRemote else { return }
            appState.checkout(branch.name)
        }
        .simultaneousGesture(TapGesture(count: 1).modifiers(.command)
            .onEnded { onSelect(myRef, true) })
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.command) { return }
            onSelect(myRef, false)
        }
        .contextMenu {
            refCompareMenu(selectedRefs: selectedRefs, onCompare: onCompare, onUnmergedWork: onUnmergedWork)
        }
        .help(branch.isRemote
            ? branch.name
            : "Double-click to check out \(branch.name)")
    }

    private func divergenceBadge(systemImage: String, count: UInt32) -> some View {
        HStack(spacing: 1) {
            Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            Text("\(count)").font(.system(size: 10)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

/// One tag in the sidebar: a tag icon, the (leaf-segment) name, and
/// double-click to check it out — the tag equivalent of `BranchRow`.
private struct TagRow: View {
    let tag: String
    /// The segment shown in the row — the leaf name when nested in a folder.
    let displayName: String
    let selectedRefs: [RefSelection]
    let onSelect: (RefSelection, Bool) -> Void
    let onCompare: (RefSelection, RefSelection) -> Void
    let onUnmergedWork: (RefSelection, RefSelection) -> Void
    @Environment(AppState.self) private var appState

    private var myRef: RefSelection { RefSelection(kind: .tag, refName: tag) }
    private var isSelected: Bool { selectedRefs.contains(myRef) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(displayName)
                .fontDesign(.monospaced)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { appState.checkout(tag) }
        .simultaneousGesture(TapGesture(count: 1).modifiers(.command)
            .onEnded { onSelect(myRef, true) })
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.command) { return }
            onSelect(myRef, false)
        }
        .contextMenu {
            refCompareMenu(selectedRefs: selectedRefs, onCompare: onCompare, onUnmergedWork: onUnmergedWork)
        }
        .help("Double-click to check out \(tag)")
    }
}

/// The "Compare / Work Not Merged" context-menu content shared by branch and tag rows.
/// Shows both actions only when exactly two refs are selected; otherwise a disabled hint.
@ViewBuilder
private func refCompareMenu(
    selectedRefs: [RefSelection],
    onCompare: @escaping (RefSelection, RefSelection) -> Void,
    onUnmergedWork: @escaping (RefSelection, RefSelection) -> Void
) -> some View {
    if selectedRefs.count == 2 {
        Button("Compare \(selectedRefs[0].refName) ↔ \(selectedRefs[1].refName)") {
            onCompare(selectedRefs[0], selectedRefs[1])
        }
        Button("Determine Work Not Merged from \(selectedRefs[0].refName) into \(selectedRefs[1].refName)") {
            onUnmergedWork(selectedRefs[0], selectedRefs[1])
        }
    } else {
        Button("Select 2 refs to compare") {}.disabled(true)
    }
}

private struct LogView: View {
    let pager: LogPager
    @Binding var selection: String?

    private static let compactThreshold: CGFloat = 480

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < Self.compactThreshold
            VStack(spacing: 0) {
                HStack {
                    Text("History")
                        .font(.headline)
                    Spacer()
                    if pager.isWalking {
                        Text("\(pager.commits.count) commits (walking…)")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        ProgressView().controlSize(.small).padding(.leading, 6)
                    } else if pager.totalKnown > 0 {
                        Text("\(pager.commits.count) of \(pager.totalKnown)")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        if pager.isLoading {
                            ProgressView().controlSize(.small).padding(.leading, 6)
                        }
                    } else {
                        Text("\(pager.commits.count) commit\(pager.commits.count == 1 ? "" : "s")")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        if pager.isLoading {
                            ProgressView().controlSize(.small).padding(.leading, 6)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                List(pager.commits, selection: $selection) { commit in
                    CommitRowView(commit: commit, isCompact: isCompact)
                        .onAppear {
                            if commit.id == pager.commits.last?.id { pager.loadNext() }
                        }
                }
                .listStyle(.plain)

                if let error = pager.error {
                    Divider()
                    Text(error)
                        .font(.footnote).foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct CommitRowView: View {
    let commit: Commit
    let isCompact: Bool
    private static let dateFormat = Date.FormatStyle()
        .year().month(.abbreviated).day().hour().minute()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(commit.summary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isCompact {
                Text(commit.authorName)
                    .foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }
            Text(commit.time, format: Self.dateFormat)
                .foregroundStyle(.secondary).lineLimit(1)
                .frame(width: isCompact ? 100 : 130, alignment: .leading)
            if !isCompact {
                Text(commit.shortOid)
                    .fontDesign(.monospaced).foregroundStyle(.tertiary)
                    .frame(width: 72, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ChangedFilesView: View {
    let store: CommitDiffStore
    @State private var filterText: String = ""

    private var isUnmergedMode: Bool {
        if case .unmergedWork = store.source { return true }
        return false
    }

    private var filteredFiles: [FileChange] {
        let patterns = filterText.split(whereSeparator: \.isWhitespace).map(String.init)
        let filter = RefFilter(patterns: patterns)
        guard filter.isActive else { return store.files }
        return store.files.filter { filter.matches($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner
            if case .range(let old, let new) = store.source {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(old).fontDesign(.monospaced).fontWeight(.semibold)
                    Text("↔").foregroundStyle(.secondary)
                    Text(new).fontDesign(.monospaced).fontWeight(.semibold)
                    Spacer()
                }
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            } else if case .unmergedWork(let refA, let refB) = store.source {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.circle")
                    Text(refA).fontDesign(.monospaced).fontWeight(.semibold)
                    Text("→").foregroundStyle(.secondary)
                    Text(refB).fontDesign(.monospaced).fontWeight(.semibold)
                    Spacer()
                }
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            // File filter — only in range-diff mode
            if case .range = store.source {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("filter files — *login* *auth*", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    if !filterText.isEmpty {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear filter")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }

            // Header
            HStack {
                Text(isUnmergedMode ? "Commits with Work Not Found" : "Changed Files")
                    .font(.headline)
                Spacer()
                if isUnmergedMode && !store.unmergedCommits.isEmpty && !store.isLoadingDiff {
                    Menu {
                        Button("Confluence") { store.exportUnmergedWorkAsConfluence() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if store.isLoadingDiff {
                    ProgressView().controlSize(.small)
                } else if isUnmergedMode {
                    if !store.unmergedCommits.isEmpty {
                        Text("\(store.unmergedCommits.count)")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if store.source != nil {
                    FilteredCountBadge(shown: filteredFiles.count, total: store.files.count)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // Body
            if store.source == nil {
                Text("Select a commit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = store.error {
                Text(err)
                    .font(.footnote).foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if isUnmergedMode {
                if store.unmergedCommits.isEmpty && !store.isLoadingDiff {
                    Text("No unmerged work found")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.unmergedCommits) { commit in
                        UnmergedCommitRow(
                            commit: commit,
                            isSelected: store.selectedUnmergedCommit?.oid == commit.oid
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectUnmergedCommit(commit) }
                    }
                    .listStyle(.plain)
                }
            } else if store.files.isEmpty && !store.isLoadingDiff {
                Text("No file changes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredFiles.isEmpty {
                Text("No files match the filter")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredFiles, selection: .constant(store.selectedFile?.index)) { file in
                    FileChangeRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectFile(file) }
                }
                .listStyle(.plain)
            }
        }
        .onChange(of: store.source) { filterText = "" }
    }
}

private struct FileChangeRow: View {
    let file: FileChange

    private var statusColor: Color {
        switch file.status {
        case "A": return .green
        case "D": return .red
        case "M": return .orange
        default:  return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 16, alignment: .center)
            Text(file.path)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text("-\(file.deletions)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One commit row in the "Commits with Work Not Found" list.
private struct UnmergedCommitRow: View {
    let commit: UnmergedCommit
    let isSelected: Bool

    private static let dateFormat = Date.FormatStyle()
        .year().month(.abbreviated).day()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(commit.authorName)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    Text(commit.time, format: Self.dateFormat)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    Text(commit.shortOid)
                        .fontDesign(.monospaced).foregroundStyle(.tertiary)
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

private struct DiffContentView: View {
    let store: CommitDiffStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if case .unmergedWork = store.source, let commit = store.selectedUnmergedCommit {
                        Text(commit.shortOid + " " + commit.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let path = store.fileDiff?.path ?? store.selectedFile?.path {
                        HStack(spacing: 4) {
                            if case .unmergedWork = store.source {
                                Text("First file:")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Text(path)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    } else if store.source == nil {
                        Text("Diff").font(.headline)
                    }
                }
                Spacer()
                if store.isLoadingFile {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if let diff = store.fileDiff {
                DiffTextView(lines: diff.lines)
            } else if (store.selectedFile != nil || store.selectedUnmergedCommit != nil) && store.isLoadingFile {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.source == nil {
                Text("Select a commit, then a file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .unmergedWork = store.source {
                Text("Select a commit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false

        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // No wrapping — long lines scroll horizontally, matching every diff viewer.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let storage = tv.textStorage else { return }
        let attr = Self.render(lines: lines)
        storage.setAttributedString(attr)
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private static func render(lines: [DiffLine]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Gutter width = digits needed for the largest line number we'll print.
        var maxNum = 1
        for line in lines {
            if line.oldLineno > maxNum { maxNum = line.oldLineno }
            if line.newLineno > maxNum { maxNum = line.newLineno }
        }
        let gutterWidth = max(2, String(maxNum).count)

        let out = NSMutableAttributedString()
        for line in lines {
            let prefix: String
            switch line.kind {
            case .insert:  prefix = "+"
            case .delete:  prefix = "-"
            case .hunk:    prefix = " "
            case .context: prefix = " "
            }

            let oldText = line.kind == .hunk ? "" : (line.oldLineno > 0 ? String(line.oldLineno) : "")
            let newText = line.kind == .hunk ? "" : (line.newLineno > 0 ? String(line.newLineno) : "")
            let gutter = "\(pad(oldText, gutterWidth)) \(pad(newText, gutterWidth)) "

            var rowBg: NSColor? = nil
            var contentFg = NSColor.labelColor
            switch line.kind {
            case .insert:  rowBg = NSColor.systemGreen.withAlphaComponent(0.18)
            case .delete:  rowBg = NSColor.systemRed.withAlphaComponent(0.18)
            case .hunk:    rowBg = NSColor.quaternaryLabelColor; contentFg = NSColor.secondaryLabelColor
            case .context: break
            }

            var gutterAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            if let rowBg { gutterAttrs[.backgroundColor] = rowBg }

            var contentAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: contentFg,
            ]
            if let rowBg { contentAttrs[.backgroundColor] = rowBg }

            out.append(NSAttributedString(string: gutter, attributes: gutterAttrs))
            let bodyStart = out.length + (prefix as NSString).length
            out.append(NSAttributedString(string: prefix + line.text + "\n", attributes: contentAttrs))
            applyHighlights(to: out, contentStart: bodyStart, text: line.text, spans: line.spans)
        }
        return out
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return String(repeating: " ", count: width - s.count) + s
    }

    /// Tree-sitter span kinds. Variables/operators stay default-colored to avoid visual noise.
    private static func color(for kind: UInt8) -> NSColor? {
        switch kind {
        case 0: return NSColor.systemPink            // keyword
        case 1: return NSColor.systemRed             // string
        case 2: return NSColor.systemGreen           // comment
        case 3: return NSColor.systemTeal            // type
        case 4: return NSColor.systemPurple          // function
        case 5: return NSColor.systemBlue            // number
        default: return nil
        }
    }

    private static func applyHighlights(
        to attr: NSMutableAttributedString,
        contentStart: Int,
        text: String,
        spans: [HighlightSpan]
    ) {
        guard !spans.isEmpty else { return }
        let utf8Count = text.utf8.count
        let utf16Count = text.utf16.count
        let isAscii = (utf8Count == utf16Count)

        for span in spans {
            let byteStart = Int(span.offset)
            let byteEnd = byteStart + Int(span.length)
            guard byteEnd <= utf8Count else { continue }
            guard let color = color(for: span.kind) else { continue }

            let utf16Start: Int
            let utf16End: Int
            if isAscii {
                utf16Start = byteStart
                utf16End = byteEnd
            } else {
                guard
                    let utf8Start = text.utf8.index(text.utf8.startIndex, offsetBy: byteStart, limitedBy: text.utf8.endIndex),
                    let utf8EndIdx = text.utf8.index(text.utf8.startIndex, offsetBy: byteEnd, limitedBy: text.utf8.endIndex),
                    let s16 = utf8Start.samePosition(in: text.utf16),
                    let e16 = utf8EndIdx.samePosition(in: text.utf16)
                else { continue }
                utf16Start = text.utf16.distance(from: text.utf16.startIndex, to: s16)
                utf16End = text.utf16.distance(from: text.utf16.startIndex, to: e16)
            }

            attr.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: contentStart + utf16Start, length: utf16End - utf16Start)
            )
        }
    }
}
