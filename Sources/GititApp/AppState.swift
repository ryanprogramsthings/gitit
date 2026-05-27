import AppKit
import Foundation
import Observation
import GititFFI

/// Plain-Swift projection of `GititFFI.RepoSummary`. We unwrap RustString/RustVec
/// at the FFI boundary so the UI works with idiomatic Swift types.
struct RepoOverview: Sendable {
    var path: URL
    var headOid: String
    var headName: String
    /// Non-empty when HEAD is detached on a tag — the checked-out tag's name.
    var headTag: String
    var branches: [BranchInfo]
    var remoteBranches: [BranchInfo]
    var tags: [String]
}

/// A branch tip, surfaced to the UI for the graph filter and the sidebar list.
struct BranchInfo: Identifiable, Hashable, Sendable {
    let name: String        // local: "main"; remote: "origin/main"
    let oid: String
    let isRemote: Bool
    /// For local refs only: a matching `origin/<name>` ref exists.
    let isTracked: Bool
    /// For tracked local refs: commits ahead of / behind `origin/<name>`.
    let ahead: UInt32
    let behind: UInt32
    var id: String { (isRemote ? "remote:" : "local:") + name }
}

enum RepoLoadState {
    case empty
    case loading(URL)
    case loaded(RepoOverview)
    case failed(URL, String)
}

struct Commit: Identifiable, Hashable, Sendable {
    let oid: String
    let summary: String
    let authorName: String
    let time: Date
    var id: String { oid }
    var shortOid: String { String(oid.prefix(8)) }
}

final class SessionHolder: @unchecked Sendable {
    var session: LogSession? = nil
}

/// One commit's position in the graph. `lane` is its row; `colorIndex` maps
/// to the palette in GraphView. `parents` is the parent oid list — used to
/// draw edges (which may cross lanes).
struct GraphCommit: Identifiable, Hashable, Sendable {
    let oid: String
    let time: Date
    let lane: UInt32
    let colorIndex: UInt32
    let parents: [String]
    var id: String { oid }
}

struct GraphTip: Hashable, Sendable {
    let name: String
    let oid: String
    let colorIndex: UInt32
    let isRemote: Bool
    let isTracked: Bool
    /// True when this tip is the checked-out tag (detached HEAD).
    let isTag: Bool
}

struct GraphSnapshot: Sendable {
    let commits: [GraphCommit]
    let tips: [GraphTip]
    /// Lookup: oid → index in `commits`. Used to draw parent edges without a linear scan.
    let indexByOid: [String: Int]
    /// `commits.map { $0.lane }.max() + 1`, capped at 1 when empty.
    let laneCount: Int
}

/// The subset of `GraphSnapshot` actually drawn: commits whose owning merged
/// branch is collapsed are removed, and lanes are re-packed to a gap-free
/// range. `commits` carry their re-packed lane; `indexByOid` indexes into it.
struct VisibleGraph: Sendable {
    let commits: [GraphCommit]
    let indexByOid: [String: Int]
    let laneCount: Int
}

@MainActor
@Observable
final class GraphStore {
    let repoPath: URL
    private(set) var availableBranches: [BranchInfo] = []
    private(set) var snapshot: GraphSnapshot?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Effective filter: ids of branches selected for inclusion.
    var enabledBranchIDs: Set<String> = []
    /// The checked-out local branch — forced to lane 0 (top) of the graph.
    private(set) var currentBranchName: String?
    /// The checked-out tag when HEAD is detached on one — also forced to lane 0.
    private(set) var currentTag: String?
    /// When true, every merge is expanded — all merged-in branches are drawn.
    var showMergedBranches: Bool = false
    /// Merge-commit oids the user expanded; their merged-in branches are drawn.
    var expandedMerges: Set<String> = []
    /// One-shot oid the graph should scroll to; cleared once consumed.
    var focusOid: String? = nil
    /// The drawn subset of `snapshot`, derived from the expand/collapse state.
    private(set) var visibleGraph: VisibleGraph?

    private let queue = DispatchQueue(label: "gitit.graph", qos: .userInitiated)
    private var loadGeneration: UInt64 = 0

    init(repoPath: URL) { self.repoPath = repoPath }

