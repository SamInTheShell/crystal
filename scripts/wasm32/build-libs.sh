#!/usr/bin/env bash
# Cross-compiles the third-party C libraries that the Crystal standard library
# links against, for the wasm32-wasi target, using wasi-sdk.
#
# Usage:
#   scripts/wasm32/build-libs.sh [--prefix DIR] [--jobs N] [lib...]
#
# Environment:
#   WASI_SDK_PATH   path to an unpacked wasi-sdk (default: /opt/wasi-sdk)
#
# With no library names, every supported library is built. Sources are
# downloaded into $PREFIX/src and verified against pinned SHA-256 digests, so
# the resulting tree is reproducible. Only static archives (.a) and headers are
# installed; wasm32-wasi has no shared libraries.
#
# The resulting directory is meant to be used as CRYSTAL_LIBRARY_PATH (merged
# with, or on top of, the wasi-libc sysroot libraries).

set -euo pipefail

WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
PREFIX="$PWD/wasm32-wasi-libs"
JOBS="$(nproc 2>/dev/null || echo 4)"

ZLIB_VERSION=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --jobs)   JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

LIBS=("$@")
if [ ${#LIBS[@]} -eq 0 ]; then
  LIBS=(zlib)
fi

if [ ! -x "$WASI_SDK_PATH/bin/clang" ]; then
  echo "WASI_SDK_PATH=$WASI_SDK_PATH does not contain bin/clang" >&2
  exit 1
fi

# The wasi-sdk clang.cfg already sets --sysroot and the default target; we
# still pass the target explicitly so build systems that probe $CC see it.
# `wasm32-wasip1` is the current spelling of what Crystal (and older
# toolchains) call `wasm32-wasi`; the ABI and the produced objects are the
# same, wasi-sdk 33 merely warns about the old name.
export CC="$WASI_SDK_PATH/bin/clang --target=wasm32-wasip1"
export CXX="$WASI_SDK_PATH/bin/clang++ --target=wasm32-wasip1"
export AR="$WASI_SDK_PATH/bin/ar"
export RANLIB="$WASI_SDK_PATH/bin/ranlib"
export NM="$WASI_SDK_PATH/bin/nm"
export STRIP="$WASI_SDK_PATH/bin/strip"
export CFLAGS="-O2"
export CXXFLAGS="-O2"

mkdir -p "$PREFIX/src" "$PREFIX/include"
PREFIX="$(cd "$PREFIX" && pwd)"
SRC="$PREFIX/src"

fetch() {
  # fetch URL SHA256 -> prints local path
  local url="$1" sha="$2" file
  file="$SRC/$(basename "$url")"
  if [ ! -f "$file" ]; then
    echo "==> downloading $url" >&2
    curl -fsSL -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
  echo "$sha  $file" | sha256sum -c - >/dev/null
  echo "$file"
}

build_zlib() {
  local tarball dir="$SRC/zlib-$ZLIB_VERSION"
  tarball="$(fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" "$ZLIB_SHA256")"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  (
    cd "$dir"
    # zlib's configure honours $CC/$AR/$RANLIB; CHOST stops it from trying
    # to run a host-detection binary.
    CHOST=wasm32-wasip1 ./configure --static --prefix="$PREFIX" >configure.log
    make -j"$JOBS" libz.a >make.log
    cp libz.a "$PREFIX/"
    cp zlib.h zconf.h "$PREFIX/include/"
  )
  echo "==> built zlib $ZLIB_VERSION"
}

for lib in "${LIBS[@]}"; do
  case "$lib" in
    zlib) build_zlib ;;
    *) echo "unknown library: $lib (supported: zlib)" >&2; exit 1 ;;
  esac
done

echo "==> done: $PREFIX"
