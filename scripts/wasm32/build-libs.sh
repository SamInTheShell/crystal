#!/usr/bin/env bash
# Cross-compiles the third-party C libraries that the Crystal standard library
# links against, for the wasm32-wasi target, using wasi-sdk.
#
# Usage:
#   scripts/wasm32/build-libs.sh [--prefix DIR] [--jobs N] [zlib|gmp|libyaml|libxml2 ...]
#
# Environment:
#   WASI_SDK_PATH   path to an unpacked wasi-sdk (default: /opt/wasi-sdk)
#
# With no library names, every supported library is built. Sources are
# downloaded into $PREFIX/src and verified against pinned SHA-256 digests, so
# the resulting tree is reproducible. Only static archives (.a) and headers are
# installed; wasm32-wasi has no shared libraries.
#
# Archives end up in $PREFIX/lib, which is meant to be added to
# CRYSTAL_LIBRARY_PATH next to the wasi-libc sysroot libraries.

set -euo pipefail

WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
PREFIX="$PWD/wasm32-wasi-libs"
JOBS="$(nproc 2>/dev/null || echo 4)"

ZLIB_VERSION=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
GMP_VERSION=6.3.0
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
LIBYAML_VERSION=0.2.5
LIBYAML_SHA256=c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
LIBXML2_VERSION=2.13.8
LIBXML2_SHA256=277294cb33119ab71b2bc81f2f445e9bc9435b893ad15bb2cd2b0e859a0ee84a

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
  LIBS=(zlib gmp libyaml libxml2)
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
    mkdir -p "$PREFIX/lib"
    cp libz.a "$PREFIX/lib/"
    cp zlib.h zconf.h "$PREFIX/include/"
  )
  echo "==> built zlib $ZLIB_VERSION"
}

# Common flags for autotools-based projects. `--host` puts configure into
# cross-compilation mode so it never tries to run the binaries it builds.
AUTOTOOLS_FLAGS=(--host=wasm32-wasip1 --prefix="$PREFIX" --disable-shared --enable-static)

# Older releases ship a config.sub that predates the wasm32-wasip1 triple.
# wasi-sdk provides up-to-date copies for exactly this purpose.
refresh_config_sub() {
  local dir="$1" f
  while IFS= read -r -d '' f; do
    cp "$WASI_SDK_PATH/share/misc/$(basename "$f")" "$f"
  done < <(find "$dir" -name config.sub -print0 -o -name config.guess -print0)
}

build_gmp() {
  local tarball dir="$SRC/gmp-$GMP_VERSION"
  tarball="$(fetch "https://gmplib.org/download/gmp/gmp-$GMP_VERSION.tar.xz" "$GMP_SHA256")"
  rm -rf "$dir"
  tar -xJf "$tarball" -C "$SRC"
  (
    cd "$dir"
    # No hand-written assembly exists for wasm32, so use the generic C
    # implementation. gmp reports invalid operations (e.g. division by
    # zero) with `raise(SIGFPE)`, which WASI only provides through
    # wasi-libc's signal emulation: compile with _WASI_EMULATED_SIGNAL and
    # link the final program with -lwasi-emulated-signal (Crystal's LibGMP
    # binding does that on wasm32).
    # configure can't see `raise` on its own because its link test doesn't
    # use the emulation library, hence the cache override.
    CFLAGS="$CFLAGS -D_WASI_EMULATED_SIGNAL" ac_cv_func_raise=yes \
      ./configure "${AUTOTOOLS_FLAGS[@]}" --disable-assembly --enable-cxx=no >configure.log
    make -j"$JOBS" >make.log
    make install >install.log
  )
  echo "==> built gmp $GMP_VERSION"
}

build_libyaml() {
  local tarball dir="$SRC/yaml-$LIBYAML_VERSION"
  tarball="$(fetch "https://github.com/yaml/libyaml/releases/download/$LIBYAML_VERSION/yaml-$LIBYAML_VERSION.tar.gz" "$LIBYAML_SHA256")"
  rm -rf "$dir"
  tar -xzf "$tarball" -C "$SRC"
  refresh_config_sub "$dir"
  (
    cd "$dir"
    ./configure "${AUTOTOOLS_FLAGS[@]}" >configure.log
    make -j"$JOBS" >make.log
    make install >install.log
  )
  echo "==> built libyaml $LIBYAML_VERSION"
}

build_libxml2() {
  local tarball dir="$SRC/libxml2-$LIBXML2_VERSION"
  tarball="$(fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.tar.xz" "$LIBXML2_SHA256")"
  rm -rf "$dir"
  tar -xJf "$tarball" -C "$SRC"
  refresh_config_sub "$dir"
  (
    cd "$dir"
    # Crystal's XML module doesn't need the network fetchers, the Python
    # bindings or the command line tools. Threads aren't available on
    # wasm32-wasi, and zlib/lzma support is left out to keep the archive
    # self-contained.
    #
    # WASI has no `dup(2)`. libxml2 only calls it when parsing from a caller
    # supplied file descriptor (`xmlReadFd` and friends) or when writing to
    # "-", neither of which Crystal uses, so make those paths fail cleanly.
    cat >wasi-compat.h <<'H'
#include <errno.h>
static inline int dup(int fd) { (void)fd; errno = ENOSYS; return -1; }
H
    CFLAGS="$CFLAGS -include $PWD/wasi-compat.h" \
      ./configure "${AUTOTOOLS_FLAGS[@]}" \
      --without-python --without-threads --without-http --without-ftp \
      --without-zlib --without-lzma --without-iconv --without-icu \
      --without-modules --without-debug >configure.log
    make -j"$JOBS" >make.log
    make install >install.log
    # Without thread support libxml2 exposes its error handler globals as
    # plain variables and drops the `__xmlGenericError()`-style accessors
    # that threaded builds (and Crystal's LibXML binding) use. Provide them
    # with the same semantics so the binding works with either build.
    cat >wasi-globals.c <<'C'
#include <libxml/xmlerror.h>
#include <libxml/globals.h>
xmlGenericErrorFunc *__xmlGenericError(void) { return &xmlGenericError; }
void **__xmlGenericErrorContext(void) { return &xmlGenericErrorContext; }
xmlStructuredErrorFunc *__xmlStructuredError(void) { return &xmlStructuredError; }
void **__xmlStructuredErrorContext(void) { return &xmlStructuredErrorContext; }
int *__xmlIndentTreeOutput(void) { return &xmlIndentTreeOutput; }
const char **__xmlTreeIndentString(void) { return &xmlTreeIndentString; }
C
    $CC $CFLAGS -Iinclude -c wasi-globals.c -o wasi-globals.o
    $AR rcs "$PREFIX/lib/libxml2.a" wasi-globals.o
    # There is no pkg-config for the target: Crystal's LibXML binding reads
    # the version from this file (next to the archive) on wasm32.
    echo "$LIBXML2_VERSION" >"$PREFIX/lib/libxml_VERSION"
  )
  echo "==> built libxml2 $LIBXML2_VERSION"
}

for lib in "${LIBS[@]}"; do
  case "$lib" in
    zlib) build_zlib ;;
    gmp) build_gmp ;;
    libyaml) build_libyaml ;;
    libxml2) build_libxml2 ;;
    *) echo "unknown library: $lib (supported: zlib gmp libyaml libxml2)" >&2; exit 1 ;;
  esac
done

# Only static archives and headers are useful downstream. pkg-config files
# and libtool archives refer to $PREFIX and would only confuse the linker.
rm -rf "$PREFIX/lib/pkgconfig" "$PREFIX/share" "$PREFIX"/lib/*.la

echo "==> done: $PREFIX"
