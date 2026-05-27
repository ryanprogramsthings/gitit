# gitit — phased plan & status

A fast Mac-native git client for large monorepos. Swift + SwiftUI shell, Rust
`gix` (gitoxide) core, FFI via `swift-bridge`. See `CLAUDE.md` for the stack
rationale and the FFI boundary rule ("data, not handles").

## Status snapshot

| Phase | Title                                             | Status        |
| ----- | ------------------------------------------------- | ------------- |
| 1     | Foundation: repo open, refs, streaming log view   | done          |
| 2     | Diff viewer w/ Swift+Kotlin syntax highlighting   | done          |
| 3     | Horizontal branch graph                           | done          |
| 4     | Pane layout: resizable + collapsible              | done          |
| 5     | Fork-style left pane                              | done          |
| 6     | Determine Work Not Merged                         | done          |
| 7     | Settings window + ref filtering                   | **next**      |
| 8     | Working tree ops + cherry-pick                    | pending       |
| 9     | Performance + polish                              | pending       |

Update this table whenever a phase flips. Don't edit the per-phase sections
below except to mark sub-items done — they're the durable record of what each
phase covered.

## Phase 1 — Foundation ✅

Goal: open a repo, see refs, scroll a commit log streamed from Rust.

- SwiftPM + Cargo workspace, swift-bridge wired with hello round-trip
- `core/repo.rs` — open repo, enumerate branches/tags/HEAD
- `core/log.rs` — stateful `LogSession` with concurrent walker thread, drop-cancellation
- `GititUI/LogView` — virtualized list, auto-drives via `is_walking`
- Commits: `de885a1`, `2473cd0`, `6820d46`, `96e18a1`, `75ea44f`

## Phase 2 — Diff viewer + syntax highlighting ✅

Goal: pick a commit, see its tree-vs-first-parent diff, syntax-highlighted.

- `core/diff.rs` — `CommitDiff` via gix `for_each_to_obtain_tree`; per-file
  unified hunks via `similar::TextDiff`; columnar FFI
- `core/highlight.rs` — tree-sitter Swift + Kotlin; captures classified into
  keyword/string/comment/type/function/number/variable/operator
- `FileDiff` carries CSR-style per-line highlight spans (`hl_starts`,
  `hl_offsets`, `hl_lengths`, `hl_kinds`)
- `DiffTextView` — `NSTextView` via `NSViewRepresentable`, line-number gutter,
  +/- row tints, per-span foreground colors with UTF-8→UTF-16 mapping
- `MACOSX_DEPLOYMENT_TARGET=14.0` pinned in `build-rust.sh` for tree-sitter C
- Commits: `c6fd7fe`, `eae6a2d`, `1d2078a`, `e09adb1`

Deferred items (worth revisiting before Phase 3 if a session has slack):

- Side-by-side diff toggle (you opted for unified-only in 2a)
- Binary/large-file handling (currently `from_utf8_lossy` produces gibberish
  for binaries)
- Gutter that excludes line numbers from selection (NSRulerView) — copy-paste
  currently includes the gutter
- Profile the ~190ms tree-sitter pass on a debug build; release should be fine
  but worth confirming

## Phase 3 — Horizontal branch graph ✅

Goal: the differentiating UI. Lane on Y, time-ordered commits on X, edges
include merge curves.

Design decisions settled at start of phase:

- **Layout:** graph above the log in a VSplitView; selection shared via
  `selectedOid`. Graph is the differentiator, log stays as the dense
  searchable chooser.
- **Lane assignment:** first-parent ownership from each branch tip in
  priority order (HEAD first). Each tip claims a fresh lane and a fresh
  palette color. Merged-in second-parent ancestry claims a new lane on
  encounter.
- **Local vs remote:** local branches without an `origin/<name>` counterpart
  render with dashed edges + open ring at the tip; tracked locals and remote
  refs render as solid edges + filled dot.
- **Filter:** sidebar checkbox per branch + master toggles "Show local
  branches" / "Show remote branches". Defaults: HEAD + all locals on,
  remotes off.

