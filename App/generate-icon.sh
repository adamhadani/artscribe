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

# **Run against the macOS SDK, whatever build invoked this.**
#
# This is a macOS command-line script that draws with CoreGraphics, but it is now
# a pre-build step of the *iOS* target as well — and Xcode exports SDKROOT,
# PLATFORM_NAME and friends into script phases. Inheriting those makes `swift`
# try to compile a macOS script for iOS and fail with
#
#     error: unable to load standard library for target 'arm64-apple-macosx26.0'
#
# which names macOS and so reads like the opposite problem.
#
# It passed locally and failed in CI for a reason worth remembering: the outputs
# are gitignored, so a working copy that already has them short-circuits above
# and never runs this line. Only a clean checkout does. Deleting both outputs
# before testing is what reproduces it.
exec env -u SDKROOT -u PLATFORM_NAME -u SUPPORTED_PLATFORMS -u TOOLCHAINS \
    xcrun --sdk macosx swift "$source_file" "$here"
