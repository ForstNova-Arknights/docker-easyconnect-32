# 32 位（armhf / `linux/arm/v7`）平台构建说明

本仓库是 [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect)
的一个分支，增加了在 **32 位 ARM（armhf）** 上构建纯命令行版镜像的能力。

上游的 `Dockerfile.cli` 依赖发行版的 `qemu-user` 包在 armhf 上模拟 amd64 的
EasyConnect 二进制，这条路现在已经走不通了（原因见下）。本分支改为**自行交叉
编译一个打过补丁的 `qemu-user`**，并把它打进镜像。

## 为什么不能直接用 `apt install qemu-user`

* QEMU **10.0** 在 `meson.build` 中加入了「禁止 32 位宿主模拟 64 位 guest」的
  检查，QEMU **11** 则彻底移除了 32 位宿主支持（`common-user/host/` 下只剩
  64 位宿主）。因此**当前任何 QEMU 版本都无法在 armhf 上模拟 x86-64 guest**。
* 相应地，Debian **trixie** 的 armhf `qemu-user` 已经不再提供 `qemu-x86_64`；
  而 trixie 的包又会把 trixie 的 libc 拖进 bookworm 镜像。

最后一个仍支持该组合的是 **QEMU 9.2** 系列，所以本分支使用 **9.2.3**。

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
它位于 `linux-user/` 这一与目标架构无关的公共代码中，**不局限于 armhf**。

> 已知未处理的缺口：`do_setsockopt()` 有同样风格的白名单，不认识
> `IP_TRANSPARENT`(19)，guest 无法**设置**该选项。EasyConnect 需要的是
> `getsockopt` 方向，故未改动。

## 使用

### 直接拉取已发布的镜像

CI 会把镜像推送到 GitHub Container Registry，通常无需本地构建：

```bash
docker pull --platform linux/arm/v7 \
    ghcr.io/forstnova-arknights/docker-easyconnect-32:cli-armhf
```

镜像只有 `linux/arm/v7` 一个平台，在 x86-64 机器上拉取**必须**显式带上
`--platform linux/arm/v7`，否则 Docker 会报
`no matching manifest for linux/amd64 in the manifest list entries`。

### 本地构建

镜像可以直接构建：

```bash
# 1. 先抓取 EasyConnect 的 deb 包（体积大，故不进 git）
cd local-deps && ./fetch.sh && cd ..

# 2. 构建 armhf 镜像
docker buildx build --platform linux/arm/v7 \
    -f Dockerfile.cli-armhf -t docker-easyconnect:cli-armhf --load .
```

运行方式与上游 `cli` 镜像完全一致：

```bash
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti \
    -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 \
    -e EC_VER=7.6.3 -e CLI_OPTS="-d vpnaddress -u username -p password" \
    docker-easyconnect:cli-armhf
```

仓库中已经附带了编译好的静态 armhf 二进制
[`qemu-user/qemu-x86_64-armhf`](../qemu-user/qemu-x86_64-armhf)（2.8 MB），所以
上一步的第 2 条命令可以直接使用，无需自己编译 QEMU。

### 关于镜像体积

EasyConnect 的三个 deb 包合计约 137 MB。构建时它们在 **`payload` 阶段**被解包，
只有解包结果被 `COPY --from` 进最终镜像；deb 包本身不进入任何最终镜像层。

这一点必须用多阶段构建实现：如果像常见写法那样 `COPY local-deps/` 之后再在后续
`RUN` 里 `rm -rf`，deb 包所在的层仍会留在镜像里——那样会白白多出 137 MB。

`payload` 阶段还固定使用 `$BUILDPLATFORM`，让 `dpkg -x` 在构建机架构上原生运行
而不是在模拟下运行（解包 amd64 的 deb 与架构无关），构建因此快了很多。

### 为什么不再依赖 `hagb/docker-easyconnect:build`

上游的 `Dockerfile.cli` 用

```dockerfile
COPY --from=hagb/docker-easyconnect:build /results/fake-hwaddr/ /results/tinyproxy-ws/ /
```

取两个辅助产物。这个镜像只存在于构建过它的机器上（Docker Hub 上没有公开的
`build` tag），所以照搬上游写法时流水线必然失败：

```
docker.io/hagb/docker-easyconnect:build: not found
```

