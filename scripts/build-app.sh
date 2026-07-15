#!/usr/bin/env bash
# Build AgentTerminal as a macOS .app bundle.
#
# Usage:
#   ./scripts/build-agent-terminal.sh
#
# What it does:
#   1. swift build -c release
#   2. Assemble dist/AgentTerminal.app/Contents/{MacOS,Resources,Info.plist}
#   3. Generate AppIcon.icns from branding/AppIcon.png
#   4. Promote SPM resource bundle to canonical macOS bundle layout
#   5. Adhoc codesign
#
# Output: prints the absolute path to the built .app bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Config ──────────────────────────────────────────────────────────────────
APP_NAME="AgentTerminal"
BUNDLE_ID="com.agentterminal.app"

# Read version from AppInfo.swift (single source of truth)
VERSION="$(grep -E 'static let displayVersion' Sources/AgentTerminalKit/App/AppInfo.swift \
    | sed -E 's/.*= "([^"]+)".*/\1/')"
if [ -z "$VERSION" ]; then
    echo "build-agent-terminal.sh: failed to extract displayVersion from AppInfo.swift" >&2
    exit 1
fi

APP="dist/${APP_NAME}.app"

# ── Build ───────────────────────────────────────────────────────────────────
echo "==> Building release config (swift build -c release)"
swift build -c release

echo "==> Verifying build artifacts"
for f in .build/release/AgentTerminal .build/release/AgentTerminalHook; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -d ".build/release/AgentTerminal_AgentTerminalKit.bundle" ] || {
    echo "missing SPM resource bundle: .build/release/AgentTerminal_AgentTerminalKit.bundle" >&2
    exit 1
}

# ── Assemble .app ───────────────────────────────────────────────────────────
echo "==> Assembling ${APP} (v${VERSION})"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp .build/release/AgentTerminal "${APP}/Contents/MacOS/${APP_NAME}"
cp .build/release/AgentTerminalHook "${APP}/Contents/MacOS/AgentTerminalHook"
# Strip debug symbols from release binaries (~1MB savings)
strip -S "${APP}/Contents/MacOS/${APP_NAME}"
strip -S "${APP}/Contents/MacOS/AgentTerminalHook"
# Convenience symlink: `agentforward list` == `AgentTerminal agent-forward list`
ln -sf "${APP_NAME}" "${APP}/Contents/MacOS/agentforward"

# Bundle.module looks at Bundle.main.resourceURL (= Contents/Resources/),
# so resource bundle must live there for runtime discovery
cp -R .build/release/AgentTerminal_AgentTerminalKit.bundle "${APP}/Contents/Resources/"

# ── App Icon ────────────────────────────────────────────────────────────────
ICON_SOURCE=""
for cand in branding/icons/icon-512@2x.png branding/icons/icon-1024.png branding/AppIcon.png; do
    if [ -f "$cand" ]; then
        ICON_SOURCE="$cand"
        break
    fi
done

if [ -n "$ICON_SOURCE" ]; then
    echo "==> Building AppIcon.icns from ${ICON_SOURCE}"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
                "32:icon_32x32.png" "64:icon_32x32@2x.png" \
                "128:icon_128x128.png" "256:icon_128x128@2x.png" \
                "256:icon_256x256.png" "512:icon_256x256@2x.png" \
                "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_SOURCE" --out "${ICONSET}/${name}" >/dev/null
    done
    iconutil -c icns -o "${APP}/Contents/Resources/AppIcon.icns" "$ICONSET"
    rm -rf "$(dirname "$ICONSET")"
    APPLE_ICON_PLIST_KEYS=$(cat <<'KEYS'
        <key>CFBundleIconFile</key>
        <string>AppIcon</string>
        <key>CFBundleIconName</key>
        <string>AppIcon</string>
KEYS
    )
else
    echo "==> No icon source found — shipping without app icon" >&2
    APPLE_ICON_PLIST_KEYS=""
fi

# ── Promote SPM resource bundle to canonical macOS layout ───────────────────
RES_BUNDLE="${APP}/Contents/Resources/AgentTerminal_AgentTerminalKit.bundle"
if [ -d "$RES_BUNDLE" ]; then
    mkdir -p "${RES_BUNDLE}/Contents/Resources"
    shopt -s nullglob
    for f in "$RES_BUNDLE"/*.ttf "$RES_BUNDLE"/*.png "$RES_BUNDLE"/*.json; do
        [ -f "$f" ] && mv "$f" "${RES_BUNDLE}/Contents/Resources/"
    done
    shopt -u nullglob

    cat > "${RES_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.resources</string>
    <key>CFBundleName</key>
    <string>AgentTerminal_AgentTerminalKit</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
</dict>
</plist>
PLIST
fi

# ── Info.plist ──────────────────────────────────────────────────────────────
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleSpokenName</key>
    <string>Agent Terminal</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 AgentTerminal Contributors</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
${APPLE_ICON_PLIST_KEYS}
</dict>
</plist>
PLIST

# PkgInfo — legacy but expected by some macOS internals
echo "APPL????" > "${APP}/Contents/PkgInfo"

# ── Adhoc codesign ──────────────────────────────────────────────────────────
echo "==> Adhoc codesigning ${APP}"
codesign --force --deep --sign - "$APP"

# ── Output ──────────────────────────────────────────────────────────────────
ABSOLUTE_PATH="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
echo ""
echo "${ABSOLUTE_PATH}"