Implementation:

- `core/graph.rs` — lane/color assignment, columnar FFI output. Takes a list
  of ref names; returns `(oid, time, lane, color, parents_csr)` per commit
  plus per-tip metadata (name, color, is_remote, is_tracked).
- `GraphView` (in `GititApp/`) — SwiftUI `Canvas`, viewport-aware. X = commit
  index (with coarse date header), Y = lane. Click-to-select drives the
  shared `selectedOid`.
- `RepoSidebar` — branch list becomes a filterable checkbox list with
  local/remote sections and a tracked indicator.
- `GraphView` — pinned left gutter labels each lane with its owning branch
  name (display-only; local name preferred when a lane is shared with a
  remote ref), colored to match the lane.
- Merged-in branches are hidden from the graph by default — a conditional
  walk from the tips follows only the first parent at a collapsed merge, and
  the drawn lanes are re-packed gap-free into a `VisibleGraph`. A "Show merged
  branches" sidebar toggle draws them all; the "Expand/Collapse Merge"
  graph-header button toggles a single merge's branch and scrolls to its tip.
  An expanded merged-in branch whose ref is gone is labeled `[deleted]`.

Deferred items (worth revisiting before Phase 4 if a session has slack):

- Viewport culling in `GraphView` (currently paints every commit and runs a
  linear hit-test scan; fine for hundreds of commits, will need windowing
  for 100k+).
- Zoom and time-on-X mode (today X is commit index — easier to read but
  loses real-time density).
- Click branch label in graph → scroll to that tip (only commit-click is
  wired so far).
- Verify against a 100k-commit repo — perf target deferred to Phase 5.

## Phase 4 — Pane layout: resizable + collapsible ✅

Goal: the three top-level panes are drag-resizable today, but none can be
collapsed. On narrower displays the 240-pt sidebar and 420-pt diff pane eat
horizontal space, and there's no way to give the full window to the graph +
log.

Design decisions settled at start of phase:

- **Scope:** top-level only — sidebar (`RepoSidebar`) and diff
  (`DiffPaneView`). Inner `VSplitView` dividers (graph/log,
  changedFiles/diffContent) can already drag to near-zero; per-pane
  chevrons are deferred.
- **Mechanism:** keep `HSplitView`; wrap collapsible children in `if showX
  { ... }`. `NavigationSplitView` rejected — its visibility model
  (`NavigationSplitViewVisibility`, `.inspector`) doesn't compose with the
  existing nested `VSplitView`s in the middle column.
- **State:** two `@AppStorage`-backed booleans, both default `true`. Keys
  centralized in `enum UIDefaultsKey`. No standalone `UIPreferences`
  Observable — two booleans with no side effects don't justify it.
- **Toolbar:** sidebar toggle on `.navigation` (⌥⌘S, `sidebar.left`);
  diff toggle on `.primaryAction` before "Open Repository" (⌥⌘0,
  `sidebar.right`). Both disabled until a repo is loaded. Mutations wrapped
  in `withAnimation(.easeInOut(duration: 0.2))`.

Implementation:

- `UIDefaultsKey` enum + `AppState.isLoaded` helper.
- `ContentView` — two `@AppStorage` properties, two new `ToolbarItem`s
  with keyboard shortcuts; the existing "Open Repository" button moves to
  third in the trailing group.
- `RepoBrowserView` — reads the same `@AppStorage` keys; wraps
  `RepoSidebar(...)` and `DiffPaneView(...)` in `if showX { ... }`.
- **Layout v2:** sidebar (fixed content-width, collapsible) | (graph top /
  log + changed-files middle / diff bottom). The bottom diff uses a custom
  `VerticalCollapsibleSplit` that retains its dragged height in
  `@AppStorage("ui.diffHeight")` across collapse/expand. History row drops
  author + hash columns below 480pt width. The earlier `DiffPaneView`
  wrapper and diff "maximize" button were removed in favor of this layout.

