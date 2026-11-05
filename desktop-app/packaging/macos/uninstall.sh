#!/bin/bash
# Stops the app, unregisters the link, and deletes the build and the cached scanner.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/build/Datafy Discovery.app"
pkill -f "Datafy Discovery.app/Contents/Resources/datafy-discovery" 2>/dev/null || true
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$app" ]] && "$lsregister" -u "$app" || true
rm -rf "$here/build" "$HOME/Library/Caches/DatafyDiscovery"
echo "Removed. (The log, if any, is ~/Library/Logs/DatafyDiscovery.log)"
