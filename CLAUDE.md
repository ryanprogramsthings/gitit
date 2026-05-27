# gitit

A fast Mac-native git client for large monorepos.

## Stack
- **UI:** Swift 5.10+ / SwiftUI on macOS 14+ (Sonoma).
  AppKit interop (`NSTextView` via `NSViewRepresentable`) for diff/log rendering at scale — SwiftUI `Text` falls over on 10k+ line content.
- **Git core:** Rust `gix` (gitoxide) crate. No shelling out to `git` except as a last-resort fallback (push/pull initially).
- **FFI:** `swift-bridge` generates the Swift↔Rust boundary. Avoid hand-rolled C FFI.
- **Syntax highlighting:** tree-sitter (`tree-sitter-swift`, `tree-sitter-kotlin` first).

## Build
```
./build/build-rust.sh         # compiles core/ → static lib + Swift bindings
swift build                   # builds SwiftPM workspace
swift run GititApp            # launches the app (terminal-run: no menu bar)
./build/build-app.sh          # builds .build/GititApp.app — a real bundle
```

`swift run` is fine for a quick check, but a terminal-launched executable never
owns the macOS menu bar, so ⌘-shortcuts and the Settings window (⌘,) do nothing.
Use `build-app.sh`, then `open .build/GititApp.app`, to run it as a real app.

## FFI rule: data, not handles
Rust returns plain value types (oids, commit summaries, parent lists). Swift never holds a `gix::Repository` reference. This keeps threading and lifetimes simple and the FFI boundary easy to reason about.

## Performance mandates
1. **Stream long results.** Commit walks, ref enumerations, and tree diffs return `AsyncStream` on the Swift side. First rows visible in <100ms; the rest streams in.
2. **Virtualize everything.** Log, graph, file tree, and diff use windowed rendering. Never materialize a million-row list.
3. **Background indexing.** On repo open, kick off a Rust task that builds an in-memory commit graph and persists it for next open.

## Repo layout
```
Sources/
  GititApp/        @main SwiftUI app shell
  GititUI/         Reusable views (LogView, GraphView, DiffView)
  GititCore/       Swift domain models + async wrappers around FFI
  GititFFI/        swift-bridge generated bindings (do not hand-edit)
core/              Rust crate (gix-backed git core)
build/             Build scripts (Rust → static lib + Swift bindings)
```

## Phase status
See `PLAN.md` at the repo root for the full phased plan and current status.
Update the status table there whenever a phase flips.

## Style
- Swift: no force-unwraps in non-test code. Prefer `async` over completion handlers. `AsyncStream` for streams.
- Rust: `clippy::pedantic` warnings on. Errors via `thiserror`; never panic across the FFI boundary.
- Comments only when the *why* isn't obvious from the code.