    /// Called on repo open and after a checkout: seeds available branches and
    /// the default filter — only the current (checked-out) branch.
    func configure(from overview: RepoOverview) {
        availableBranches = overview.branches + overview.remoteBranches
        currentBranchName = overview.headName.isEmpty ? nil : overview.headName
        currentTag = overview.headTag.isEmpty ? nil : overview.headTag
        enabledBranchIDs = overview.headName.isEmpty
            ? []
            : ["local:" + overview.headName]
        rebuild()
    }

    func setBranchEnabled(_ branch: BranchInfo, enabled: Bool) {
        if enabled { enabledBranchIDs.insert(branch.id) }
        else { enabledBranchIDs.remove(branch.id) }
        rebuild()
    }

    /// Re-derives the drawn graph — no `open_graph` rebuild needed.
    func setShowMergedBranches(_ value: Bool) {
        guard showMergedBranches != value else { return }
        showMergedBranches = value
        recomputeVisible()
    }

    /// Toggle a merge between expanded (its merged-in branch drawn) and
    /// collapsed (hidden). Expanding focuses the merged-in branch's tip.
    func toggleMerge(_ commit: GraphCommit) {
        if expandedMerges.remove(commit.oid) == nil {
            expandedMerges.insert(commit.oid)
            focusOid = commit.parents.dropFirst().first
        }
        recomputeVisible()
    }

    /// Rebuilds `visibleGraph`: a walk from the tips that follows only the
    /// first parent at a collapsed merge, then re-packs lanes gap-free. Runs
    /// on the main actor — fine at current commit counts; Phase 6 may move it.
    func recomputeVisible() {
        guard let snap = snapshot else { visibleGraph = nil; return }
        var visibleSet = Set<String>()
        var stack: [String] = snap.tips.map { $0.oid }
        while let oid = stack.popLast() {
            guard visibleSet.insert(oid).inserted else { continue }
            guard let idx = snap.indexByOid[oid] else { continue }
            let c = snap.commits[idx]
            let followAll = showMergedBranches
                || c.parents.count < 2
                || expandedMerges.contains(oid)
            if followAll {
                stack.append(contentsOf: c.parents)
            } else if let first = c.parents.first {
                stack.append(first)
            }
        }
        let kept = snap.commits.filter { visibleSet.contains($0.oid) }
        let usedLanes = Set(kept.map { $0.lane }).sorted()
        var remap: [UInt32: UInt32] = [:]
        for (i, lane) in usedLanes.enumerated() { remap[lane] = UInt32(i) }
        var commits: [GraphCommit] = []
        commits.reserveCapacity(kept.count)
        var indexByOid: [String: Int] = [:]
        indexByOid.reserveCapacity(kept.count)
        for (i, c) in kept.enumerated() {
            indexByOid[c.oid] = i
            commits.append(GraphCommit(
                oid: c.oid, time: c.time, lane: remap[c.lane] ?? 0,
                colorIndex: c.colorIndex, parents: c.parents
            ))
        }
        visibleGraph = VisibleGraph(
            commits: commits, indexByOid: indexByOid,
            laneCount: max(1, usedLanes.count)
        )
    }

    /// The resolved ref names currently filtered in — drives both `open_graph`
    /// and the History walk. The checked-out branch is forced first so the
    /// graph assigns it lane 0 (the top lane).
    var activeRefs: [String] {
        var refs = availableBranches.compactMap { enabledBranchIDs.contains($0.id) ? $0.name : nil }
        if let current = currentBranchName,
           let idx = refs.firstIndex(of: current), idx != 0 {
            refs.remove(at: idx)
            refs.insert(current, at: 0)
        }
        if let tag = currentTag {
            refs.insert(tag, at: 0)
        }
        return refs
    }

