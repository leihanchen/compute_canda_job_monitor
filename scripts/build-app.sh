#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Error: Info.plist not found at $INFO_PLIST" >&2
    exit 1
fi

ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build --package-path "$ROOT_DIR" -c release "${ARCH_FLAGS[@]}"; then
    echo "Universal build (arm64 + x86_64) failed; falling back to arm64." >&2
    ARCH_FLAGS=(--arch arm64)
    swift build --package-path "$ROOT_DIR" -c release "${ARCH_FLAGS[@]}"
fi

BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BINARY_PATH="$BIN_DIR/SlurmMonitorApp"
if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Error: expected release binary not found at $BINARY_PATH" >&2
    exit 1
fi

APP_DIR="$ROOT_DIR/build/Slurm Monitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/SlurmMonitorApp"
chmod +x "$MACOS_DIR/SlurmMonitorApp"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"

# Optional version stamping (used by the release workflow), applied before signing.
# APP_VERSION accepts "1.2.3" or "v1.2.3"; BUILD_NUMBER sets CFBundleVersion.
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION#v}" "$CONTENTS_DIR/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$CONTENTS_DIR/Info.plist"
fi

plutil -lint "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=4 "$APP_DIR"

echo "Built app bundle at: $APP_DIR"
