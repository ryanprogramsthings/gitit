#!/usr/bin/env bash
# Build the Rust core crate and stage generated FFI artifacts into Sources/.
# Idempotent — safe to re-run.

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$PACKAGE_ROOT/core"

PROFILE="${PROFILE:-debug}"
case "$PROFILE" in
    debug)   CARGO_PROFILE_ARG="" ;;
    release) CARGO_PROFILE_ARG="--release" ;;
    *) echo "unknown PROFILE: $PROFILE (expected debug|release)" >&2; exit 2 ;;
esac

# Pin the C compiler target to match the Swift package's deployment target.
# Tree-sitter grammar .c files are built by the cc crate; without this they
# inherit the system SDK and the linker warns when staged into our macOS 14 app.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "==> cargo build ($PROFILE, MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET)"
(cd "$CORE_DIR" && cargo build $CARGO_PROFILE_ARG)

OUT_DIR_MARKER="$CORE_DIR/target/swift-bridge-out-dir.txt"
if [[ ! -f "$OUT_DIR_MARKER" ]]; then
    echo "ERROR: swift-bridge OUT_DIR marker missing at $OUT_DIR_MARKER" >&2
    exit 1
fi
SB_OUT_DIR="$(cat "$OUT_DIR_MARKER")"
if [[ ! -d "$SB_OUT_DIR" ]]; then
    echo "ERROR: swift-bridge OUT_DIR does not exist: $SB_OUT_DIR" >&2
    exit 1
fi

INCLUDE_DIR="$PACKAGE_ROOT/Sources/CGititCore/include"
LIB_DIR="$PACKAGE_ROOT/Sources/CGititCore/lib"
SWIFT_DIR="$PACKAGE_ROOT/Sources/GititFFI/Generated"

mkdir -p "$INCLUDE_DIR" "$LIB_DIR" "$SWIFT_DIR"

echo "==> staging headers   -> $INCLUDE_DIR"
cp "$SB_OUT_DIR/SwiftBridgeCore.h" "$INCLUDE_DIR/SwiftBridgeCore.h"
cp "$SB_OUT_DIR/GititCore/GititCore.h" "$INCLUDE_DIR/GititCore.h"

echo "==> staging swift glue -> $SWIFT_DIR"
# Prepend `import CGititCore` so the generated Swift can see the C FFI symbols.
prepend_import() {
    local src="$1" dst="$2"
    {
        echo "import CGititCore"
        echo
        cat "$src"
    } > "$dst"
}
prepend_import "$SB_OUT_DIR/SwiftBridgeCore.swift" "$SWIFT_DIR/SwiftBridgeCore.swift"
prepend_import "$SB_OUT_DIR/GititCore/GititCore.swift" "$SWIFT_DIR/GititCore.swift"

echo "==> staging static lib -> $LIB_DIR"
cp "$CORE_DIR/target/$PROFILE/libgitit_core.a" "$LIB_DIR/libgitit_core.a"

echo "done."