Deferred items (worth revisiting before Phase 5 if a session has slack):

- Inner-pane (graph/log, changedFiles/diffContent) toggle affordances —
  each header would need a chevron and its own state key.
- Persisted exact pane widths across launches — `HSplitView` returns
  reappearing panes at their `idealWidth`, not their pre-collapse drag
  width; persisting widths means hand-rolling a split container.
- A "reset layout" menu item, once we have more layout state to reset.

## Phase 5 — Fork-style left pane ✅

Goal: turn the left pane from a graph-filter checkbox list into a Fork-style
navigator.

Design decisions settled at start of phase:

- **Selection model:** double-click a branch row checks it out (shells to
  `git checkout`); a per-row filter button toggles graph + History inclusion.
  Multi-select stays — several branches can be filtered in at once.
- **Master toggles removed.** Collapsible Local/Remote/Tags sections plus the
  per-branch filter replace "Show local/remote branches". Only "Show merged
  branches" survives as a checkbox at the top.
- **Upstream:** the `origin/<name>` convention, consistent with the existing
  `branch_tracked` logic.
- **History is re-scoped** by the filter — the log walk now starts from the
  filtered branch tips instead of HEAD only.
- **Launch default:** only the current local branch is filtered into the graph
  and History.

Implementation:

- `core/repo.rs` — `RepoSummary` gains `branch_ahead` / `branch_behind`
  (commits diverged from `origin/<name>`, via `rev_walk(...).with_hidden(...)`);
  `checkout_branch` shells to `git checkout`.
