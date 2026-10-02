# CLI 镜像（多架构）构建说明

本仓库是 [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect)
的一个分支，为**每个架构**都构建一份纯命令行版（`cli`）镜像，其中包括上游没
有覆盖的 32 位架构。

上游的 `Dockerfile.cli` **只在 amd64 下构建**，因为 CLI 的二进制来自
`easyconn_7.6.8.2-ubuntu_amd64.deb`——无论镜像是什么架构，它们都是 amd64 的；
7.6.3 / 7.6.7 的 deb 只贡献 `conf` 目录。所以在其它任何架构上，这些 amd64
二进制都必须跑在 `qemu-user` 里，而上游依赖的发行版 `qemu-user` 在这里行不通
（原因见下）。本分支改为**自行交叉编译打过补丁的 `qemu-user`**，一个 host 架构
一份，打进对应镜像。

## 支持哪些架构

| 镜像架构 | Docker platform | 基础镜像 | EasyConnect 二进制 | 需要的模拟器 |
|---|---|---|---|---|
| amd64 | `linux/amd64` | bookworm | amd64（原生） | 不需要 |
| i386 | `linux/386` | bookworm | amd64 | `qemu-x86_64-i386` |
| arm64 | `linux/arm64` | bookworm | amd64 | `qemu-x86_64-arm64` |
| armhf | `linux/arm/v7` | bookworm | amd64 | `qemu-x86_64-armhf` |
| ppc64le | `linux/ppc64le` | bookworm | amd64 | `qemu-x86_64-ppc64el` |
| riscv64 | `linux/riscv64` | forky | amd64 | `qemu-x86_64-riscv64` |
| s390x | `linux/s390x` | forky | amd64 | `qemu-x86_64-s390x` |

