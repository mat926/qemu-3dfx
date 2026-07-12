#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_VERSION="${QEMU_VERSION:-9.2.2}"
QEMU_TARBALL="qemu-$QEMU_VERSION.tar.xz"
QEMU_URL="${QEMU_URL:-https://download.qemu.org/$QEMU_TARBALL}"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}"
DOWNLOAD_DIR="${QEMU_DOWNLOAD_DIR:-"$ROOT_DIR/.cache/qemu"}"
WORK_DIR="${QEMU_WORK_DIR:-"$ARTIFACT_DIR/qemu-build"}"
SOURCE_DIR="$WORK_DIR/qemu-$QEMU_VERSION"
BUILD_DIR="$WORK_DIR/build"
PACKAGE_ROOT="$WORK_DIR/package-root"
DIST_DIR="$ARTIFACT_DIR/qemu-binaries"
PACKAGE_NAME="${PACKAGE_NAME:-qemu-3dfx-qemu-$QEMU_VERSION-linux-x86_64}"
TARGET_LIST="${TARGET_LIST:-i386-softmmu,x86_64-softmmu}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd bash
require_cmd curl
require_cmd git
require_cmd make
require_cmd patch
require_cmd sha256sum
require_cmd tar

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$DIST_DIR"

if [[ -n "${QEMU_SOURCE_DIR:-}" ]]; then
  echo "Using QEMU source from $QEMU_SOURCE_DIR"
  cp -a "$QEMU_SOURCE_DIR" "$SOURCE_DIR"
else
  if [[ ! -f "$DOWNLOAD_DIR/$QEMU_TARBALL" ]]; then
    echo "Downloading $QEMU_URL"
    curl --fail --location --retry 5 --retry-delay 5 \
      --output "$DOWNLOAD_DIR/$QEMU_TARBALL" "$QEMU_URL"
  fi

  echo "Extracting $DOWNLOAD_DIR/$QEMU_TARBALL"
  tar -C "$WORK_DIR" -xf "$DOWNLOAD_DIR/$QEMU_TARBALL"
fi

echo "Applying qemu-3dfx patch to QEMU $QEMU_VERSION"
cp -a "$ROOT_DIR/qemu-0/hw/3dfx" "$SOURCE_DIR/hw/"
cp -a "$ROOT_DIR/qemu-1/hw/mesa" "$SOURCE_DIR/hw/"
(
  cd "$SOURCE_DIR"
  patch -p0 -i "$ROOT_DIR/00-qemu92x-mesa-glide.patch"
  bash "$ROOT_DIR/scripts/sign_commit"
)

mkdir -p "$BUILD_DIR"
echo "Configuring QEMU targets: $TARGET_LIST"
(
  cd "$BUILD_DIR"
  "$SOURCE_DIR/configure" \
    --prefix=/opt/qemu-3dfx \
    --target-list="$TARGET_LIST" \
    --enable-sdl \
    --enable-opengl \
    --enable-slirp \
    --enable-tools \
    --disable-docs \
    --disable-gtk \
    --disable-werror
)

echo "Building QEMU with $MAKE_JOBS jobs"
make -C "$BUILD_DIR" -j"$MAKE_JOBS"

echo "Verifying qemu-3dfx version banner"
"$BUILD_DIR/qemu-system-i386" --version | tee "$DIST_DIR/qemu-system-i386.version.txt"
"$BUILD_DIR/qemu-system-x86_64" --version | tee "$DIST_DIR/qemu-system-x86_64.version.txt"
grep -q 'featuring qemu-3dfx@' "$DIST_DIR/qemu-system-i386.version.txt"
grep -q 'featuring qemu-3dfx@' "$DIST_DIR/qemu-system-x86_64.version.txt"

echo "Installing QEMU into package root"
make -C "$BUILD_DIR" install DESTDIR="$PACKAGE_ROOT"

cat > "$PACKAGE_ROOT/opt/qemu-3dfx/README-qemu-3dfx.txt" <<EOF
qemu-3dfx QEMU $QEMU_VERSION Linux x86_64 build

Built from QEMU $QEMU_VERSION with the qemu-3dfx patch applied from this
repository branch.

Primary binaries:
  opt/qemu-3dfx/bin/qemu-system-i386
  opt/qemu-3dfx/bin/qemu-system-x86_64

The binaries are dynamically linked and are intended for Linux x86_64 systems
with compatible runtime libraries installed.
EOF

tar -C "$PACKAGE_ROOT" -czf "$DIST_DIR/$PACKAGE_NAME.tar.gz" opt
sha256sum "$DIST_DIR/$PACKAGE_NAME.tar.gz" > "$DIST_DIR/$PACKAGE_NAME.tar.gz.sha256"

echo "Created $DIST_DIR/$PACKAGE_NAME.tar.gz"
echo "Created $DIST_DIR/$PACKAGE_NAME.tar.gz.sha256"
