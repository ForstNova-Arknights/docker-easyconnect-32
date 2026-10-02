#!/bin/sh
#
# Verify that getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...) survives emulation.
#
#   ./run_verify.sh
#
# Environment overrides:
#   ARMHF_QEMU   the armhf qemu-x86_64 under test
#                (default: <repo>/qemu-armhf/qemu-x86_64)
#   NATIVE_DIR   directory holding a *patched* qemu-arm / qemu-x86_64 built for
#                this host, used to drive the armhf binary (default:
#                <repo>/qemu-armhf/build-native)
#
# Every case runs in its own throw-away network namespace, so the host's own
# networking is never modified.  The test program connects to 127.0.0.1:18081,
# which the REDIRECT rule sends to its own listener on :18080; a working
# getsockopt() reports the *pre-redirect* port 18081 back.
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ARMHF_QEMU=${ARMHF_QEMU:-"$ROOT/qemu-armhf/qemu-x86_64"}
NATIVE_DIR=${NATIVE_DIR:-"$ROOT/qemu-armhf/build-native"}
SYS_QEMU_ARM=${SYS_QEMU_ARM:-/usr/bin/qemu-arm-static}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== compiling test programs =="
gcc -O2 -static -o "$WORK/origdst_test" "$HERE/origdst_test.c" || exit 1
gcc -O2 -static -o "$WORK/probe2" "$HERE/probe2.c" || exit 1

run_case() {
    label=$1
    shift
    printf '\n===== %s =====\n' "$label"
    unshare -n -- sh -c '
        ip link set lo up
        iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 \
                 -j REDIRECT --to-ports 18080 || exit 9
        '"$*"'
    '
    printf 'exit=%s\n' "$?"
}

run_case "1. native x86_64 (reference, no emulation)" \
         "$WORK/origdst_test"

if [ -x "$NATIVE_DIR/qemu-x86_64" ]; then
    run_case "2. patched qemu-x86_64, native x86_64 host" \
             "$NATIVE_DIR/qemu-x86_64 $WORK/origdst_test"
else
    printf '\n===== 2. skipped: no %s =====\n' "$NATIVE_DIR/qemu-x86_64"
fi

if [ -x "$NATIVE_DIR/qemu-arm" ] && [ -x "$ARMHF_QEMU" ]; then
    run_case "3. armhf qemu-x86_64 under a patched qemu-arm" \
             "$NATIVE_DIR/qemu-arm $ARMHF_QEMU $WORK/origdst_test"
else
    printf '\n===== 3. skipped: need %s and %s =====\n' \
           "$NATIVE_DIR/qemu-arm" "$ARMHF_QEMU"
fi

if [ -x "$SYS_QEMU_ARM" ] && [ -x "$ARMHF_QEMU" ]; then
    run_case "4. armhf qemu-x86_64 under the distribution's unpatched qemu-arm (control)" \
             "$SYS_QEMU_ARM $ARMHF_QEMU $WORK/origdst_test"
else
    printf '\n===== 4. skipped: no %s =====\n' "$SYS_QEMU_ARM"
fi
