# `qemu-x86_64` for armhf, with `SO_ORIGINAL_DST` forwarding

This directory holds the `qemu-x86_64` user-mode emulator used by the armhf
(`linux/arm/v7`) build of the image.  It is a **static 32-bit ARM executable**
that emulates an **x86-64** guest, i.e. it lets the amd64 EasyConnect binaries
run inside an armhf container.

```
$ file qemu-x86_64
qemu-x86_64: ELF 32-bit LSB executable, ARM, EABI5, statically linked, stripped
$ ls -l qemu-x86_64
-rwxr-xr-x 1 root root 2770980 ... qemu-x86_64
```

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
build uses **QEMU 9.2.3** from <https://download.qemu.org/>.

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
the QEMU source root).

Known gap, deliberately not patched: `do_setsockopt()` has the same style of
whitelist and does not know `IP_TRANSPARENT` (19), so a guest cannot *set* that
option.  `getsockopt` is the direction EasyConnect needs.

## How it was built

Cross toolchain and dependencies (on the x86-64 build host):

```sh
dpkg --add-architecture armhf
apt-get install gcc-arm-linux-gnueabihf libc6-dev:armhf \
                libglib2.0-dev:armhf pkg-config
python3 -m pip install meson ninja tomli
```

Then, from the QEMU 9.2.3 source tree:

```sh
tar xf qemu-9.2.3.tar.xz && cd qemu-9.2.3
patch -p1 < /path/to/qemu-9.2.3-so_original_dst.patch
mkdir build-armhf && cd build-armhf
PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig \
../configure --cross-prefix=arm-linux-gnueabihf- --cpu=arm \
             --target-list=x86_64-linux-user --static \
             --disable-system --disable-tools --disable-docs \
             --disable-guest-agent --disable-werror --disable-plugins \
             --disable-capstone --disable-install-blobs
ninja -j2
arm-linux-gnueabihf-strip -o qemu-x86_64.stripped qemu-x86_64
```

Notes:

* `--static` matters: the image is `debian:bookworm-slim` and the emulator
  must not depend on any armhf shared library beyond the kernel.
* Stripping takes the binary from 14 MB to 2.8 MB.
* The `meson.build` version check in QEMU >= 10 is exactly what makes 9.2.3
  the newest usable release; there is no flag to override it.

## How it is verified

Each case below runs in its own throw-away network namespace, so the host's
own networking is never touched:

```sh
unshare -n -- sh -c '
    ip link set lo up
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 \
             -j REDIRECT --to-ports 18080
    <emulator command> /opt/work/test/origdst_test'
```

The test program connects to 127.0.0.1:18081 — which the rule redirects to its
own listener on :18080 — and then prints what `SO_ORIGINAL_DST` reports.  A
correct emulator reports the *pre-redirect* port 18081.

| # | how the test program runs | `SO_ORIGINAL_DST` says | result |
|---|---|---|---|
| 1 | natively, no emulation | `127.0.0.1:18081` | PASS |
| 2 | patched `qemu-x86_64` on an x86-64 host | `127.0.0.1:18081` | PASS |
| 3 | **this armhf `qemu-x86_64`, run under a patched `qemu-arm`** | `127.0.0.1:18081` | PASS |
| 4 | this armhf `qemu-x86_64`, run under Debian's unpatched `qemu-arm` | `errno=92` (ENOPROTOOPT) | FAIL |

Case 3 is the end-to-end proof for the binary shipped here; case 4 is the
control that reproduces the original bug.

### Verified inside the built image

`hagb/docker-easyconnect:cli-armhf-patched` ships this exact binary
(sha256 `8038657949e07c006cab531dd97aed0386f2673a0221678d9a4bb620c570b016`).
Running an x86-64 probe inside the armhf image shows the difference directly:

| image | `getsockopt(fd, SOL_IP, 80, ...)` | `getsockopt(fd, SOL_IP, 999, ...)` |
|---|---|---|
| `cli-armhf` (Debian `qemu-user` 7.2, unpatched) | `errno=92` ENOPROTOOPT | `errno=92` ENOPROTOOPT |
| `cli-armhf-patched` (this build) | `errno=2` ENOENT | `errno=92` ENOPROTOOPT |

A real option now reaches the kernel (`ENOENT` = the socket has no conntrack
entry to report), while an unknown option is still rejected — which is exactly
the kernel's own behaviour.

### Caveat when repeating this on an x86-64 host

An armhf emulator can only be executed on an x86-64 host through another
emulator (`qemu-arm`), and Debian's `qemu-arm` contains *the same unpatched
`do_getsockopt()`*.  In that nested setup the outer emulator answers
`-ENOPROTOOPT` first and hides the fix, exactly as case 4 shows.  Cases 2 and 3
therefore use a `qemu-arm` built from the same patched source; on a real armhf
host no outer emulator is involved at all.
