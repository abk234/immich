#!/usr/bin/env bash
# Build ImmichLanProxy.app (dedicated binary for macOS Firewall allowlisting).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/immich-lan-proxy"
APP="$ROOT/scripts/ImmichLanProxy.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

mkdir -p "$MACOS" "$RES"
cd "$SRC"
go build -trimpath -ldflags="-s -w" -o "$MACOS/ImmichLanProxy" .

cat >"$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>ImmichLanProxy</string>
  <key>CFBundleDisplayName</key>
  <string>Immich LAN Proxy</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.immich.lanproxy</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>ImmichLanProxy</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so Firewall / Gatekeeper treat it as a real app binary.
codesign --force --sign - --identifier com.local.immich.lanproxy "$MACOS/ImmichLanProxy" 2>/dev/null || true
codesign --force --sign - --identifier com.local.immich.lanproxy "$APP" 2>/dev/null || true

echo "built: $APP"
"$MACOS/ImmichLanProxy" -h 2>&1 | head -5 || true
