#!/bin/bash
# Builds "Datafy Discovery.app" for this Mac and registers its datafy-discovery:// link.
#
#   ./build-app.sh          production build (only the production origin is trusted)
#   ./build-app.sh --dev    development build: also trusts http://localhost:3000 (the Vite dev server)
#
# The result is UNSIGNED (ad-hoc signed only). That is fine on the Mac that built it: macOS only blocks apps that came
# from a download. To give it to anyone else it must be signed and notarized first (see ../../README.md).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/build"
app="$out/Datafy Discovery.app"
tags=""
[[ "${1:-}" == "--dev" ]] && tags="-tags dev"

rm -rf "$app"
mkdir -p "$out"

echo "==> building the program ${tags:+(dev build)}"
(cd "$root" && go build $tags -trimpath -ldflags "-s -w" -o "$out/datafy-discovery" ./cmd/datafy-discovery)

echo "==> building the launcher app"
osacompile -o "$app" "$here/launcher.applescript"
cp "$out/datafy-discovery" "$app/Contents/Resources/datafy-discovery"
chmod 755 "$app/Contents/Resources/datafy-discovery"

echo "==> registering the datafy-discovery:// link"
plist="$app/Contents/Info.plist"
pb=/usr/libexec/PlistBuddy
set_or_add() { "$pb" -c "Set :$1 $3" "$plist" 2>/dev/null || "$pb" -c "Add :$1 $2 $3" "$plist"; }
set_or_add CFBundleIdentifier string io.datafy.discovery
set_or_add CFBundleName string "Datafy Discovery"
set_or_add LSUIElement bool true   # no Dock icon: it runs quietly in the background
"$pb" -c "Delete :CFBundleURLTypes" "$plist" 2>/dev/null || true
"$pb" -c "Add :CFBundleURLTypes array" "$plist"
"$pb" -c "Add :CFBundleURLTypes:0 dict" "$plist"
"$pb" -c "Add :CFBundleURLTypes:0:CFBundleURLName string io.datafy.discovery" "$plist"
"$pb" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist"
"$pb" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string datafy-discovery" "$plist"

echo "==> ad-hoc signing (required on Apple Silicon once the bundle is edited)"
codesign --force --deep --sign - "$app"

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -f "$app"

echo
echo "Built: $app"
echo "Try:   open 'datafy-discovery://open?origin=http%3A%2F%2Flocalhost%3A3000&nonce=0123456789abcdef0123'   (dev build)"
echo "Log:   ~/Library/Logs/DatafyDiscovery.log"
echo "Remove: $here/uninstall.sh"