    func rebuild() {
        // Lane numbers and the commit set change on every rebuild.
        expandedMerges = []
        focusOid = nil
        let names = activeRefs
        guard !names.isEmpty else {
            snapshot = nil
            isLoading = false
            error = nil
            return
        }
        loadGeneration &+= 1
        let gen = loadGeneration
        let path = repoPath.path
        let currentTag = self.currentTag
        isLoading = true
        error = nil

        queue.async { [weak self] in
            guard let self else { return }
            do {
                // open_graph's swift-bridge signature unifies both string args
                // under one generic, so we pass RustString explicitly to keep
                // the Vec element type compatible.
                let pathRS = RustString(path)
                let nameVec = RustVec<RustString>()
                for n in names { nameVec.push(value: RustString(n)) }
                let g = try open_graph(pathRS, nameVec)
                // Pull all columnar arrays once.
                let oids   = g.oids().map   { $0.as_str().toString() }
                let times  = g.times().map  { $0 }
                let lanes  = g.lanes().map  { $0 }
                let colors = g.colors().map { $0 }
                let pStart = g.parent_starts().map { $0 }
                let pOids  = g.parent_oids().map { $0.as_str().toString() }
                let tnames = g.tip_names().map  { $0.as_str().toString() }
                let toids  = g.tip_oids().map   { $0.as_str().toString() }
                let tcols  = g.tip_colors().map { $0 }
                let trem   = g.tip_is_remote().map  { $0 }
                let ttrk   = g.tip_is_tracked().map { $0 }

                var commits: [GraphCommit] = []
                commits.reserveCapacity(oids.count)
                var indexByOid: [String: Int] = [:]
                indexByOid.reserveCapacity(oids.count)
                for i in 0..<oids.count {
                    let lo = Int(pStart[i])
                    let hi = Int(pStart[i + 1])
                    let parents = (lo < hi) ? Array(pOids[lo..<hi]) : []
                    let oid = oids[i]
                    indexByOid[oid] = i
                    commits.append(GraphCommit(
                        oid: oid,
                        time: Date(timeIntervalSince1970: TimeInterval(times[i])),
                        lane: lanes[i],
                        colorIndex: colors[i],
                        parents: parents
                    ))
                }
                let tips: [GraphTip] = (0..<tnames.count).map { i in
                    GraphTip(
                        name: tnames[i],
                        oid: toids[i],
                        colorIndex: tcols[i],
                        isRemote: trem[i] != 0,
                        isTracked: ttrk[i] != 0,
                        isTag: tnames[i] == currentTag
                    )
                }
                let laneCount = max(1, Int((lanes.max() ?? 0)) + 1)
                let snap = GraphSnapshot(
                    commits: commits, tips: tips,
                    indexByOid: indexByOid, laneCount: laneCount
                )
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.snapshot = snap
                    self.recomputeVisible()
                    self.isLoading = false
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoading = false
                    self.snapshot = nil
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoading = false
                    self.snapshot = nil
                }
            }
        }
    }
}

enum DiffLineKind: UInt8, Sendable {
    case context = 0
    case insert  = 1
    case delete  = 2
    case hunk    = 3
}

/// Syntax-highlighted span within a diff line's text. Offset and length are
/// in UTF-8 bytes, matching tree-sitter's source positions.
struct HighlightSpan: Hashable, Sendable {
    let offset: UInt32
    let length: UInt32
    let kind: UInt8     // 0 keyword, 1 string, 2 comment, 3 type, 4 function, 5 number, 6 variable, 7 operator
}

struct DiffLine: Identifiable, Hashable, Sendable {
    let index: Int
    let kind: DiffLineKind
    let oldLineno: Int      // -1 if N/A
    let newLineno: Int      // -1 if N/A
    let text: String
    let spans: [HighlightSpan]
    var id: Int { index }
}

struct FileChange: Identifiable, Hashable, Sendable {
    let index: UInt32
    let path: String
    let status: String       // "A" | "M" | "D"
    let additions: UInt32
    let deletions: UInt32
    var id: UInt32 { index }
}

/// A commit identified as having introduced lines not present in the comparison ref.
struct UnmergedCommit: Identifiable, Hashable, Sendable {
    let oid: String
    let summary: String
    let authorName: String
    let time: Date
    var id: String { oid }
    var shortOid: String { String(oid.prefix(8)) }
}

struct FileDiffModel: Sendable {
    let path: String
    let lines: [DiffLine]
}

final class CommitDiffHolder: @unchecked Sendable {
    var session: CommitDiff? = nil
}

@MainActor
@Observable
final class CommitDiffStore {
    /// What the loaded diff represents: a single commit (vs. its first parent)
    /// or a direct comparison between two refs.
    enum DiffSource: Equatable {
        case commit(String)                          // commit oid
        case range(old: String, new: String)         // ref names (compare mode)
        case unmergedWork(refA: String, refB: String) // blame-based unmerged work
    }

