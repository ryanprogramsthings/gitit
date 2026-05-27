---
name: swiftui-sidebar-tree
description: >-
  Recipe for building or changing a list in gitit's SwiftUI sidebar
  (`RepoSidebar` in `Sources/GititApp/GititApp.swift`) — branches, tags, and any
  future list such as stashes, worktrees, submodules, or remotes. Use this skill
  whenever you add a new sidebar section, add slash-folder grouping to an
  existing one, scope a section with a filter (e.g. ref name filtering), or
  investigate scrolling / expansion lag in the sidebar. gitit
  has a specific virtualized-tree pattern; follow it rather than re-deriving it,
  because the obvious SwiftUI nesting silently breaks virtualization and the app
  crawls or hangs on large repos (the gmap-ios test repo has 26k+ tags and 5k+
  remote branches).
---

# gitit sidebar tree pattern

Every grouped list in `RepoSidebar` (Local branches, Remote branches, Tags)
uses the same five-part recipe. It was re-derived twice — once to fix branch
scroll lag, once to add tag folders — so it is written down here. Adding the
next list (stashes, worktrees, …) should be a near-mechanical application of it.

All the code referenced below lives in `Sources/GititApp/GititApp.swift`.

## Why it has to be this way

Two SwiftUI facts drive the whole design:

1. **`LazyVStack` only virtualizes its *direct* `ForEach` children.** A `ForEach`
   nested inside an intermediate `VStack`/`Group` is realized eagerly. So the
   whole section — headers, folders, leaves, every nesting level — must be
   *flattened into one array* and fed to a single `ForEach`.
2. **A recursive folder view that holds its own `@State expanded` materializes
   the entire subtree.** If `expanded` defaults to `true`, expanding a section
   builds every descendant at once. Expansion state must live in the model, not
   in per-row view state, and folders must default *collapsed*.

**What is *not* required:** a `LazyVStack` virtualizes fine inside a plain
`ScrollView` with no height cap — the Local/Remote branch lists do exactly that.
The `.frame(maxHeight: 220)` on the Tags pane is a layout choice (it stops that
pane from growing unbounded and shoving other sections off-screen), *not*
something windowing depends on. Don't add a height cap believing it's what makes
virtualization work, and don't conclude a list isn't virtualized just because it
lacks one — the lazy container plus a direct `ForEach` is the whole mechanism.

A third, non-SwiftUI cost: splitting thousands of slash-delimited names into a
tree on every `body` pass is too slow — the tree must be memoized.

Get any of these wrong and the build still succeeds; the failure only shows up
as lag on a large repo. That is why this pattern is worth following verbatim.

## The five parts

**1. `TreeNode<Leaf>` + `buildTree`** — generic. `buildTree(_ items: [(String, Leaf)])`
splits each key on `/` into a nested folder tree (`leaf == nil` ⇒ folder).
Leaves carry a payload: branches pass `(branch.name, BranchInfo)`, tags pass
`(tag, tag)`. A new list passes `(key, YourLeafType)`.

**2. A flattened row enum** — one `case` per kind of row the section renders
(`header`, `folder`, leaf, `empty`, …), each `Identifiable` with a prefixed,
stable `id`. See `SidebarRow` (branches) and `TagRowKind` (tags). The folder and
leaf cases carry a depth `Int` for indentation.

**3. A computed flatten** — a `var rows: [RowEnum]` that walks the memoized tree
via a recursive `append…` helper, emitting a folder row then, *only if its path
is in the expanded set*, recursing into its children. See `sidebarRows` /
`appendTree` and `tagRows` / `appendTagTree`.

**4. Expand state = `Set<String>` of folder paths on the model.** One `@State`
set per section (`expandedFolders` for branches, `expandedTagFolders` for tags —
kept separate so a `release/` branch folder and a `release/` tag folder cannot
collide). Toggling is `if !set.insert(path).inserted { set.remove(path) }`.
Folders start collapsed.

