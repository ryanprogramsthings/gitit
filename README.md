# gitit

A fast Mac-native git client for large monorepos.

- Native SwiftUI on macOS 14+
- Rust `gitoxide` core via `swift-bridge` FFI
- Horizontal branch graph
- Diffs between any two refs for a specific file, with Swift + Kotlin syntax highlighting
- First-class cherry-pick

Status: pre-alpha. Phase 1 scaffolding.

## Contributing to this Repository

Please feel free to open Issues or Pull Requests. I'm just a single engineer, but I may add some others as reviewers if people really like this idea and this grows. Admittedly, I'm focusing on features that affect my day to day working with a really large, legacy codebase. If this is something you deal with, please give it a shot and contribute!

## Build
```
# If you want to run with logs from command line (keep in mind this overtakes the settings menu, so you can't test that currently if you do this)
./build/build-rust.sh
swift run GititApp

# If you want to build it as a standalone app
open .build/GititApp.app
```

Requires Rust toolchain (1.75+) and Xcode 15+ command-line tools.

## AI Structure & Process

- Currently set up for Claude, but plan to move to support open standards.
- Currently use Anthropic's skill-creator skill globally & have a global CLAUDE.md on my machine that reviews my session after making a feature and self reflects on any skills that would have sped up the process or saved me tokens. Skills in this project are a result of this process.
- If a PLAN.md exists in the project, there are still planned phases not completed. If you'd like to plans for what's next, you can always review it there. (Or feel free to open a PR to this file to add any phases you think would be nice)