    let repoPath: URL
    private(set) var source: DiffSource?
    private(set) var files: [FileChange] = []
    private(set) var selectedFile: FileChange?
    private(set) var fileDiff: FileDiffModel?
    private(set) var isLoadingDiff = false
    private(set) var isLoadingFile = false
    private(set) var error: String?
    /// Commits populated in `.unmergedWork` mode.
    private(set) var unmergedCommits: [UnmergedCommit] = []
    /// The commit whose diff is shown in the bottom pane during `.unmergedWork` mode.
    private(set) var selectedUnmergedCommit: UnmergedCommit?

    private let queue = DispatchQueue(label: "gitit.commitdiff", qos: .userInitiated)
    private let holder = CommitDiffHolder()
    /// Separate holder for the commit diff shown when a user taps an unmerged commit,
    /// so the unmerged commit list isn't discarded.
    private let unmergedDiffHolder = CommitDiffHolder()
    /// Bumped on every load; async completions check it to drop stale results.
    private var loadGeneration = 0

    init(repoPath: URL) {
        self.repoPath = repoPath
    }

    func loadDiff(for oid: String) {
        if source == .commit(oid) { return }
        load(source: .commit(oid)) { try open_commit_diff($0, oid) }
    }

    /// Load a direct tree diff between two refs (branches or tags).
    func loadRangeDiff(old: String, new: String) {
        let next = DiffSource.range(old: old, new: new)
        if source == next { return }
        load(source: next) { try open_range_diff($0, old, new) }
    }

