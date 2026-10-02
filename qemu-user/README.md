# `qemu-user` with `SO_ORIGINAL_DST` forwarding

This directory holds the user-mode emulators used by the non-amd64 builds of
the image: **static** executables that emulate an **x86-64** guest, so that the
amd64 EasyConnect binaries can run inside a container of another architecture.
The prebuilt ones committed here are

| file | runs on | image platform | size | sha256 |
|---|---|---|---|---|
| `qemu-x86_64-i386` | i386 | `linux/386` | 5,025,800 | `81c5999a39a8` |
| `qemu-x86_64-arm64` | arm64 | `linux/arm64` | 4,394,608 | `2c3c71feb7d1` |
| `qemu-x86_64-armhf` | armhf | `linux/arm/v7` | 2,779,160 | `907c5f2f7eb3` |
| `qemu-x86_64-armel` | armel | `linux/arm/v5` | 3,801,124 | `9f2b753cc3cd` |
| `qemu-x86_64-ppc64el` | ppc64el | `linux/ppc64le` | 5,443,176 | `6c47e9e4e683` |
| `qemu-x86_64-riscv64` | riscv64 | `linux/riscv64` | 4,051,512 | `7dfc86aea643` |
| `qemu-x86_64-s390x` | s390x | `linux/s390x` | 4,936,544 | `bc676756819d` |

amd64 needs none: the EasyConnect binaries are amd64 and run natively there.
armel has an emulator but no image yet; see `doc/cli-images.md` for why.

```
$ file qemu-x86_64-armhf
qemu-x86_64-armhf: ELF 32-bit LSB executable, ARM, EABI5, statically linked, stripped
```

The patch itself lives in `linux-user/`, which is shared by every target, so
nothing here is armhf specific — `build.sh` produces the emulator for any
host/target pair QEMU 9.2 still supports.

## Building

```sh
./build.sh [HOST_ARCH] [TARGET_ARCH]
```

`HOST_ARCH` is the architecture the emulator will **run** on, named the Debian
way (`armhf`, `armel`, `arm64`, `i386`, `amd64`, `ppc64el`, `riscv64`, `s390x`,
`mips64el`).  `TARGET_ARCH` is the architecture it will **emulate**, named the
QEMU way (`x86_64`, `i386`, `arm`, `aarch64`, …).  Both default to the armhf →
x86_64 pair used by the image.

```sh
./build.sh                     # armhf  -> x86_64   (32-bit ARM host)
./build.sh armhf i386          # armhf  -> i386
./build.sh arm64 x86_64        # arm64  -> x86_64
./build.sh amd64 x86_64        # native x86-64 build
```

The result is written next to this script as `qemu-<TARGET_ARCH>-<HOST_ARCH>`.
Run it as root and it installs the cross toolchain itself; otherwise install
the toolchain first:

```sh
dpkg --add-architecture armhf
apt-get install gcc-arm-linux-gnueabihf libc6-dev:armhf \
                libglib2.0-dev:armhf pkg-config
python3 -m pip install meson ninja tomli
```

Notes:

* `--static` matters: the image is `debian:bookworm-slim` and the emulator
  must not depend on any armhf shared library beyond the kernel.
* Stripping takes the binary from 14 MB to 2.8 MB.

## Why this is not just `apt-get install qemu-user`

Upstream `build-scripts/add-qemu.sh` installs Debian's `qemu-user` package on
armhf.  That no longer works:

* QEMU **10.0** added *"Disallow 64-bit on 32-bit emulation and
  virtualization"* to `meson.build`, and QEMU **11** dropped 32-bit hosts
  entirely (`common-user/host/` only carries 64-bit hosts).  So no current
  QEMU can emulate an x86-64 guest on an armhf host.
* Consequently Debian **trixie** (the current `stable`) ships no 64-bit
  emulators in `qemu-user` on armhf, while installing the trixie package would
  also drag trixie's libc into a bookworm image.

The last QEMU series that still supports this configuration is **9.2**, so this
build uses **QEMU 9.2.3** from <https://download.qemu.org/>.  There is no flag
to override the `meson.build` check in QEMU >= 10.

## The `SO_ORIGINAL_DST` patch

`linux-user/syscall.c` implements `getsockopt()` in `do_getsockopt()`.  The
`case SOL_IP:` arm of that function only whitelists options whose value is a
plain `int`; `SO_ORIGINAL_DST` (80) is not in that list, so it falls into