基础镜像用 `BASE_SUITE` 选择，默认 `bookworm`。Debian 官方镜像并没有覆盖所有
架构——`debian:bookworm-slim` 只发布 `amd64, arm32v7, arm64v8, i386, ppc64le`
（见 [official-images 的 library/debian](https://github.com/docker-library/official-images/blob/master/library/debian)），
所以 riscv64 和 s390x 只能用更新的 tag（这里是 `forky`）。模拟器是静态编译的，
因此基础镜像的版本只影响镜像里的软件包。

但基础镜像的版本也不能随便挑：CLI 镜像的 SOCKS5 代理用的是 `/usr/sbin/danted`
（来自 `dante-server` 包）。`dante-server` 在 bookworm 里有，**trixie 已经把它删掉
了**（[madison](https://api.ftp-master.debian.org/madison?package=dante-server) 显示
它现在只在 forky/sid 里），forky 里则有。于是：

- amd64、i386、arm64、armhf、ppc64el 用 bookworm；
- riscv64、s390x 没有 bookworm 基础镜像，用 forky；
- **armel 不出镜像**：有 armel 基础镜像的 tag（trixie）里没有 `danted`，有 `danted`
  的 tag（bookworm、forky）里又没有 armel 基础镜像。armel 的模拟器仍然照常构建并
  提交（`qemu-x86_64-armel`），只要能自备 `danted`，用
  `--build-arg BASE_SUITE=trixie` 手动构建 `linux/arm/v5` 依旧可行。

**mips64el 不在支持之列**：Debian 官方镜像的**任何** tag 都没有发布
`linux/mips64le`，没有基础镜像就无从构建。（QEMU 9.2 本身是支持 mips64 作为宿主
的，`qemu-user/build.sh mips64el x86_64` 在别的构建环境里仍然可用。）

`Dockerfile.cli` 自己从 buildx 自动提供的 `TARGETARCH` / `TARGETVARIANT` 推导
镜像架构，不需要手工传参，也就不会和 `--platform` 不一致；推导出的架构等于
`EC_HOST`（即 amd64）时它什么都不装，二进制直接原生运行。

armel 的 platform 是 `linux/arm/v5` 而不是 `v6`——Debian 的 armel 就是 armv5 软浮点，
官方镜像发布的是 `arm32v5`。

## 为什么不能直接用 `apt install qemu-user`

两个互相独立的原因：

1. **32 位宿主拿不到 `qemu-x86_64`。** QEMU **10.0** 在 `meson.build` 中加入了
   「禁止 32 位宿主模拟 64 位 guest」的检查，QEMU **11** 则彻底移除了 32 位宿主
   支持。Debian trixie 的 armhf/armel/i386 `qemu-user` 因此不再提供
   `qemu-x86_64`。最后一个仍支持该组合的是 **QEMU 9.2** 系列。
2. **即使是 64 位宿主，发行版的 `qemu-user` 也是坏的。** 它的
   `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)` 会被模拟器自己拦下来，永远返回
   `-ENOPROTOOPT`，到不了宿主内核。

## 为什么需要打补丁

`linux-user/syscall.c` 的 `do_getsockopt()` 中，`case SOL_IP:` 只白名单了那些
返回 `int` 的选项，`SO_ORIGINAL_DST`（值为 80）不在其中，于是直接落到：

```c
        default:
            ret = -TARGET_ENOPROTOOPT;
```

结果就是**该选项永远不会被转发到宿主内核，guest 永远收到 `-ENOPROTOOPT`**。

EasyConnect 正是用 `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)` 来查询一条被
netfilter 重定向（`iptables -j REDIRECT` / DNAT）的连接**原本要访问的地址**，
所以这个缺陷会直接破坏透明代理场景。

补丁做了三件事：

1. 在宿主头文件没有定义时，把 `SO_ORIGINAL_DST` / `IP6T_SO_ORIGINAL_DST`
   定义为 80；
2. 新增 `do_getsockopt_original_dst()`，把调用转发给宿主 `getsockopt()`，再用
   `host_to_target_sockaddr()` 把 `struct sockaddr` 转回 guest，并把真实长度
   写回 guest 的 `socklen_t`；
3. 在 `SOL_IP` / `SOL_IPV6` 两个分支分别接上
   `SO_ORIGINAL_DST` / `IP6T_SO_ORIGINAL_DST`。

补丁共新增 79 行、删除 0 行，见
[`qemu-user/qemu-9.2.3-so_original_dst.patch`](../qemu-user/qemu-9.2.3-so_original_dst.patch)。
它位于 `linux-user/` 这一与目标架构无关的公共代码中，所以**一份补丁、一份源码，
交叉编译出所有 host 架构的模拟器**。

> 已知未处理的缺口：`do_setsockopt()` 有同样风格的白名单，不认识
> `IP_TRANSPARENT`(19)，guest 无法**设置**该选项。EasyConnect 需要的是
> `getsockopt` 方向，故未改动。

## 使用

### 直接拉取已发布的镜像

CI 会把每个架构的镜像推送到 GitHub Container Registry
（`ghcr.io/forstnova-arknights/docker-easyconnect-32`）：

| tag | platform | 基础镜像 | 拉取体积 |
|---|---|---|---|
| `:cli` | 多架构 manifest | — | — |
| `:cli-amd64` | `linux/amd64` | bookworm | 43 MB |
| `:cli-i386` | `linux/386` | bookworm | 57 MB |
| `:cli-arm64` | `linux/arm64` | bookworm | 56 MB |
| `:cli-armhf` | `linux/arm/v7` | bookworm | 51 MB |
| `:cli-ppc64el` | `linux/ppc64le` | bookworm | 61 MB |
| `:cli-riscv64` | `linux/riscv64` | forky | 63 MB |
| `:cli-s390x` | `linux/s390x` | forky | 65 MB |

每次构建还会额外推一个 `:sha-<commit>-<架构>`，方便把某个提交钉住。

```bash
# 多架构 manifest（Docker 会自动选匹配当前平台的）
docker pull ghcr.io/forstnova-arknights/docker-easyconnect-32:cli

# 或者显式指定某一个架构
docker pull --platform linux/arm/v7 \
    ghcr.io/forstnova-arknights/docker-easyconnect-32:cli-armhf
```

在 x86-64 机器上拉取**非本机架构**的镜像必须显式带 `--platform`，否则 Docker 会
报 `no matching manifest for linux/amd64`。

### 本地构建

```bash
# 1. 先抓取 EasyConnect 的 deb 包（体积大，故不进 git）
cd local-deps && ./fetch.sh && cd ..

# 2. 构建（以 armhf 为例）
docker buildx build --platform linux/arm/v7 \
    -f Dockerfile.cli -t docker-easyconnect:cli-armhf --load .
```

运行方式与上游 `cli` 镜像完全一致：

```bash
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti \
    -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 \
    -e EC_VER=7.6.3 -e CLI_OPTS="-d vpnaddress -u username -p password" \
    docker-easyconnect:cli-armhf
```

### 有些设备要用 `--privileged` 才能登录

实测**至少 x86-64 上，部分设备不加 `--privileged` 会登录失败**（能连上、但登录不成功），
加上 `--privileged` 就正常。触发条件还没摸清，也没能定位到具体是哪一步需要它，所以先
记在这里：遇到「连得上但登录不上」就先加 `--privileged` 试。它会把容器的隔离全部关掉，
能用 `--cap-add` 精确放权时不要用它。详见
[README 里对应的说明](../README.md#有些设备要用---privileged-才能登录)。

除 amd64 外，每个架构都需要仓库里对应的
[`qemu-user/qemu-x86_64-<架构>`](../qemu-user) 预编译二进制（已随仓库提供）。要
自己编译、或想换别的宿主/目标组合：

```bash
./qemu-user/build.sh armhf x86_64    # 默认就是 armhf -> x86_64
./qemu-user/build.sh amd64 x86_64    # 本机 x86-64 原生构建
```

细节（依赖列表、configure 参数、注意事项）见
[`qemu-user/README.md`](../qemu-user/README.md)。

## 关于镜像体积

EasyConnect 的三个 deb 包合计约 137 MB。构建时它们在 **`payload` 阶段**被解包，
只有解包结果被 `COPY --from` 进最终镜像；deb 包本身不进入任何最终镜像层。

这一点必须用多阶段构建实现：如果像常见写法那样 `COPY local-deps/` 之后再在后续
`RUN` 里 `rm -rf`，deb 包所在的层仍会留在镜像里——那样会白白多出 137 MB。

`payload` 阶段还固定使用 `$BUILDPLATFORM`，让 `dpkg -x` 在构建机架构上原生运行
而不是在模拟下运行（解包 amd64 的 deb 与架构无关），构建因此快了很多。

参考体积：armhf 52.9 MB（含 2.7 MB 模拟器），amd64 45.1 MB（不需要模拟器）。

## 为什么不再依赖 `hagb/docker-easyconnect:build`

上游的 `Dockerfile.cli` 用

```dockerfile
COPY --from=hagb/docker-easyconnect:build /results/fake-hwaddr/ /results/tinyproxy-ws/ /
```

取两个辅助产物（`fake-hwaddr.so` 用于伪造网卡 MAC，`tinyproxy` 是打了 websocket
补丁的版本）。这个 tag 只存在于构建过它的机器上：上游 CI 在本地
`docker buildx build -t hagb/docker-easyconnect:build -f Dockerfile.build .` 构建，
所有下游镜像构建完之后 `docker image rm` 掉，push 步骤里没有它——它是一个**纯本地
中间 tag**。于是照搬上游写法时流水线必然失败：

```
docker.io/hagb/docker-easyconnect:build: not found
```

自己构建它也走不通：上游的 `Dockerfile.build` 在 `EC_HOST=amd64` 时会安装
`crossbuild-essential-amd64`。该包在 armhf 的 trixie/bullseye 索引里**存在**，
但它依赖的交叉编译器 `gcc-x86-64-linux-gnu` **没有为 armhf 构建**，于是整个
依赖链不可安装。

所以本分支直接在 `Dockerfile.cli` 里构建这两个产物：

* `fake-hwaddr.so` 会被 `LD_PRELOAD` 进 EasyConnect 二进制，而那些二进制是
  amd64、跑在模拟器里，所以它**必须**是 x86-64 对象——因此在
  `linux/$EC_HOST` 平台上**原生编译**，而不是交叉编译；
* `tinyproxy` 在镜像里原生运行，所以按目标架构编译（arm/v7 下要跑几分钟，
  CI 里靠 BuildKit 缓存摊薄）。

这样 Dockerfile 就是自包含的：从干净的 checkout 出发、只需要 `local-deps/` 里的
deb 包就能构建，不依赖任何预置镜像。

## 验证

`qemu-user/test/run_verify.sh` 会在**各自独立的 network namespace** 中跑四个
用例（不会改动宿主机网络）：先加一条
`iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 -j REDIRECT --to-ports 18080`，
再让测试程序连接 `127.0.0.1:18081`（被重定向到它自己的 `:18080` 监听），最后打印
`SO_ORIGINAL_DST` 报告出来的地址——正确时应为**重定向前的 18081**。脚本对每个
用例断言预期结果，任一不符就以非 0 退出。

| # | 运行方式 | `SO_ORIGINAL_DST` | 预期 |
|---|---|---|---|
| 1 | 原生 x86_64（基准） | `127.0.0.1:18081` | PASS |
| 2 | 打过补丁的 `qemu-x86_64`（x86-64 宿主） | `127.0.0.1:18081` | PASS |
| 3 | **本仓库的 armhf `qemu-x86_64-armhf`**，外层用打过补丁的 `qemu-arm` | `127.0.0.1:18081` | PASS |
| 4 | 本仓库的 armhf `qemu-x86_64-armhf`，外层用发行版未打补丁的 `qemu-arm`（对照） | `errno=92` ENOPROTOOPT | FAIL |

镜像内的对比同样能看出差别（`optname 999` 是故意传入的非法选项）：

| 镜像 | `getsockopt(fd, SOL_IP, 80, ...)` | `getsockopt(fd, SOL_IP, 999, ...)` |
|---|---|---|
| 未打补丁（发行版 `qemu-user`） | `errno=92` ENOPROTOOPT | `errno=92` ENOPROTOOPT |
| 本分支构建的镜像 | `errno=2` ENOENT | `errno=92` ENOPROTOOPT |

打过补丁后，真实选项能到达内核（`ENOENT` 表示该 socket 没有 conntrack 记录可
报），而非法选项仍被拒绝——这正是内核自身的行为。

补丁位于与架构无关的公共代码中，所以上面这组功能验证在 **armhf** 上做完即可；
其余架构的模拟器在 CI 里另有一道冒烟测试（见下）。

### 在 x86-64 宿主上复现测试时的注意事项

armhf 的模拟器在 x86-64 宿主上必须再套一层 `qemu-arm` 才能执行，而发行版的
`qemu-arm` **含有同一处未修补的 `do_getsockopt()`**，会抢先返回
`-ENOPROTOOPT`，把修复完全掩盖掉（即上表用例 4）。因此用例 2、3 使用的是用
同一份补丁源码编译出来的 `qemu-arm`；在真实的 armhf 机器上不存在外层模拟器，
也就没有这个问题。

```bash
sudo ./qemu-user/build.sh amd64 arm            # 编译打过补丁的本机 qemu-arm
mkdir -p /tmp/native && cp qemu-user/qemu-arm-amd64 /tmp/native/qemu-arm
sudo env NATIVE_DIR=/tmp/native ./qemu-user/test/run_verify.sh
```

## 持续集成

[`.github/workflows/build-cli-images.yml`](../.github/workflows/build-cli-images.yml)
包含四个 job：

* **emulator** —— 矩阵构建每个架构的模拟器。默认使用仓库里已提交的二进制；
  勾选 `rebuild_emulator` 或推送 `v*` tag 时从头编译，产物作为 artifact 上传，
  tag 构建时还会附到 GitHub Release。

  每个模拟器都在**它自己架构的容器里原生构建**，而不是交叉编译。交叉编译看着更
  省事，但在这里不可行：它需要构建根里有目标架构的 libc 和 glib，而 amd64 构建根
  里的软件包带安全更新，armel/s390x/mips64el 却没有对应的更新版本——Debian 的
  `bookworm-security` 归档只包含 `amd64, arm64, armhf, i386, ppc64el`。`Multi-Arch:
  same` 的包必须版本一致，于是外来架构的 libc 直接不可安装：

  ```
  libssl3:s390x : Depends: libssl3 ... but it is not going to be installed
  ```

  原生构建没有需要协调的外来软件包，问题自然消失；产物是静态的，构建容器用哪个
  发行版也无所谓，只要该发行版发布了这个架构的基础镜像：armel、riscv64、s390x 用
  trixie（riscv64 在 bookworm 之后才成为 Debian 的正式发布架构），其余用 bookworm。
* **verify** —— 编译一个打过补丁的本机 `qemu-arm` / `qemu-x86_64` 作为外层模拟器，
  然后运行上面那张表的四个用例，断言不通过就让流水线失败；
* **image** —— 矩阵构建每个架构的镜像并推送到 GHCR（`:<tag>-<host>` 形式），
  并对每个非原生架构做一次冒烟测试（在镜像里执行 `qemu-x86_64 --version`）。
  这里**不能**用 `SO_ORIGINAL_DST` 做冒烟测试：在 runner 上外层模拟器是
  binfmt 注册的、未打补丁的那个，它会把每个架构都报成 `ENOPROTOOPT`；
* **manifest** —— 用 `docker buildx imagetools create` 把各架构镜像合成
  `:cli` 多架构 manifest。

PR 与 `push: false` 的手动触发只构建、不推送（此时镜像会 `--load` 进本地 daemon，
好让冒烟测试有东西可跑）。只改文档的推送不会触发重建，`push` 的 `paths-ignore` 把
`**.md`、`doc/**` 和 `LICENSE` 排除在外；打 tag 时路径过滤不生效，所以发版一定会跑。