    /// Blame-based unmerged work: for each line in refA not present in refB,
    /// find the commit in refA's history that introduced it.
    func loadUnmergedWork(refA: String, refB: String) {
        let next = DiffSource.unmergedWork(refA: refA, refB: refB)
        if source == next { return }
        source = next
        files = []
        unmergedCommits = []
        selectedFile = nil
        selectedUnmergedCommit = nil
        fileDiff = nil
        error = nil
        isLoadingDiff = true
        loadGeneration += 1
        let gen = loadGeneration
        let path = repoPath.path

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try open_unmerged_work(path, refA, refB)
                let oids      = result.oids().map { $0.as_str().toString() }
                let summaries = result.summaries().map { $0.as_str().toString() }
                let authors   = result.authors().map { $0.as_str().toString() }
                let times     = result.times().map { $0 }
                var commits: [UnmergedCommit] = []
                commits.reserveCapacity(oids.count)
                for i in 0..<oids.count {
                    commits.append(UnmergedCommit(
                        oid: oids[i],
                        summary: summaries[i],
                        authorName: authors[i],
                        time: Date(timeIntervalSince1970: TimeInterval(times[i]))
                    ))
                }
                let captured = commits
                let first = captured.first
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.unmergedCommits = captured
                    self.isLoadingDiff = false
                    if let first { self.selectUnmergedCommit(first) }
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingDiff = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingDiff = false
                }
            }
        }
    }

    /// Select a commit from the unmerged-work list and show its first file's diff
    /// in the bottom pane. Does NOT change `source` or `unmergedCommits`.
    func selectUnmergedCommit(_ commit: UnmergedCommit) {
        guard selectedUnmergedCommit?.oid != commit.oid else { return }
        selectedUnmergedCommit = commit
        fileDiff = nil
        selectedFile = nil
        isLoadingFile = true
        let path = repoPath.path
        let holder = self.unmergedDiffHolder
        let gen = loadGeneration

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = try open_commit_diff(path, commit.oid)
                holder.session = session
                guard session.file_count() > 0 else {
                    Task { @MainActor in
                        guard self.loadGeneration == gen else { return }
                        self.isLoadingFile = false
                    }
                    return
                }
                let fd = try session.open_file_diff(0)
                let filePath = session.file_path(0).toString()
                let kinds  = fd.line_kinds().map { $0 }
                let olds   = fd.line_old().map { $0 }
                let news   = fd.line_new().map { $0 }
                let texts  = fd.line_text().map { $0.as_str().toString() }
                let hlSt   = fd.hl_starts().map  { $0 }
                let hlOff  = fd.hl_offsets().map { $0 }
                let hlLen  = fd.hl_lengths().map { $0 }
                let hlKind = fd.hl_kinds().map   { $0 }
                var lines: [DiffLine] = []
                lines.reserveCapacity(kinds.count)
                for i in 0..<kinds.count {
                    let spanLo = Int(hlSt[i])
                    let spanHi = Int(hlSt[i + 1])
                    var spans: [HighlightSpan] = []
                    if spanHi > spanLo {
                        spans.reserveCapacity(spanHi - spanLo)
                        for j in spanLo..<spanHi {
                            spans.append(HighlightSpan(offset: hlOff[j], length: hlLen[j], kind: hlKind[j]))
                        }
                    }
                    lines.append(DiffLine(
                        index: i,
                        kind: DiffLineKind(rawValue: kinds[i]) ?? .context,
                        oldLineno: Int(olds[i]),
                        newLineno: Int(news[i]),
                        text: texts[i],
                        spans: spans
                    ))
                }
                let model = FileDiffModel(path: filePath, lines: lines)
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.fileDiff = model
                    self.isLoadingFile = false
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingFile = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingFile = false
                }
            }
        }
    }

    /// Build a Confluence wiki-markup table of the current unmerged commits and
    /// copy it to the system clipboard. No-op outside unmergedWork mode or when
    /// the list is empty.
    func exportUnmergedWorkAsConfluence() {
        guard case .unmergedWork(_, let refB) = source else { return }
        guard !unmergedCommits.isEmpty else { return }

        func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }

        var lines: [String] = []
        lines.append("||Author||Team||Commit||\(escape(refB))||Comments||")
        for c in unmergedCommits {
            let author  = escape(c.authorName)
            let summary = escape(c.summary)
            let commit  = "{{\(c.shortOid)}} \(summary)"
            lines.append("|\(author)| |\(commit)|{status:colour=Red|title=NOT MERGED}| |")
        }
        let text = lines.joined(separator: "\n")

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func load(source: DiffSource, _ makeSession: @escaping @Sendable (String) throws -> CommitDiff) {
        self.source = source
        files = []
        selectedFile = nil
        fileDiff = nil
        error = nil
        isLoadingDiff = true
        loadGeneration += 1
        let gen = loadGeneration

        let path = repoPath.path
        let holder = self.holder
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = try makeSession(path)
                holder.session = session
                let count = session.file_count()
                var rows: [FileChange] = []
                rows.reserveCapacity(Int(count))
                for i in 0..<count {
                    rows.append(FileChange(
                        index: i,
                        path: session.file_path(i).toString(),
                        status: session.file_status(i).toString(),
                        additions: session.file_additions(i),
                        deletions: session.file_deletions(i)
                    ))
                }
                let captured = rows
                let first = rows.first
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.files = captured
                    self.isLoadingDiff = false
                    if let first { self.selectFile(first) }
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingDiff = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.loadGeneration == gen else { return }
                    self.error = msg
                    self.isLoadingDiff = false
                }
            }
        }
    }

    func selectFile(_ file: FileChange) {
        guard selectedFile?.index != file.index else { return }
        selectedFile = file
        fileDiff = nil
        isLoadingFile = true
        let holder = self.holder
        let gen = loadGeneration
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = holder.session else { return }
            do {
                let fd = try session.open_file_diff(file.index)
                let kinds  = fd.line_kinds().map { $0 }
                let olds   = fd.line_old().map { $0 }
                let news   = fd.line_new().map { $0 }
                let texts  = fd.line_text().map { $0.as_str().toString() }
                let hlSt   = fd.hl_starts().map  { $0 }
                let hlOff  = fd.hl_offsets().map { $0 }
                let hlLen  = fd.hl_lengths().map { $0 }
                let hlKind = fd.hl_kinds().map   { $0 }
                var lines: [DiffLine] = []
                lines.reserveCapacity(kinds.count)
                for i in 0..<kinds.count {
                    let spanLo = Int(hlSt[i])
                    let spanHi = Int(hlSt[i + 1])
                    var spans: [HighlightSpan] = []
                    if spanHi > spanLo {
                        spans.reserveCapacity(spanHi - spanLo)
                        for j in spanLo..<spanHi {
                            spans.append(HighlightSpan(offset: hlOff[j], length: hlLen[j], kind: hlKind[j]))
                        }
                    }
                    lines.append(DiffLine(
                        index: i,
                        kind: DiffLineKind(rawValue: kinds[i]) ?? .context,
                        oldLineno: Int(olds[i]),
                        newLineno: Int(news[i]),
                        text: texts[i],
                        spans: spans
                    ))
                }
                let model = FileDiffModel(path: file.path, lines: lines)
                Task { @MainActor in
                    guard self.loadGeneration == gen, self.selectedFile?.index == file.index else { return }
                    self.fileDiff = model
                    self.isLoadingFile = false
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.loadGeneration == gen, self.selectedFile?.index == file.index else { return }
                    self.error = msg
                    self.isLoadingFile = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.loadGeneration == gen, self.selectedFile?.index == file.index else { return }
                    self.error = msg
                    self.isLoadingFile = false
                }
            }
        }
    }
}

