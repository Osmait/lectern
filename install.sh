#!/bin/sh
# Builds Lectern and installs it for the current user: the binary under
# ~/.local/bin, and the desktop entry and the icon under ~/.local/share.
# `--default` also makes it the default PDF reader.
set -eu
cd "$(dirname "$0")"

bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
apps="$data/applications"
icons="$data/icons/hicolor/scalable/apps"

zig build -Doptimize=ReleaseSafe
mkdir -p "$bin" "$apps" "$icons"
install -m 755 zig-out/bin/lectern "$bin/lectern"
sed "s|^Exec=lectern|Exec=$bin/lectern|" data/lectern.desktop > "$apps/lectern.desktop"
install -m 644 data/lectern.svg "$icons/lectern.svg"
gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
update-desktop-database "$apps" 2>/dev/null || true

if [ "${1:-}" = "--default" ]; then
    xdg-mime default lectern.desktop application/pdf
fi
echo "Installed $bin/lectern"