自己构建它也走不通：上游的 `Dockerfile.build` 在 `EC_HOST=amd64` 时会安装
`crossbuild-essential-amd64`。该包在 armhf 的 trixie/bullseye 索引里**存在**，
但它依赖的交叉编译器 `gcc-x86-64-linux-gnu` **没有为 armhf 构建**，于是整个
依赖链不可安装。

上游自己的流水线也从不需要这个 tag 是公开的：它在本地
`docker buildx build -t hagb/docker-easyconnect:build -f Dockerfile.build .`
构建，所有下游镜像构建完之后 `docker image rm` 掉，push 步骤里没有它——所以它
是一个**纯本地中间 tag**。而且上游 CI 的 `archs` 只有
`mips64le arm64 i386 amd64`，`Dockerfile.cli` 更是**只在 amd64 下构建**，armhf
的 cli 镜像上游没有任何产物。

所以本分支直接在 `Dockerfile.cli-armhf` 里构建这两个产物：

* `fake-hwaddr.so` 会被 `LD_PRELOAD` 进 EasyConnect 二进制，而那些二进制是
  amd64、跑在模拟器里，所以它**必须**是 x86-64 对象——因此在
  `linux/$EC_HOST` 平台上**原生编译**，而不是交叉编译；
* `tinyproxy` 在镜像里原生运行，所以按目标架构编译（arm/v7 下要跑几分钟，
  CI 里靠 BuildKit 缓存摊薄）。

这样 Dockerfile 就是自包含的：从干净的 checkout 出发、只需要 `local-deps/` 里的
deb 包就能构建，不依赖任何预置镜像。

### QEMU 架构选项

补丁与架构无关，所以 emulator 也可以换成别的宿主/目标组合。`Dockerfile.cli-armhf`
暴露了三个构建参数：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `QEMU_HOST_ARCH` | `armhf` | 镜像运行的架构（Debian 命名），决定用哪个预编译二进制 |
| `QEMU_TARGET_ARCH` | `x86_64` | 被模拟的架构（QEMU 命名），必须与 `EC_HOST` 对应 |
| `EC_HOST` | `amd64` | EasyConnect 二进制本身的架构（Debian 命名） |

```bash
docker buildx build --platform linux/arm/v7 -f Dockerfile.cli-armhf \
    --build-arg QEMU_HOST_ARCH=armhf \
    --build-arg QEMU_TARGET_ARCH=x86_64 \
    --build-arg EC_HOST=amd64 \
    -t docker-easyconnect:cli-armhf --load .
```

换成别的组合时，需要先用 [`qemu-user/build.sh`](../qemu-user/build.sh) 生成对应
的 `qemu-user/qemu-<TARGET_ARCH>-<HOST_ARCH>`：

```bash
./qemu-user/build.sh                # armhf  -> x86_64（默认）
./qemu-user/build.sh arm64 x86_64   # arm64  -> x86_64
./qemu-user/build.sh amd64 x86_64   # 本机 x86-64 原生构建
```

细节（依赖列表、configure 参数、注意事项）见
[`qemu-user/README.md`](../qemu-user/README.md)。

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
| 上游 `cli-armhf`（Debian `qemu-user` 7.2，未打补丁） | `errno=92` ENOPROTOOPT | `errno=92` ENOPROTOOPT |
| 本分支构建的镜像 | `errno=2` ENOENT | `errno=92` ENOPROTOOPT |

打过补丁后，真实选项能到达内核（`ENOENT` 表示该 socket 没有 conntrack 记录可
报），而非法选项仍被拒绝——这正是内核自身的行为。

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

[`.github/workflows/build-armhf-cli-image.yml`](../.github/workflows/build-armhf-cli-image.yml)
包含三个 job：

* **emulator** —— 在云端交叉编译 emulator（`workflow_dispatch` 勾选
  `rebuild_emulator`，或推送 `v*` tag 时触发），产物作为 artifact 上传，
  并在 tag 构建时附到 GitHub Release；
* **verify** —— 编译一个打过补丁的本机 `qemu-arm` 作为外层模拟器，然后运行
  上面那张表的四个用例，断言不通过就让流水线失败；
* **image** —— 拉取 EasyConnect 包、构建 `linux/arm/v7` 镜像并推送到
  GitHub Container Registry：

  ```
  ghcr.io/<owner>/docker-easyconnect-32:cli-armhf
  ghcr.io/<owner>/docker-easyconnect-32:master
  ghcr.io/<owner>/docker-easyconnect-32:sha-<commit>
  ```

  PR 与 `push: false` 的手动触发只构建、不推送。