@MainActor
@Observable
final class LogPager {
    let repoPath: URL
    private(set) var commits: [Commit] = []
    private(set) var hasMore = true
    private(set) var isLoading = false
    private(set) var isWalking = false
    private(set) var error: String?
    private(set) var totalKnown: UInt32 = 0

    private var refNames: [String] = []
    private let pageSize: UInt32 = 500
    private let queue = DispatchQueue(label: "gitit.logpager", qos: .userInitiated)
    private var holder = SessionHolder()
    /// Bumped on every `reload`; stale background results are discarded.
    private var generation = 0

    init(repoPath: URL) {
        self.repoPath = repoPath
    }

    /// Restart the walk scoped to `refNames` (the active branch filter).
    /// An empty list makes the Rust session fall back to HEAD.
    func reload(refNames: [String]) {
        self.refNames = refNames
        generation += 1
        holder = SessionHolder()
        commits = []
        hasMore = true
        isLoading = false
        isWalking = false
        error = nil
        totalKnown = 0
        loadNext()
    }

    func loadNext() {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let path = repoPath.path
        let pageSize = self.pageSize
        let holder = self.holder
        let refNames = self.refNames
        let gen = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if holder.session == nil {
                    let pathRS = RustString(path)
                    let nameVec = RustVec<RustString>()
                    for n in refNames { nameVec.push(value: RustString(n)) }
                    holder.session = try open_log(pathRS, nameVec)
                }
                let session = holder.session!

                // First call after open may race the walker: spin briefly until either
                // the walker has produced some rows or it has finished entirely.
                var batch = session.next_batch(pageSize)
                var batchCount = batch.len()
                var attempts = 0
                while batchCount == 0 && session.is_walking() && attempts < 40 {
                    Thread.sleep(forTimeInterval: 0.025)
                    batch = session.next_batch(pageSize)
                    batchCount = batch.len()
                    attempts += 1
                }

                let oids = batch.oids().map { $0.as_str().toString() }
                let summaries = batch.summaries().map { $0.as_str().toString() }
                let authors = batch.authors().map { $0.as_str().toString() }
                let times = batch.times().map { $0 }
                var newCommits: [Commit] = []
                newCommits.reserveCapacity(oids.count)
                for i in 0..<oids.count {
                    newCommits.append(Commit(
                        oid: oids[i],
                        summary: summaries[i],
                        authorName: authors[i],
                        time: Date(timeIntervalSince1970: TimeInterval(times[i]))
                    ))
                }

                let walking = session.is_walking()
                let total = session.total()
                let remaining = session.remaining()
                let captured = newCommits
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.commits.append(contentsOf: captured)
                    self.totalKnown = total
                    self.isWalking = walking
                    self.hasMore = walking || remaining > 0
                    self.isLoading = false
                    // Auto-drive while the walker is still producing — first
                    // page appears immediately and the rest streams in.
                    if walking {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            self.loadNext()
                        }
                    }
                }
            } catch let err as RustString {
                let msg = err.toString()
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.error = msg
                    self.isLoading = false
                    self.hasMore = false
                    self.isWalking = false
                }
            } catch {
                let msg = "\(error)"
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.error = msg
                    self.isLoading = false
                    self.hasMore = false
                    self.isWalking = false
                }
            }
        }
    }
}

