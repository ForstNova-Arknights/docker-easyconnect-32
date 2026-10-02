#!/bin/sh
#
# Cross-build a *static* qemu-user emulator that forwards
#
#     getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)
#
# to the host kernel.  The patch lives in linux-user/ and is architecture
# independent, so the same script produces the emulator for any host/target
# pair that QEMU 9.2 supports.
#
#   ./build.sh [HOST_ARCH] [TARGET_ARCH]
#
#     HOST_ARCH    architecture the emulator will RUN on    (default: armhf)
#     TARGET_ARCH  architecture the emulator will EMULATE   (default: x86_64)
#
# HOST_ARCH uses Debian architecture names; TARGET_ARCH uses QEMU target names.
# The result is written next to this script as qemu-<TARGET_ARCH>-<HOST_ARCH>.
#
#   ./build.sh                     # armhf  -> x86_64   (32-bit ARM host)
#   ./build.sh armhf i386          # armhf  -> i386
#   ./build.sh arm64 x86_64        # arm64  -> x86_64
#   ./build.sh amd64 x86_64        # native x86-64 build
#
# See README.md for why QEMU 9.2 is the version to use.
#
set -eu

HOST_ARCH=${1:-armhf}
TARGET_ARCH=${2:-x86_64}

# ---------------------------------------------------------------- arch tables
case "$HOST_ARCH" in
    armhf)    DEB_ARCH=armhf;    CROSS=arm-linux-gnueabihf-;      CPU=arm;       TRIPLET=arm-linux-gnueabihf ;;
    armel)    DEB_ARCH=armel;    CROSS=arm-linux-gnueabi-;        CPU=arm;       TRIPLET=arm-linux-gnueabi ;;
    arm64)    DEB_ARCH=arm64;    CROSS=aarch64-linux-gnu-;        CPU=aarch64;   TRIPLET=aarch64-linux-gnu ;;
    i386)     DEB_ARCH=i386;     CROSS=i686-linux-gnu-;           CPU=i386;      TRIPLET=i686-linux-gnu ;;
    amd64)    DEB_ARCH=amd64;    CROSS=;                          CPU=x86_64;    TRIPLET=x86_64-linux-gnu ;;
    ppc64el)  DEB_ARCH=ppc64el;  CROSS=powerpc64le-linux-gnu-;    CPU=ppc64;     TRIPLET=powerpc64le-linux-gnu ;;
    riscv64)  DEB_ARCH=riscv64;  CROSS=riscv64-linux-gnu-;        CPU=riscv64;   TRIPLET=riscv64-linux-gnu ;;
    s390x)    DEB_ARCH=s390x;    CROSS=s390x-linux-gnu-;          CPU=s390x;     TRIPLET=s390x-linux-gnu ;;
    mips64el) DEB_ARCH=mips64el; CROSS=mips64el-linux-gnuabi64-;  CPU=mips64el;  TRIPLET=mips64el-linux-gnuabi64 ;;
    *) echo "build.sh: unsupported HOST_ARCH '$HOST_ARCH'" >&2; exit 1 ;;
esac

QEMU_VERSION=9.2.3
QEMU_URL="https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-"$HERE/build"}
OUT="$HERE/qemu-${TARGET_ARCH}-${HOST_ARCH}"

BUILD_ARCH=$(dpkg --print-architecture 2>/dev/null || echo unknown)
if [ "$HOST_ARCH" = "$BUILD_ARCH" ]; then
    NATIVE=yes
else
    NATIVE=no
fi

echo "== building qemu-${TARGET_ARCH} for ${HOST_ARCH} (native: $NATIVE) =="

# ---------------------------------------------------------------- dependencies
# Set SKIP_DEPS=1 to use a toolchain that is already installed.
if [ -z "${SKIP_DEPS:-}" ] && [ "$(id -u)" -eq 0 ]; then
    echo "== installing build dependencies =="
    apt_opts=""
    if [ "$NATIVE" = no ]; then
        dpkg --add-architecture "$DEB_ARCH"
        # Ubuntu keeps non-x86 architectures in the "ports" archive, and
        # security.ubuntu.com carries none of them, so a plain apt-get update
        # after dpkg --add-architecture 404s on every $DEB_ARCH index and the
        # whole build aborts.  Hand apt a private sources list for this run
        # instead of rewriting the system one.
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" = ubuntu ]; then
            codename=${VERSION_CODENAME:-jammy}
            sl="${TMPDIR:-/tmp}/qemu-crossbuild-sources.list"
            : > "$sl"
            for c in main universe; do
                printf 'deb [arch=%s] http://archive.ubuntu.com/ubuntu %s %s\n' "$BUILD_ARCH" "$codename" "$c" >> "$sl"
                printf 'deb [arch=%s] http://archive.ubuntu.com/ubuntu %s-updates %s\n' "$BUILD_ARCH" "$codename" "$c" >> "$sl"
                printf 'deb [arch=%s] http://security.ubuntu.com/ubuntu %s-security %s\n' "$BUILD_ARCH" "$codename" "$c" >> "$sl"
                printf 'deb [arch=%s] http://ports.ubuntu.com/ubuntu-ports %s %s\n' "$DEB_ARCH" "$codename" "$c" >> "$sl"
                printf 'deb [arch=%s] http://ports.ubuntu.com/ubuntu-ports %s-updates %s\n' "$DEB_ARCH" "$codename" "$c" >> "$sl"
                printf 'deb [arch=%s] http://ports.ubuntu.com/ubuntu-ports %s-security %s\n' "$DEB_ARCH" "$codename" "$c" >> "$sl"
            done
            apt_opts="-o Dir::Etc::sourcelist=$sl -o Dir::Etc::sourceparts=/dev/null"
        fi
    fi
    pkgs="pkg-config patch make xz-utils curl ca-certificates python3-pip python3-venv ninja-build"
    if [ "$NATIVE" = no ]; then
        pkgs="$pkgs gcc-$TRIPLET libc6-dev:$DEB_ARCH libglib2.0-dev:$DEB_ARCH"
    else
        pkgs="$pkgs gcc libc6-dev libglib2.0-dev"
    fi
    # shellcheck disable=SC2086
    apt-get $apt_opts update
    # shellcheck disable=SC2086
    apt-get $apt_opts install -y --no-install-recommends $pkgs
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
BUILDDIR="build-${TARGET_ARCH}-${HOST_ARCH}"
echo "== configuring =="
mkdir -p "$BUILDDIR"
cd "$BUILDDIR"

CONFIGURE_ARGS="--target-list=${TARGET_ARCH}-linux-user --static
    --disable-system --disable-tools --disable-docs --disable-guest-agent
    --disable-werror --disable-plugins --disable-capstone --disable-install-blobs"

if [ "$NATIVE" = yes ]; then
    # shellcheck disable=SC2086
    ../configure $CONFIGURE_ARGS
else
    # shellcheck disable=SC2086
    PKG_CONFIG_LIBDIR="/usr/lib/${TRIPLET}/pkgconfig:/usr/share/pkgconfig" \
        ../configure --cross-prefix="$CROSS" --cpu="$CPU" $CONFIGURE_ARGS
fi

echo "== building =="
ninja -j"$(nproc 2>/dev/null || echo 2)"

echo "== stripping =="
"${CROSS}strip" -o "$OUT" "qemu-${TARGET_ARCH}"

echo
echo "== done: $OUT =="
ls -l "$OUT"
file "$OUT" 2>/dev/null || true