**5. Memoize the tree in `@State`.** Build the `TreeNode` arrays in a
`rebuildTrees()` method, never inside `body`. See `localTree` / `remoteTree` /
`tagTree`. The method is driven by `.onChange` — `of: overview.headOid,
initial: true` rebuilds on open and after every checkout. The key thing is that
the `.onChange` set must cover *every* input the trees depend on (see
"Filtering an existing list" below): miss one and the list silently shows stale
rows until the next checkout.

The section then renders as exactly:

```swift
ScrollView {
    LazyVStack(spacing: 0) {
        ForEach(rows) { row in rowView(row) }
    }
}
```

where `rowView` is a `@ViewBuilder` that `switch`es over the row enum.

## Adding a new sidebar section (worked checklist)

For a hypothetical "Stashes" list:

1. Add `@State private var stashTree: [TreeNode<StashInfo>] = []` and
   `@State private var expandedStashFolders: Set<String> = []` to `RepoSidebar`.
2. In the existing `.onChange(of: overview.headOid, initial: true)` block, add
   `stashTree = buildTree(overview.stashes.map { ($0.name, $0) })`.
3. Define `enum StashRowKind: Identifiable` with `folder`/`stash` cases and
   prefixed `id`s — model it on `TagRowKind`.
4. Add `stashRows` + `appendStashTree` — copy `tagRows` / `appendTagTree`,
   consulting `expandedStashFolders`.
5. Add `stashRowView` (`@ViewBuilder` switch) + a `stashFolderRow` modeled on
   `tagFolderRow`, and a leaf row view (model on `TagRow` / `BranchRow`).
6. Render it: either its own `CollapsibleSection { ScrollView { LazyVStack {
   ForEach(stashRows) } } }` (separate pane, like Tags), or fold its rows into
   the main `sidebarRows` list as a third section (like Local/Remote). Match
   whichever the design calls for.

The two flatten helpers stay per-section rather than generic: the recursion is
short and the row enums differ, so unifying them costs more than it saves.
`TreeNode` and `buildTree` *are* shared — that is the one worthwhile generic.

## Filtering an existing list

Scoping a section to a subset of refs (e.g. the Settings "Filtering" category —
glob patterns per ref kind) is a *pre-`buildTree` filter*, not a new row type.
The trees stay memoized; you only change what feeds them and when they rebuild.

The trap: the memoized trees are rebuilt by `.onChange`, and the obvious trigger
`overview.headOid` does not change when a filter setting changes. If you filter
the input but leave the trigger alone, the sidebar keeps showing the old rows
until the next checkout. So:

1. Filter the ref arrays inside `rebuildTrees()`, before `buildTree` — never
   inside the `rows` flatten (that runs every `body` pass; the cost the
   memoization exists to avoid). Always keep refs the user cannot afford to
   lose — the current branch (`overview.headName`) and a detached-HEAD tag
   (`overview.headTag`) — regardless of the filter.
2. Add a second trigger so a filter change rebuilds the trees:

   ```swift
   .onChange(of: overview.headOid, initial: true) { rebuildTrees() }
   .onChange(of: currentPatterns) { rebuildTrees() }
   ```

   `.onChange` needs an `Equatable` value, so the filter input (e.g.
   `RepoFilterPatterns`) must conform to `Equatable`. Reading the filter through
   a computed property (`currentPatterns`) registers the `@Observable`
   dependency, so an edit in the Settings window reflows the sidebar live.
3. Compile each pattern once into a reusable matcher, then test every ref
   against it — never recompile per ref, or filtering 26k tags crawls. See
   `RefFilter` (glob patterns translated to anchored regexes).

The live filter pattern is in `RepoSidebar` (`rebuildTrees`, `currentPatterns`)
and `FilterSettings` in `AppState.swift`.

## Verifying

`swift build` will not catch a virtualization regression. Verify by running
`swift run GititApp` against a large repo (one with thousands of branches/tags): the
section must expand instantly and scroll smoothly, and folders must come up
collapsed. Ignore the inline SourceKit `No such module 'GititFFI'` diagnostic —
it is a known false positive; trust `swift build`.
