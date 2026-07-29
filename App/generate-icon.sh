#!/bin/sh
# Regenerates App/Artscribe.icns from App/GenerateIcon.swift when it is missing
# or out of date. The .icns itself is gitignored — the Swift file is the source.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
icns="$here/Artscribe.icns"
source_file="$here/GenerateIcon.swift"

if [ -f "$icns" ] && [ "$icns" -nt "$source_file" ]; then
    exit 0
fi

exec swift "$source_file" "$here"
