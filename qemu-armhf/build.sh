#!/bin/sh
#
# Cross-build a *static 32-bit ARM* qemu-x86_64 that forwards
# getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...) to the host kernel.
#
# Run this on a Debian/Ubuntu **x86-64** host; it produces qemu-x86_64 next to
# this script.  See README.md for why QEMU 9.2.3 is the version to use.
#
#   ./build.sh
#
set -eu

QEMU_VERSION=9.2.3
QEMU_URL="https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-"$HERE/build"}

# ---------------------------------------------------------------- dependencies
if [ "$(id -u)" -eq 0 ]; then
    echo "== installing build dependencies =="
    dpkg --add-architecture armhf
    apt-get update
    apt-get install -y --no-install-recommends \
        gcc-arm-linux-gnueabihf libc6-dev:armhf \
        libglib2.0-dev:armhf pkg-config xz-utils curl ca-certificates \
        python3-pip python3-venv ninja-build
    # QEMU's configure insists on a recent meson; the distro one is often too old.
    python3 -m pip install --break-system-packages meson tomli 2>/dev/null ||
        python3 -m pip install meson tomli
fi

# ------------------------------------------------------------------- source
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "qemu-${QEMU_VERSION}.tar.xz" ]; then
    echo "== downloading QEMU ${QEMU_VERSION} =="
    curl -fL -o "qemu-${QEMU_VERSION}.tar.xz" "$QEMU_URL"
fi
if [ ! -d "qemu-${QEMU_VERSION}" ]; then
    echo "== extracting =="
    tar xf "qemu-${QEMU_VERSION}.tar.xz"
fi

# -------------------------------------------------------------------- patch
cd "qemu-${QEMU_VERSION}"
echo "== applying the SO_ORIGINAL_DST patch =="
if grep -q 'do_getsockopt_original_dst' linux-user/syscall.c; then
    echo "   (already applied)"
else
    patch -p1 < "$HERE/qemu-${QEMU_VERSION}-so_original_dst.patch"
fi

# -------------------------------------------------------------------- build
echo "== configuring =="
mkdir -p build-armhf
cd build-armhf
PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig \
../configure --cross-prefix=arm-linux-gnueabihf- --cpu=arm \
             --target-list=x86_64-linux-user --static \
             --disable-system --disable-tools --disable-docs \
             --disable-guest-agent --disable-werror --disable-plugins \
             --disable-capstone --disable-install-blobs

echo "== building =="
ninja -j"$(nproc 2>/dev/null || echo 2)"

echo "== stripping =="
arm-linux-gnueabihf-strip -o "$HERE/qemu-x86_64" qemu-x86_64

echo
echo "== done: $HERE/qemu-x86_64 =="
ls -l "$HERE/qemu-x86_64"
file "$HERE/qemu-x86_64" 2>/dev/null || true
