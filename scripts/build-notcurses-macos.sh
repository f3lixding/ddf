#!/usr/bin/env bash
set -euo pipefail

# Build notcurses on macOS with the tmux crash patch used by flake.nix.
#
# Requirements:
#   brew install cmake pkg-config ncurses libunistring libdeflate
#
# Usage:
#   ./scripts/build-notcurses-macos.sh
#
# Optional environment variables:
#   NOTCURSES_VERSION=3.0.17
#   BUILD_DIR=$PWD/.deps/notcurses-build
#   PREFIX=$PWD/.deps/notcurses
#   CMAKE_EXTRA_ARGS="-DSOME_FLAG=..."

NOTCURSES_VERSION="${NOTCURSES_VERSION:-3.0.17}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_DIR:-$ROOT_DIR/.deps/notcurses-build}"
PREFIX="${PREFIX:-$ROOT_DIR/.deps/notcurses}"
SRC_DIR="$BUILD_ROOT/src"
CMAKE_BUILD_DIR="$BUILD_ROOT/cmake-build"
PATCH_URL="https://github.com/dankamongmen/notcurses/pull/2926/changes/9e436185ff2da838e3d5f2d119c192537cbfab53.patch"
PATCH_FILE="$BUILD_ROOT/tmux-crash.patch"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script is intended for macOS/Darwin" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing command '$1'" >&2
    exit 1
  fi
}

need_cmd git
need_cmd curl
need_cmd cmake
need_cmd pkg-config
need_cmd brew

BREW_PREFIX="$(brew --prefix)"
NCURSES_PREFIX="$(brew --prefix ncurses)"
LIBUNISTRING_PREFIX="$(brew --prefix libunistring)"
LIBDEFLATE_PREFIX="$(brew --prefix libdeflate)"

mkdir -p "$BUILD_ROOT"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --depth 1 --branch "v$NOTCURSES_VERSION" \
    https://github.com/dankamongmen/notcurses.git \
    "$SRC_DIR"
fi

curl -L "$PATCH_URL" -o "$PATCH_FILE"

pushd "$SRC_DIR" >/dev/null
if ! git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  git apply --check "$PATCH_FILE"
  git apply "$PATCH_FILE"
else
  echo "patch already applied"
fi
popd >/dev/null

# Homebrew keeps ncurses keg-only on many macOS installs, so make discovery explicit.
export PKG_CONFIG_PATH="$NCURSES_PREFIX/lib/pkgconfig:$LIBUNISTRING_PREFIX/lib/pkgconfig:$LIBDEFLATE_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$NCURSES_PREFIX/include -I$LIBUNISTRING_PREFIX/include -I$LIBDEFLATE_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$NCURSES_PREFIX/lib -L$LIBUNISTRING_PREFIX/lib -L$LIBDEFLATE_PREFIX/lib ${LDFLAGS:-}"

cmake -S "$SRC_DIR" -B "$CMAKE_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$NCURSES_PREFIX;$LIBUNISTRING_PREFIX;$LIBDEFLATE_PREFIX;$BREW_PREFIX" \
  ${CMAKE_EXTRA_ARGS:-}

cmake --build "$CMAKE_BUILD_DIR" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$CMAKE_BUILD_DIR"

cat <<EOF

notcurses built and installed to:
  $PREFIX

For this project, you will likely need:
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
  export DYLD_LIBRARY_PATH="$PREFIX/lib:\${DYLD_LIBRARY_PATH:-}"

EOF
