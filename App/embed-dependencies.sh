#!/bin/sh
# Makes Artscripture.app stand on its own.
#
# The app links two Homebrew libraries — librubberband and, through it,
# libsamplerate — by absolute path:
#
#   /opt/homebrew/opt/rubberband/lib/librubberband.3.dylib
#   /opt/homebrew/opt/libsamplerate/lib/libsamplerate.0.dylib
#
# A bundle that only launches on a Mac with Homebrew installed in that exact
# prefix is not a distributable app, so this copies both into
# Contents/Frameworks, rewrites every load command to @rpath, and re-signs. The
# executable already carries an @executable_path/../Frameworks runpath (set in
# project.yml).
#
# Nothing else is vendored: everything remaining in `otool -L` is either a
# system framework or /usr/lib, and the check at the bottom fails the build if
# that ever stops being true. Rubber Band is GPL-2.0-or-later and libsamplerate
# is BSD-2-Clause, both compatible with Artscripture's GPL-3.0-or-later, and their
# licence texts are copied into Resources alongside ours.
#
# Run by the Xcode post-build phase, so it works from `make app` and from a
# build started inside Xcode alike. Uses only $BUILT_PRODUCTS_DIR and friends.
set -eu

: "${BUILT_PRODUCTS_DIR:?must be run from an Xcode build phase}"
: "${CONTENTS_FOLDER_PATH:?must be run from an Xcode build phase}"
: "${EXECUTABLE_PATH:?must be run from an Xcode build phase}"

app_contents="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
executable="$BUILT_PRODUCTS_DIR/$EXECUTABLE_PATH"
frameworks="$app_contents/Frameworks"
resources="$app_contents/Resources"
repo_root=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$frameworks" "$resources"

brew_prefix=$(brew --prefix 2>/dev/null || echo /opt/homebrew)

# name:formula pairs. Kept explicit rather than walked from `otool -L`, so a new
# third-party dependency has to be added here deliberately — the verification
# step at the bottom is what catches one that was not.
vendored="librubberband.3.dylib:rubberband libsamplerate.0.dylib:libsamplerate"

for entry in $vendored; do
    lib=${entry%%:*}
    formula=${entry##*:}
    src="$brew_prefix/opt/$formula/lib/$lib"
    if [ ! -f "$src" ]; then
        echo "error: $src not found. Run 'make bootstrap' (brew install $formula)." >&2
        exit 1
    fi
    cp -f "$src" "$frameworks/$lib"
    chmod u+w "$frameworks/$lib"
    # Its own identity, so anything linking it records @rpath rather than the
    # Homebrew path.
    install_name_tool -id "@rpath/$lib" "$frameworks/$lib"
    cp -f "$brew_prefix/opt/$formula/COPYING" "$resources/LICENSE-$formula.txt" 2>/dev/null || true
done

# Repoint every load command — in the executable and in the vendored libraries,
# since librubberband links libsamplerate itself.
for target in "$executable" "$frameworks"/*.dylib; do
    otool -L "$target" | awk 'NR > 1 { print $1 }' | while read -r dep; do
        case "$dep" in
            "$brew_prefix"/*)
                install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$target"
                ;;
        esac
    done
done

# Artscripture is GPL-3.0-or-later; a distributed binary carries its licence.
cp -f "$repo_root/LICENSE" "$resources/LICENSE.txt"

# Sign the vendored libraries — install_name_tool invalidates any signature they
# arrived with — then the bundle. Inner code first, outermost last, which is the
# order codesign requires.
#
# **A real identity needs a secure timestamp and the hardened runtime here too,
# not just on the bundle.** This used to sign with `--timestamp=none`
# unconditionally, which is right for ad-hoc — Apple's timestamp server is a
# network round trip nobody wants on every local build — and fatal for
# distribution: notarisation rejected the archive with "The signature does not
# include a secure timestamp" against both dylibs, having accepted the app
# itself. Nested code is notarised on its own terms.
identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}
if [ "$identity" = "-" ]; then
    timestamp_flag="--timestamp=none"
    runtime_flag=""
else
    timestamp_flag="--timestamp"
    runtime_flag="--options runtime"
fi
for lib in "$frameworks"/*.dylib; do
    # shellcheck disable=SC2086 # runtime_flag is deliberately word-split or empty
    codesign --force --sign "$identity" $timestamp_flag $runtime_flag "$lib"
done

# Then confirm nothing outside the bundle and the OS is still being asked for.
# A dependency added without being vendored fails the build here rather than on
# somebody else's Mac.
leaked=$(
    for target in "$executable" "$frameworks"/*.dylib; do
        otool -L "$target" | awk 'NR > 1 { print $1 }'
    done | grep -v '^@rpath/' | grep -v '^/usr/lib/' | grep -v '^/System/' || true
)
if [ -n "$leaked" ]; then
    echo "error: the bundle still links libraries from outside itself:" >&2
    echo "$leaked" >&2
    echo "Add them to \$vendored in $0." >&2
    exit 1
fi

# And that every @rpath name resolves to something actually in Frameworks.
# Rewriting a load command to @rpath without copying the library would satisfy
# the check above while still failing to launch anywhere.
for target in "$executable" "$frameworks"/*.dylib; do
    otool -L "$target" | awk 'NR > 1 { print $1 }' | grep '^@rpath/' | while read -r dep; do
        if [ ! -f "$frameworks/${dep#@rpath/}" ]; then
            echo "error: $target wants $dep, which is not in Contents/Frameworks." >&2
            exit 1
        fi
    done || exit 1
done

echo "embedded:"
ls -1 "$frameworks" | sed 's/^/  /'
