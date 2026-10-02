#!/bin/sh
#
# Verify that getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...) survives emulation.
#
#   ./run_verify.sh
#
# Environment overrides:
#   ARMHF_QEMU   the qemu-user binary under test
#                (default: <repo>/qemu-user/qemu-x86_64-armhf)
#   NATIVE_DIR   directory holding *patched* emulators built for this host,
#                named qemu-x86_64 and qemu-arm; used to drive the binary under
#                test and to check the patch on the host architecture
#                (default: <repo>/qemu-user/build-native)
#   SYS_QEMU_ARM the distribution's (unpatched) qemu-arm-static, used as a
#                control (default: /usr/bin/qemu-arm-static)
#
# Every case runs in its own throw-away network namespace, so the host's own
# networking is never modified.  The test program connects to 127.0.0.1:18081,
# which the REDIRECT rule sends to its own listener on :18080; a working
# getsockopt() reports the *pre-redirect* port 18081 back.
#
# Exits non-zero if any case does not behave as expected.
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ARMHF_QEMU=${ARMHF_QEMU:-"$ROOT/qemu-user/qemu-x86_64-armhf"}
NATIVE_DIR=${NATIVE_DIR:-"$ROOT/qemu-user/build-native"}
SYS_QEMU_ARM=${SYS_QEMU_ARM:-/usr/bin/qemu-arm-static}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0

echo "== compiling test programs =="
gcc -O2 -static -o "$WORK/origdst_test" "$HERE/origdst_test.c" || exit 1

# run_case <label> <expect: pass|fail> <command...>
run_case() {
    label=$1
    expect=$2
    shift 2

    printf '\n===== %s =====\n' "$label"
    unshare -n -- sh -c '
        ip link set lo up
        iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 \
                 -j REDIRECT --to-ports 18080 || exit 9
        '"$*"'
    '
    rc=$?

    if { [ "$expect" = pass ] && [ "$rc" -eq 0 ]; } ||
       { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
        printf '>>> OK (%s, exit=%s)\n' "$expect" "$rc"
    else
        printf '>>> UNEXPECTED: expected %s, exit=%s\n' "$expect" "$rc"
        FAILED=1
    fi
}

skip() {
    printf '\n===== %s =====\n>>> SKIPPED: %s\n' "$1" "$2"
}

# 1. the host itself, no emulation involved
run_case "1. native x86_64 (reference, no emulation)" pass \
         "$WORK/origdst_test"

# 2. the patch, exercised on the host architecture
if [ -x "$NATIVE_DIR/qemu-x86_64" ]; then
    run_case "2. patched qemu-x86_64, native x86_64 host" pass \
             "$NATIVE_DIR/qemu-x86_64 $WORK/origdst_test"
else
    skip "2. patched qemu-x86_64, native x86_64 host" "no $NATIVE_DIR/qemu-x86_64"
fi

# 3. the actual artifact: the cross-built emulator, driven by a patched qemu-arm
if [ -x "$NATIVE_DIR/qemu-arm" ] && [ -x "$ARMHF_QEMU" ]; then
    run_case "3. $ARMHF_QEMU under a patched qemu-arm" pass \
             "$NATIVE_DIR/qemu-arm $ARMHF_QEMU $WORK/origdst_test"
else
    skip "3. $ARMHF_QEMU under a patched qemu-arm" \
         "need $NATIVE_DIR/qemu-arm and $ARMHF_QEMU"
fi

# 4. control: the distribution's qemu-arm has the same unpatched
#    do_getsockopt(), so it must *not* be able to forward the option
if [ -x "$SYS_QEMU_ARM" ] && [ -x "$ARMHF_QEMU" ]; then
    run_case "4. $ARMHF_QEMU under the distribution's unpatched qemu-arm (control)" fail \
             "$SYS_QEMU_ARM $ARMHF_QEMU $WORK/origdst_test"
else
    skip "4. control under the distribution's qemu-arm" "no $SYS_QEMU_ARM"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "== all cases behaved as expected =="
else
    echo "== FAILURES ==" >&2
fi
exit "$FAILED"
