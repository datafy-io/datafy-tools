#!/bin/bash
# DEVELOPMENT SCRIPT, not yet tested on Linux. Installs the binary and registers datafy-discovery:// for this user.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tags=""; [[ "${1:-}" == "--dev" ]] && tags="-tags dev"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
(cd "$root" && go build $tags -trimpath -ldflags "-s -w" -o "$HOME/.local/bin/datafy-discovery" ./cmd/datafy-discovery)
cp "$here/datafy-discovery.desktop" "$HOME/.local/share/applications/"
xdg-mime default datafy-discovery.desktop x-scheme-handler/datafy-discovery
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "Installed to ~/.local/bin/datafy-discovery and registered datafy-discovery://"