- `core/log.rs` — `LogSession::open` takes ref names and walks from those tips
  (reusing the graph's ref-resolution shape); empty list falls back to HEAD.
- `RepoSidebar` rewrite — `CollapsibleSection` for Local/Remote/Tags (Remote &
  Tags collapsed by default; Tags pinned to the pane bottom), `BranchRow` with
  a current-branch indicator, ahead/behind badges, local-only marker, and a
  filter button. Sidebar content fills the full pane width.
- `GraphStore` drops the local/remote master toggles; `LogPager` reloads on
  filter change so History tracks the same branch set.

## Phase 6 — Determine Work Not Merged ✅

Goal: right-click two refs in the sidebar and find which commits in ref_a introduced
the lines that differ between ref_a and ref_b.

Design decisions:
- **Algorithm:** blame-based, content-matching. Diff B vs A (old=B, new=A) → collect
  the text of every insertion line per file → walk A's commit ancestry; for each commit
  that touches a file, check which of its inserted lines match our set; attribute those
  to the commit. Content matching avoids the need to remap line indices as history shifts
  lines around.
- **Two menu items:** "Compare A ↔ B" (existing) and "Determine Work Not Merged from A
  into B" (new) both appear when two refs are selected. Direction is first-selected=source,
  second-selected=target.
- **Pane rename:** "Changed Files" header becomes "Commits with Work Not Found" in this
  mode. File filter is hidden; the commit list replaces the file list.
- **Commit click:** tapping a commit in the list loads its first-file diff into the bottom
  pane via a separate `unmergedDiffHolder`, so the commit list is preserved.
- **Mode exit:** clicking any commit in the History log calls `loadDiff(for:)` which
  resets `source` to `.commit(...)` and exits unmerged-work mode naturally.
- **Binary files:** skipped silently (NUL-byte check on first 8 KiB).
- **gix blame:** gix 0.66 has no `gix-blame` crate; blame is implemented manually
  via `rev_walk` + `similar::TextDiff` with early-exit when all lines are attributed.

Implementation:
- `core/src/blame.rs` (new) — `blame_insertions()` walk + `file_change_in_commit()` helper
- `core/src/diff.rs` — `UnmergedWorkResult` struct + `open_unmerged_work()` function; made
  `read_blob_text` `pub(crate)` for reuse
- `core/src/lib.rs` — `UnmergedWork` opaque FFI type; `open_unmerged_work` bridge fn
- `AppState.swift` — `UnmergedCommit` struct; `.unmergedWork` case on `DiffSource`;
  `unmergedCommits`, `selectedUnmergedCommit`, `unmergedDiffHolder` on `CommitDiffStore`;
  `loadUnmergedWork(refA:refB:)` and `selectUnmergedCommit(_:)` methods
- `GititApp.swift` — `refCompareMenu` gains `onUnmergedWork` param + new button; `RepoSidebar`,
  `BranchRow`, `TagRow` all thread through the callback; `ChangedFilesView` conditionally
  renders commit list and renames header; `UnmergedCommitRow` view added; `DiffContentView`
  shows commit info in header when a commit is selected
- **Perf rewrite:** the per-file blame walked all of A's ancestry and spun on large repos.
  Replaced with a bounded touched-file walk: `git rev-list B..A` + per-commit tree-diff vs
  first parent, early-cancel on the first path in the A↔B change set.
  `core/src/blame.rs` removed. FFI surface and Swift code unchanged.

## Phase 7 — Settings window + ref filtering

Goal: make large monorepos navigable by scoping which refs the sidebar shows,
and give the app its first real Settings UI to host that control.

Design decisions settled at start of phase:

- **Settings window:** a standard macOS `Settings` scene with a category
  `TabView`. The first category is "Filtering"; the structure takes new
  categories as one more `.tabItem`.
- **Filtering:** per ref kind (Local Branches, Remote Branches, Tags) the user
  enters any number of glob patterns (`*`, `?`, anchored to the whole name —
  `trunk` is exact, `trunk*` is a prefix). A ref is shown when its name matches
  at least one pattern; an empty list shows all. Glob, not regex, because the
  patterns must read naturally to users who don't think in regex.
- **Scope:** the filter affects the sidebar lists only — the graph and History
  are untouched. No Rust/FFI changes.
- **Per repository:** patterns are keyed by repo path and persisted as one JSON
  blob in `UserDefaults`.
- **Always visible:** the current branch and a detached-HEAD tag survive the
  filter even when they don't match a pattern.

Implementation:

- `AppState.swift` — `RepoFilterPatterns` (Codable per-repo pattern lists) and
  `FilterSettings` (`@Observable`, persists/loads the JSON blob).
- `GititApp.swift` — a `Settings` scene; `SettingsView` (the `TabView`),
  `FilteringSettingsView`, `PatternSection`/`PatternRow` editor views; a
  `RefFilter` value type (globs translated to anchored regexes, compiled once).
- `RepoSidebar` — `rebuildTrees()` filters branches/remotes/tags before
  `buildTree`, driven by `.onChange` of HEAD and of this repo's patterns;
  section headers show `shown / total` with a funnel glyph when filtered.

Verify: open a 26k-tag repo, set tag patterns like `release/26.*`; the Tags
list collapses to matches and stays smooth to scroll; patterns persist per repo
across relaunch.

## Phase 8 — Working tree ops + cherry-pick

Goal: the daily workflow plus the must-have.

> Branch checkout was delivered early as part of Phase 5 (double-click a branch
> in the sidebar). This phase covers the rest.

- Stage/unstage hunks, commit, fetch/pull/push (push/pull can shell to `git`
  initially if gix's push isn't ready in this version)
- Cherry-pick UX: multi-select in log or graph; drag commits onto a branch
  label in the graph to cherry-pick onto it
- Conflict surfacing: list conflicted files inline, jump-to-conflict, mark
  resolved, continue/abort
- **Verify:** cherry-pick a 5-commit range across branches with one conflict;
  conflict UI surfaces; resolution completes the operation

## Phase 9 — Performance + polish

- Persistent commit graph cache (Rust side) — open-time amortization
- Profile with Instruments: log scroll, diff first-frame, ref switch
- Targets:
  - Log scroll: 120 fps on a 100k-commit repo
  - Ref switch: < 200 ms
  - First-frame diff: < 250 ms
  - Cold open of a 100k-commit repo: < 1 s to first ref + first commit
    visible
