#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build-direct"
APP_PATH="$BUILD_DIR/CodexQuotaFloat.app"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macosx13.0"
SWIFTC_OPTIONS=(-swift-version 5 -target "$TARGET" -O)

mkdir -p "$BUILD_DIR"

# Some Command Line Tools 16.4 installations contain two identical
# SwiftBridging module maps. Hide the duplicate only for this build.
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
   && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    OVERLAY="$BUILD_DIR/hide-duplicate-modulemap.yaml"
    sed "s|__EMPTY_MODULEMAP__|$ROOT/toolchain-workaround/empty.modulemap|g" \
        "$ROOT/toolchain-workaround/hide-duplicate-modulemap.yaml.in" > "$OVERLAY"
    SWIFTC_OPTIONS=(-vfsoverlay "$OVERLAY" "${SWIFTC_OPTIONS[@]}")
fi

CORE_SOURCES=("$ROOT"/Sources/CodexQuotaCore/*.swift)
APP_SOURCES=("$ROOT"/Sources/CodexQuotaFloat/*.swift)

swiftc "${SWIFTC_OPTIONS[@]}" \
    -parse-as-library \
    -emit-library -static \
    -emit-module -module-name CodexQuotaCore \
    -emit-module-path "$BUILD_DIR/CodexQuotaCore.swiftmodule" \
    -o "$BUILD_DIR/libCodexQuotaCore.a" \
    "${CORE_SOURCES[@]}"

swiftc "${SWIFTC_OPTIONS[@]}" \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lCodexQuotaCore -lsqlite3 \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    -o "$BUILD_DIR/CodexQuotaFloat" \
    "${APP_SOURCES[@]}"

swiftc "${SWIFTC_OPTIONS[@]}" \
    -parse-as-library \
    -I "$BUILD_DIR" -L "$BUILD_DIR" -lCodexQuotaCore -lsqlite3 \
    -o "$BUILD_DIR/QuotaCoreSmokeTest" \
    "$ROOT/Tests/QuotaCoreSmokeTest.swift"

"$BUILD_DIR/QuotaCoreSmokeTest"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_DIR/CodexQuotaFloat" "$APP_PATH/Contents/MacOS/CodexQuotaFloat"
cp "$ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign - "$APP_PATH"

echo "Built: $APP_PATH"