```c
        default:
            ret = -TARGET_ENOPROTOOPT;
```

and the guest *always* sees `-ENOPROTOOPT` — the option never reaches the host
kernel.  That breaks every transparent-proxy style setup, because the
EasyConnect client uses `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)` to learn
the address a connection was redirected from.

`linux-user/syscall.c` is patched to

1. define `SO_ORIGINAL_DST` / `IP6T_SO_ORIGINAL_DST` as 80 when the host
   headers do not,
2. add `do_getsockopt_original_dst()`, which forwards the call to the host
   `getsockopt()` and converts the resulting `struct sockaddr` back to the
   guest (`host_to_target_sockaddr()`) and writes the real length back to the
   guest's `socklen_t`,
3. hook it up with `case SO_ORIGINAL_DST:` in the `SOL_IP` block and
   `case IP6T_SO_ORIGINAL_DST:` in the `SOL_IPV6` block.

The change is 79 added lines and no deletions; the diff is kept next to this
file as `qemu-9.2.3-so_original_dst.patch` (it applies with `patch -p1` from
the QEMU source root, and has been checked to reproduce byte-for-byte the tree
the shipped binary was built from).

Known gap, deliberately not patched: `do_setsockopt()` has the same style of
whitelist and does not know `IP_TRANSPARENT` (19), so a guest cannot *set* that
option.  `getsockopt` is the direction EasyConnect needs.

## How it is verified

`test/run_verify.sh` compiles the test program and runs four cases, each in its
own throw-away network namespace so the host's own networking is never touched:

```sh
unshare -n -- sh -c '
    ip link set lo up
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 \
             -j REDIRECT --to-ports 18080
    <emulator command> origdst_test'
```

The test program connects to 127.0.0.1:18081 — which the rule redirects to its
own listener on :18080 — and then prints what `SO_ORIGINAL_DST` reports.  A
correct emulator reports the *pre-redirect* port 18081.  The script exits
non-zero unless every case behaves as listed.

| # | how the test program runs | `SO_ORIGINAL_DST` says | expected |
|---|---|---|---|
| 1 | natively, no emulation | `127.0.0.1:18081` | PASS |
| 2 | patched `qemu-x86_64` on an x86-64 host | `127.0.0.1:18081` | PASS |
| 3 | **the armhf `qemu-x86_64-armhf`, run under a patched `qemu-arm`** | `127.0.0.1:18081` | PASS |
| 4 | `qemu-x86_64-armhf`, run under Debian's unpatched `qemu-arm` | `errno=92` (ENOPROTOOPT) | FAIL |

Case 3 is the end-to-end proof for the binary shipped here; case 4 is the
control that reproduces the original bug.

```sh
# case 3 needs a *patched* native qemu-arm as the outer emulator:
sudo ./build.sh amd64 arm
mkdir -p /tmp/native && cp qemu-arm-amd64 /tmp/native/qemu-arm
sudo env NATIVE_DIR=/tmp/native ./test/run_verify.sh
```

### Caveat when repeating this on an x86-64 host

An armhf emulator can only be executed on an x86-64 host through another
emulator (`qemu-arm`), and Debian's `qemu-arm` contains *the same unpatched
`do_getsockopt()`*.  In that nested setup the outer emulator answers
`-ENOPROTOOPT` first and hides the fix, exactly as case 4 shows.  Cases 2 and 3
therefore use a `qemu-arm` built from the same patched source; on a real armhf
host no outer emulator is involved at all.

### Verified inside the built image

The image ships this exact binary (sha256
`907c5f2f7eb32f5c81b614e53843fb00d13acfb4819a1771838ba7d6ec743a9c`).  Running
an x86-64 probe inside the armhf image shows the difference directly (measured
on that image; `test/run_verify.sh` re-checks the same property for the
binaries committed here on every CI run):

| image | `getsockopt(fd, SOL_IP, 80, ...)` | `getsockopt(fd, SOL_IP, 999, ...)` |
|---|---|---|
| upstream `cli-armhf` (Debian `qemu-user` 7.2, unpatched) | `errno=92` ENOPROTOOPT | `errno=92` ENOPROTOOPT |
| this image | `errno=2` ENOENT | `errno=92` ENOPROTOOPT |

A real option now reaches the kernel (`ENOENT` = the socket has no conntrack
entry to report), while an unknown option is still rejected — which is exactly
the kernel's own behaviour.
