#!/bin/sh
# Regenerates App/Artscribe.icns from App/GenerateIcon.swift when it is missing
# or out of date. The .icns itself is gitignored — the Swift file is the source.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
icns="$here/Artscribe.icns"
source_file="$here/GenerateIcon.swift"

# Both outputs must be present and fresh. Checking only the .icns was enough
# while it was the only one; with the iOS PNG added, a stale-but-newer .icns
# would have skipped the regeneration that creates the PNG, and the iPad target
# would build with no icon and no error.
ios_icon="$here/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

if [ -f "$icns" ] && [ "$icns" -nt "$source_file" ] \
   && [ -f "$ios_icon" ] && [ "$ios_icon" -nt "$source_file" ]; then
    exit 0
fi

exec swift "$source_file" "$here"
