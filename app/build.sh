#!/bin/zsh
# Builds mmco.app with swiftc (Command Line Tools are enough, Xcode is not required).
#   app/build.sh              -> build/mmco.app
#   app/build.sh --install    -> also copies it to ~/Applications and registers the mmco:// scheme
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/mmco.app"
ARCH="$(uname -m)"

# From the macOS 27 SDK on, SwiftUI's @State is a compiler macro whose plugin ships only with
# Xcode. With Command Line Tools alone, pick the newest SDK that still declares it as a plain
# property wrapper. A full Xcode install has the plugin, so its default SDK is fine.
pick_sdk() {
  local default
  default="$(xcrun --show-sdk-path)"
  if xcodebuild -version >/dev/null 2>&1; then echo "$default"; return; fi
  local dir sdk iface
  dir="$(dirname "$default")"
  for sdk in "$default" $(ls -d "$dir"/MacOSX*.*.sdk 2>/dev/null | sort -rV); do
    iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/$ARCH-apple-macos.swiftinterface"
    [ -f "$iface" ] || iface="${iface/$ARCH-apple/arm64e-apple}"
    if [ -f "$iface" ] && ! grep -q "public macro State" "$iface"; then echo "$sdk"; return; fi
  done
  echo "$default"
}
SDK="$(pick_sdk)"
echo "sdk: $SDK"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -O \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework Cocoa -framework SwiftUI \
  "$ROOT"/app/Sources/*.swift \
  -o "$OUT/Contents/MacOS/mmco"

cp "$ROOT/app/Info.plist" "$OUT/Contents/Info.plist"
cp "$ROOT/bin/mmco" "$OUT/Contents/Resources/mmco"
chmod +x "$OUT/Contents/Resources/mmco"
echo "APPL????" > "$OUT/Contents/PkgInfo"

# Ad-hoc signature: enough for a locally built app to launch without Gatekeeper complaints.
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo "built $OUT"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/mmco.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "installed $DEST (mmco:// registered)"
fi