@MainActor
@Observable
final class AppState {
    var state: RepoLoadState = .empty
    /// Set when a checkout fails; the UI presents it and clears it.
    var checkoutError: String?

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        state = .loading(url)
        Task.detached(priority: .userInitiated) {
            let nextState = Self.fetchOverview(url)
            await MainActor.run { self.state = nextState }
        }
    }

    /// Re-reads the repo summary in place — used after a checkout so HEAD, the
    /// current-branch indicator, and ahead/behind badges reflect the new state.
    func refresh() {
        guard case let .loaded(current) = state else { return }
        let url = current.path
        Task.detached(priority: .userInitiated) {
            let nextState = Self.fetchOverview(url)
            await MainActor.run { self.state = nextState }
        }
    }

    /// Checks out `branch` (shells to `git checkout`), then refreshes the
    /// summary on success or surfaces the error on failure.
    func checkout(_ branch: String) {
        guard case let .loaded(current) = state else { return }
        let url = current.path
        Task.detached(priority: .userInitiated) {
            do {
                try checkout_branch(RustString(url.path), RustString(branch))
            } catch let err as RustString {
                await MainActor.run { self.checkoutError = err.toString() }
                return
            } catch {
                await MainActor.run { self.checkoutError = "\(error)" }
                return
            }
            let nextState = Self.fetchOverview(url)
            await MainActor.run { self.state = nextState }
        }
    }

    /// Reads a repository summary and projects it into a `RepoLoadState`.
    private nonisolated static func fetchOverview(_ url: URL) -> RepoLoadState {
        do {
            let summary = try repo_summary(url.path)
            let names    = summary.branches.map        { $0.as_str().toString() }
            let oids     = summary.branch_oids.map     { $0.as_str().toString() }
            let tracked  = summary.branch_tracked.map  { $0 }
            let ahead    = summary.branch_ahead.map    { $0 }
            let behind   = summary.branch_behind.map   { $0 }
            let rNames   = summary.remote_branches.map     { $0.as_str().toString() }
            let rOids    = summary.remote_branch_oids.map  { $0.as_str().toString() }

            let locals: [BranchInfo] = (0..<names.count).map { i in
                BranchInfo(
                    name: names[i], oid: oids[i], isRemote: false,
                    isTracked: tracked[i] != 0, ahead: ahead[i], behind: behind[i]
                )
            }
            let remotes: [BranchInfo] = (0..<rNames.count).map { i in
                BranchInfo(
                    name: rNames[i], oid: rOids[i], isRemote: true,
                    isTracked: true, ahead: 0, behind: 0
                )
            }

            let overview = RepoOverview(
                path: url,
                headOid: summary.head_oid.toString(),
                headName: summary.head_name.toString(),
                headTag: summary.head_tag.toString(),
                branches: locals,
                remoteBranches: remotes,
                tags: summary.tags.map { $0.as_str().toString() }
            )
            return .loaded(overview)
        } catch let err as RustString {
            return .failed(url, err.toString())
        } catch {
            return .failed(url, "\(error)")
        }
    }
}

/// Regex patterns that scope which refs a repository shows in the sidebar.
/// An empty list for a ref kind means "show all" — no filtering.
struct RepoFilterPatterns: Codable, Equatable, Sendable {
    var local: [String] = []
    var remote: [String] = []
    var tags: [String] = []
}

/// Per-repository ref-filter patterns, persisted as one JSON blob in
/// `UserDefaults` and observed by both the Settings UI and the sidebar.
@MainActor
@Observable
final class FilterSettings {
    /// Patterns keyed by repository path (`URL.path`).
    private(set) var byRepo: [String: RepoFilterPatterns] = [:]

    init() {
        guard let data = UserDefaults.standard.data(forKey: UIDefaultsKey.refFilters),
              let decoded = try? JSONDecoder().decode([String: RepoFilterPatterns].self, from: data)
        else { return }
        byRepo = decoded
    }

    func patterns(for path: String) -> RepoFilterPatterns {
        byRepo[path] ?? RepoFilterPatterns()
    }

    func setPatterns(_ patterns: RepoFilterPatterns, for path: String) {
        byRepo[path] = patterns
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(byRepo) else { return }
        UserDefaults.standard.set(data, forKey: UIDefaultsKey.refFilters)
    }
}
