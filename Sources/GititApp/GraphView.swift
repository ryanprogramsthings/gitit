import AppKit
import SwiftUI

/// Horizontal branch graph. X = commit index in walk order (most recent on the
/// left), Y = lane. Edges are drawn from each commit to each parent; same-lane
/// edges are straight, cross-lane edges curve.
///
/// Local-only branches (no `origin/<name>` counterpart) render with dashed
/// edges and an open ring at the tip. Tracked locals and remotes render with
/// solid edges and a filled dot.
struct GraphView: View {
    let visible: VisibleGraph
    let tips: [GraphTip]
    @Binding var selection: String?
    @Binding var focusOid: String?

    // Layout constants.
    private static let commitDX: CGFloat = 14
    private static let laneDY: CGFloat = 22
    private static let dotRadius: CGFloat = 4
    private static let topMargin: CGFloat = 28
    private static let leftMargin: CGFloat = 12
    private static let gutterWidth: CGFloat = 132

    /// `colorIndex` values whose owning tip is a local-only branch (no remote).
    /// Rendered with dashed edges + open rings.
    private var localOnlyColors: Set<UInt32> {
        Set(tips.filter { !$0.isRemote && !$0.isTracked }.map { $0.colorIndex })
    }

    /// Set of oids that are a tip of at least one ref. Multiple refs can share
    /// the same commit (e.g. `main` and `origin/main` after a fresh pull) so we
    /// keep this as a Set rather than a name lookup.
    private var tipOids: Set<String> {
        Set(tips.map { $0.oid })
    }

    private var totalWidth: CGFloat {
        Self.leftMargin * 2 + CGFloat(visible.commits.count) * Self.commitDX
    }
    private var totalHeight: CGFloat {
        Self.topMargin + CGFloat(visible.laneCount) * Self.laneDY
    }

