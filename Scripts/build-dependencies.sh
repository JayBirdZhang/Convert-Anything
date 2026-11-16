#!/bin/bash
# Builds the two libraries the app links, as self-contained universal (Apple Silicon + Intel) files
# that run on macOS 14 and later without Homebrew:
#   ThirdParty/lib/libmp3lame.a, libwebp.a, libsharpyuv.a   (linked into the app)
#   ThirdParty/include/lame/lame.h, webp/*.h
#
# Sources come from Homebrew's checksum-verified download cache (Homebrew is only needed to build,
# not to run the app). Takes a minute. Run once; Xcode uses the results.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ThirdParty"
WORK="${TMPDIR:-/tmp}/convert-everything-deps"
MIN_MACOS=14.0
ARCHS=(arm64 x86_64)
JOBS=$(sysctl -n hw.ncpu)

# Keep Homebrew's libraries out of the build so nothing links against them.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CPPFLAGS LDFLAGS PKG_CONFIG_PATH

source_tarball() {
    /opt/homebrew/bin/brew fetch --quiet --build-from-source "$1" >/dev/null
    /opt/homebrew/bin/brew --cache --build-from-source "$1"
}

unpack() {   # unpack <tarball> <dir>
    rm -rf "$2"; mkdir -p "$2"
    tar -xf "$1" -C "$2" --strip-components 1
}

# Run a command for the target architecture (Intel builds run under Rosetta, so configure scripts
# can execute the test programs they compile).
for_arch() {
    local arch=$1; shift
    if [ "$arch" = x86_64 ]; then arch -x86_64 "$@"; else arch -arm64 "$@"; fi
}

mkdir -p "$WORK" "$OUT/lib" "$OUT/include"

# A stand-in pkg-config that finds no packages: configure scripts insist on having one.
mkdir -p "$WORK/stub"
printf '#!/bin/sh\ncase "$1" in --version) echo 0.29.2 ;; --atleast-pkgconfig-version) exit 0 ;; *) exit 1 ;; esac\n' > "$WORK/stub/pkg-config"
chmod +x "$WORK/stub/pkg-config"
export PATH="$WORK/stub:$PATH" PKG_CONFIG="$WORK/stub/pkg-config"

# --- LAME (MP3 encoder) ---------------------------------------------------------------------------
LAME_SRC=$(source_tarball lame)
for arch in "${ARCHS[@]}"; do
    dir="$WORK/lame-$arch"
    unpack "$LAME_SRC" "$dir"
    (cd "$dir" && for_arch "$arch" env CC=cc CFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -O2" \
        ./configure --quiet --disable-shared --enable-static --disable-frontend --disable-decoder \
        && for_arch "$arch" make -j"$JOBS" -C libmp3lame >/dev/null)
done
lipo -create "$WORK"/lame-*/libmp3lame/.libs/libmp3lame.a -output "$OUT/lib/libmp3lame.a"
mkdir -p "$OUT/include/lame" && cp "$WORK/lame-arm64/include/lame.h" "$OUT/include/lame/"
echo "LAME: done"

# --- libwebp (WebP encoder) -----------------------------------------------------------------------
WEBP_SRC=$(source_tarball webp)
for arch in "${ARCHS[@]}"; do
    dir="$WORK/webp-$arch"
    unpack "$WEBP_SRC" "$dir"
    (cd "$dir" && make -j"$JOBS" -f makefile.unix src/libwebp.a sharpyuv/libsharpyuv.a \
        CC="cc -arch $arch -mmacosx-version-min=$MIN_MACOS" >/dev/null)
done
lipo -create "$WORK"/webp-*/src/libwebp.a -output "$OUT/lib/libwebp.a"
lipo -create "$WORK"/webp-*/sharpyuv/libsharpyuv.a -output "$OUT/lib/libsharpyuv.a"
mkdir -p "$OUT/include/webp" && cp "$WORK"/webp-arm64/src/webp/{encode,types}.h "$OUT/include/webp/"
echo "WebP: done"

ls -lh "$OUT/lib"
for f in "$OUT/lib/"*.a; do lipo -info "$f"; done