    var body: some View {
        HStack(spacing: 0) {
            laneGutter
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    Canvas { ctx, size in
                        drawDateHeader(in: ctx, size: size)
                        drawEdges(in: ctx)
                        drawCommits(in: ctx)
                        drawSelection(in: ctx)
                    }
                    .frame(width: totalWidth, height: totalHeight)
                    .overlay(alignment: .topLeading) { focusAnchor }
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                if let oid = hitTest(at: event.location) {
                                    selection = oid
                                }
                            }
                    )
                }
                .onChange(of: focusOid) { _, new in
                    guard let new, visible.indexByOid[new] != nil else { return }
                    withAnimation(.easeInOut) {
                        proxy.scrollTo("graph.focusAnchor", anchor: .center)
                    }
                    // Clear after the anchor has rendered so the scroll lands.
                    DispatchQueue.main.async { focusOid = nil }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// A 1pt scroll target placed at the focused commit's x. The leading
    /// spacer is real layout (an `.offset` would not move the frame, so
    /// `scrollTo` would ignore it).
    @ViewBuilder private var focusAnchor: some View {
        if let focusOid, let idx = visible.indexByOid[focusOid] {
            HStack(spacing: 0) {
                Color.clear.frame(width: position(forIndex: idx, lane: 0).x, height: 1)
                Color.clear.frame(width: 1, height: 1).id("graph.focusAnchor")
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Lane labels

    /// One branch name pinned to the left of the lane it owns.
    private struct LaneLabel: Identifiable {
        let lane: UInt32
        let name: String
        let colorIndex: UInt32
        let isTag: Bool
        var id: UInt32 { lane }
    }

    /// Lane → branch name, over the *visible* graph only.
    ///
    /// Every commit a tip's first-parent pass claims carries that tip's
    /// `colorIndex`, and each tip has a unique color — so a lane is owned by
    /// the tip whose color its commits carry. Matching on color (rather than
    /// on where a tip's commit happens to land) avoids mislabeling a lane when
    /// a tip is subsumed into another branch's or a merged-in lane. A lane
    /// whose color belongs to no tip is an expanded merged-in branch: it takes
    /// the name of a ref still sitting on its head commit, else `[deleted]`.
    private var laneLabels: [LaneLabel] {
        let v = visible
        // Commits arrive head-first in topo order, so the first commit seen
        // for a lane is its head.
        var colorOfLane: [UInt32: UInt32] = [:]
        var headOidOfLane: [UInt32: String] = [:]
        for c in v.commits where colorOfLane[c.lane] == nil {
            colorOfLane[c.lane] = c.colorIndex
            headOidOfLane[c.lane] = c.oid
        }
        var nameOfColor: [UInt32: String] = [:]
        var nameOfTipOid: [String: String] = [:]
        var isTagOfColor: [UInt32: Bool] = [:]
        var isTagOfTipOid: [String: Bool] = [:]
        for tip in tips {
            nameOfColor[tip.colorIndex] = tip.name
            nameOfTipOid[tip.oid] = tip.name
            isTagOfColor[tip.colorIndex] = tip.isTag
            isTagOfTipOid[tip.oid] = tip.isTag
        }
        var labels: [LaneLabel] = []
        for (lane, color) in colorOfLane {
            let name = nameOfColor[color]
                ?? headOidOfLane[lane].flatMap { nameOfTipOid[$0] }
                ?? "[deleted]"
            let isTag = isTagOfColor[color]
                ?? headOidOfLane[lane].flatMap { isTagOfTipOid[$0] }
                ?? false
            labels.append(LaneLabel(lane: lane, name: name, colorIndex: color, isTag: isTag))
        }
        return labels.sorted { $0.lane < $1.lane }
    }

    private var laneGutter: some View {
        ZStack(alignment: .topLeading) {
            ForEach(laneLabels) { label in
                HStack(spacing: 3) {
                    if label.isTag {
                        Image(systemName: "tag").font(.system(size: 9))
                    }
                    Text(label.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(palette(label.colorIndex))
                .frame(width: Self.gutterWidth - 12, height: Self.laneDY, alignment: .trailing)
                .padding(.trailing, 8)
                .offset(y: Self.topMargin + CGFloat(label.lane) * Self.laneDY)
            }
        }
        .frame(width: Self.gutterWidth, height: totalHeight, alignment: .topLeading)
    }

    // MARK: - Drawing

    private func drawEdges(in ctx: GraphicsContext) {
        for (i, commit) in visible.commits.enumerated() {
            let p = position(forIndex: i, lane: commit.lane)
            let dashed = localOnlyColors.contains(commit.colorIndex)
            let color = palette(commit.colorIndex)

            for parentOid in commit.parents {
                // A parent missing from the visible set belongs to a collapsed
                // merged branch — its edge is intentionally not drawn.
                guard let pIdx = visible.indexByOid[parentOid] else { continue }
                let parent = visible.commits[pIdx]
                let q = position(forIndex: pIdx, lane: parent.lane)
                let edgeColor = palette(parent.colorIndex)
                let edgeDashed = localOnlyColors.contains(parent.colorIndex) || dashed

                var path = Path()
                path.move(to: p)
                if commit.lane == parent.lane {
                    path.addLine(to: q)
                } else {
                    // Smooth S-curve between two lanes. Control points pulled
                    // toward each end horizontally so the bend has some flesh
                    // on it rather than a sharp corner.
                    let midX = (p.x + q.x) / 2
                    let c1 = CGPoint(x: midX, y: p.y)
                    let c2 = CGPoint(x: midX, y: q.y)
                    path.addCurve(to: q, control1: c1, control2: c2)
                }
                let style = StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    dash: edgeDashed ? [3, 3] : []
                )
                ctx.stroke(path, with: .color(edgeColor), style: style)
                _ = color // silence unused-color warning while we keep edges parent-colored
            }
        }
    }

    private func drawCommits(in ctx: GraphicsContext) {
        for (i, commit) in visible.commits.enumerated() {
            let p = position(forIndex: i, lane: commit.lane)
            let color = palette(commit.colorIndex)
            let isTip = tipOids.contains(commit.oid)
            let isLocalOnly = localOnlyColors.contains(commit.colorIndex)
            let rect = CGRect(
                x: p.x - Self.dotRadius,
                y: p.y - Self.dotRadius,
                width: Self.dotRadius * 2,
                height: Self.dotRadius * 2
            )
            let circle = Path(ellipseIn: rect)
            // Open ring for local-only tips, filled dot otherwise. Non-tip
            // commits still get the smaller filled dot.
            if isTip && isLocalOnly {
                ctx.fill(circle, with: .color(Color(nsColor: .textBackgroundColor)))
                ctx.stroke(circle, with: .color(color), lineWidth: 1.8)
            } else {
                ctx.fill(circle, with: .color(color))
                if isTip {
                    // Outer ring marks ref tips so they're distinguishable from
                    // intermediate commits at a glance.
                    let ring = Path(ellipseIn: rect.insetBy(dx: -2, dy: -2))
                    ctx.stroke(ring, with: .color(color), lineWidth: 1.2)
                }
            }
        }
    }

    private func drawSelection(in ctx: GraphicsContext) {
        guard let selection,
              let i = visible.indexByOid[selection] else { return }
        let commit = visible.commits[i]
        let p = position(forIndex: i, lane: commit.lane)
        let ring = Path(ellipseIn: CGRect(
            x: p.x - Self.dotRadius - 4,
            y: p.y - Self.dotRadius - 4,
            width: (Self.dotRadius + 4) * 2,
            height: (Self.dotRadius + 4) * 2
        ))
        ctx.stroke(ring, with: .color(Color(nsColor: .selectedControlColor)), lineWidth: 2)
    }

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d ''yy"
        return f
    }()

    private func drawDateHeader(in ctx: GraphicsContext, size: CGSize) {
        // Sparse date labels along the top — every ~80 columns. Saves space
        // on a graph with hundreds of commits.
        guard !visible.commits.isEmpty else { return }
        let count = visible.commits.count
        let step = max(1, count / max(1, Int(size.width / 80)))
        var i = 0
        while i < count {
            let commit = visible.commits[i]
            let x = position(forIndex: i, lane: 0).x
            let label = Self.headerFormatter.string(from: commit.time)
            let text = Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            ctx.draw(text, at: CGPoint(x: x, y: 10), anchor: .center)
            i += step
        }
    }

    // MARK: - Hit testing

    private func hitTest(at point: CGPoint) -> String? {
        // Linear scan is fine for first cut. With viewport culling later we'll
        // be able to bound this naturally.
        let r2 = (Self.dotRadius + 3) * (Self.dotRadius + 3)
        for (i, commit) in visible.commits.enumerated() {
            let p = position(forIndex: i, lane: commit.lane)
            let dx = p.x - point.x
            let dy = p.y - point.y
            if dx * dx + dy * dy <= r2 {
                return commit.oid
            }
        }
        return nil
    }

    private func position(forIndex i: Int, lane: UInt32) -> CGPoint {
        CGPoint(
            x: Self.leftMargin + CGFloat(i) * Self.commitDX,
            y: Self.topMargin + (CGFloat(lane) + 0.5) * Self.laneDY
        )
    }

    /// 12-entry palette. Wraps for color indices >= 12.
    private func palette(_ idx: UInt32) -> Color {
        let palette: [Color] = [
            .blue, .orange, .green, .purple, .pink, .teal,
            .red, .indigo, .yellow, .mint, .cyan, .brown,
        ]
        return palette[Int(idx) % palette.count]
    }
}
