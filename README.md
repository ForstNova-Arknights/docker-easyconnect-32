# docker-easyconnect

让深信服开发的**非自由**的 VPN 软件 EasyConnect 或 aTrust 运行在 docker 中，提供 [socks5 和 http 代理](doc/usage.md#代理服务)服务和[网关](doc/usage.md#ip-forward)供宿主机连接使用。

本项目基于 EasyConnect 官方“Linux”版的 deb 包、[@shmille](https://github.com/shmilee) 提供的[命令行版客户端 deb 包](https://github.com/shmilee/scripts/releases/download/v0.0.1/easyconn_7.6.8.2-ubuntu_amd64.deb)、aTrust 官方“Linux”版 deb 包，这些 deb 包的版权归深信服（Sangfor）所有，请不要滥用本项目。本项目**不是**深信服官方项目。

**招募项目维护者，有兴趣可在 [#275](https://github.com/docker-easyconnect/docker-easyconnect/issues/275) 下回复。**

欢迎批评、指正，提交 issue、PR，包括但不仅限于 bug、各种疑问、代码和文档的改进。

详细用法见于 [doc/usage.md](doc/usage.md)，常见问题见于 [doc/faq.md](doc/faq.md)，自行构建可参照构建说明 [doc/build.md](doc/build.md)。

## 多架构 CLI 镜像（含 32 位平台）

本分支为**每个架构**都构建一份纯命令行版（`cli`）镜像：`amd64`、`i386`、`arm64`、
`armhf`、`ppc64le`、`riscv64`、`s390x`。

`armel`（`linux/arm/v5`）没有出镜像：有 armel 基础镜像的 Debian tag 里没有 CLI 镜像
需要的 `danted`（SOCKS5 代理用），而有 `danted` 的 tag 里没有 armel 基础镜像。它的
模拟器仍然照常构建并提交，细节见 [doc/cli-images.md](doc/cli-images.md)。

上游的 `cli` 镜像只在 amd64 下构建。原因是 CLI 的二进制来自
[shmilee 的命令行版 deb 包](https://github.com/shmilee/scripts/releases/download/v0.0.1/easyconn_7.6.8.2-ubuntu_amd64.deb)，
**无论镜像架构是什么它们都是 amd64**（7.6.3 / 7.6.7 的 deb 只贡献 `conf`），所以在
其它架构上必须跑在 `qemu-user` 里。而发行版的 `qemu-user` 在这里行不通：

* QEMU 自 10.0 起禁止 32 位宿主模拟 64 位 guest（11.x 更是移除了 32 位宿主），
  Debian trixie 的 armhf/armel/i386 `qemu-user` 因此不再提供 `qemu-x86_64`；
* 即使在 64 位宿主上，发行版的模拟器也会把
  `getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)` 直接以 `-ENOPROTOOPT` 拒绝，
  到不了宿主内核，从而破坏 EasyConnect 的透明代理场景。

因此本分支改为用 QEMU 9.2.3 源码加一个 79 行的补丁，**为每个架构各编译一份静态
`qemu-x86_64`** 打进对应镜像（`qemu-user/qemu-x86_64-<架构>`，已随仓库提供）。补丁在
`linux-user/` 里、与目标架构无关，所以一份补丁通吃所有宿主架构。

CI 会把各架构镜像推送到 GitHub Container Registry
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
docker pull ghcr.io/forstnova-arknights/docker-easyconnect-32:cli       # 多架构 manifest
docker pull --platform linux/arm/v7 \
    ghcr.io/forstnova-arknights/docker-easyconnect-32:cli-armhf         # 指定架构
```

在 x86-64 机器上拉取非本机架构的镜像必须显式带 `--platform`，否则会报
`no matching manifest for linux/amd64`。

自己构建（以 armhf 为例）：

```bash
cd local-deps && ./fetch.sh && cd ..          # 抓取 EasyConnect 的 deb 包
docker buildx build --platform linux/arm/v7 \
    -f Dockerfile.cli -t docker-easyconnect:cli-armhf .
```

`Dockerfile.cli` 会自己从 `--platform` 推导镜像架构，不需要额外传参；amd64 下它
不安装模拟器，二进制原生运行。若要自己编译模拟器，或想换成别的宿主/目标架构组合，
见 [`qemu-user/build.sh`](qemu-user/build.sh)（`./build.sh [HOST_ARCH] [TARGET_ARCH]`）。
云端流水线见
[`.github/workflows/build-cli-images.yml`](.github/workflows/build-cli-images.yml)。

### 有些设备要用 `--privileged` 才能登录

实测**至少 x86-64 上，部分设备不加 `--privileged` 会登录失败**（能连上，但登录不成功），
加上 `--privileged` 就正常。触发条件还没摸清，也没能定位到具体是哪一步需要它——同一个
镜像在不同设备上表现不一样，所以只能先记在这里：

```bash
docker run --rm --privileged --device /dev/net/tun -ti \
    -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 \
    -e EC_VER=7.6.7 -e CLI_OPTS="-d vpnaddress -u username -p password" \
    ghcr.io/forstnova-arknights/docker-easyconnect-32:cli
```

如果你遇到「连得上但登录不上」，先按这个试。`--privileged` 会关掉容器的隔离，能用
`--cap-add` 精确放权时就不要用它；但在原因查清之前，它是最省事的排查手段。

详见 [doc/cli-images.md](doc/cli-images.md)。

## 简明使用步骤

使用下述方式登录后，可以通过 `127.0.0.1:1080`、`127.0.0.1:8888` 分别访问 [socks5 和 http 代理](doc/usage.md#代理服务)。

### 纯命令行版 EasyConnect（amd64、i386、arm64、armhf、ppc64le、riscv64、s390x 架构）

注意，纯命令行版本仅支持下列登录方式：用户名+密码、硬件特征码。

1. [安装Docker并运行](https://docs.docker.com/get-docker/)；
2.  在终端输入：
	``` bash
	docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 -e EC_VER=7.6.3 -e CLI_OPTS="-d vpnaddress -u username -p password" ghcr.io/forstnova-arknights/docker-easyconnect-32:cli
	```
	本分支的 `:cli` 有 7 个架构；**部分设备需要加 `--privileged` 才能登录成功**，见[上面](#有些设备要用---privileged-才能登录)。

	其中 `-e EC_VER=7.6.7` 表示使用 `7.6.7` 版本的 EasyConnect，请根据实际情况修改版本号（选择 `7.6.7` 或 `7.6.3`，详见 [EasyConnect 版本选择](doc/usage.md#easyconnect-版本选择)）；
3. 根据提示输入服务器地址、登录凭据。

### 图形界面版 EasyConnect（x86、amd64、arm64、mips64el 架构；镜像来自上游，本分支未构建）

1. [安装Docker并运行](https://docs.docker.com/get-docker/)；
2. 在终端输入： `docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -e PASSWORD=xxxx -e URLWIN=1 -v $HOME/.ecdata:/root -p 127.0.0.1:5901:5901 -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 hagb/docker-easyconnect:7.6.7`（末尾 EasyConnect 版本号 `7.6.7` 请根据实际情况修改；arm64 和 mips64el 架构需要加入 `-e DISABLE_PKG_VERSION_XML=1` 参数）；
3. 使用vnc客户端连接vnc， 地址：`127.0.0.1`，端口: 5901, 密码 xxxx；
4. 成功连上后你应该能看到 EasyConnect 的登录窗口，填写登录凭据并登录，若需要 web 登录可参看 [web 登录](doc/usage.md#web-登录)。

### 图形界面版 aTrust（amd64、arm64、mips64el 架构；镜像来自上游，本分支未构建）

1. [安装Docker并运行](https://docs.docker.com/get-docker/)；
2. 在终端输入： `docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -e PASSWORD=xxxx -e URLWIN=1 -v $HOME/.atrust-data:/root -p 127.0.0.1:5901:5901 -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 -p 127.0.0.1:54631:54631 --sysctl net.ipv4.conf.default.route_localnet=1 hagb/docker-atrust`；
3. 使用vnc客户端连接vnc， 地址：127.0.0.1，端口: 5901, 密码 xxxx；
4. 成功连上后你应该能看到 aTrust 的登录窗口；若需要 web 登录，在宿主机的浏览器打开 aTrust 弹出的网址网址登录即可；若需要无人值守的自动化登录和保活，请[参见此处](https://github.com/kenvix/aTrustLogin)。
5. 若必须经过 web 界面登录或 web 端需要唤起 `atrust://browserstart` 详见 [#433](https://github.com/docker-easyconnect/docker-easyconnect/issues/443)，你可以使用内置 chromium 版镜像，启动命令需加上 `-e CHROMIUM=1`，详见 [构建带有chromium的VNC镜像](doc/build.md#构建带有-chromium-的-VNC-镜像)。

## 拉取

### 本分支的镜像（GHCR）

本分支只发布纯命令行版，tag 见[上面的表格](#多架构-cli-镜像含-32-位平台)；下面的
图形界面版镜像来自上游，本分支没有构建。

### 从 Docker Hub 上直接获取：

```
docker pull hagb/docker-easyconnect:TAG
```

其中 TAG 可以是如下值（不带 VNC 服务端的 image 比带 VNC 服务端的 image 小）：

- `latest`: 默认值，带 VNC 服务端的`7.6.7`版 image，
- `cli`: 多版本（`7.6.3`, `7.6.7`, `7.6.8`）纯命令行版
- `vncless`: 不带 VNC 服务端的`7.6.7`版 image
- `7.6.3`: 带 VNC 服务端的`7.6.3`版 image
- `vncless-7.6.3`: 不带 VNC 服务端的`7.6.3`版 image
- `7.6.7`: 带 VNC 服务端的`7.6.7`版 image
- `vncless-7.6.7`: 不带 VNC 服务端的`7.6.7`版 image

## 参考资料

登录过程的一个 hack ([docker-root/usr/local/bin/start-sangfor.sh](docker-root/usr/local/bin/start-sangfor.sh))参考了这篇文章：<https://blog.51cto.com/13226459/2476193>。在此对该文作者表示感谢。

## 其他 EasyConnect 相关项目

- [@shmilee](https://github.com/shmilee) 的 [easyconnect-in-docker 方案](https://github.com/shmilee/scripts/tree/master/easyconnect-in-docker)（另见 [#35](https://github.com/Hagb/docker-easyconnect/issues/35)）实现了多 EasyConnect 版本共用容器
- [ultranity/minimal-EasyConnect](https://github.com/ultranity/minimal-EasyConnect): minimal EasyConnect CLI in docker-alpine
- [Mythologyli/ZJU-Connect](https://github.com/Mythologyli/ZJU-Connect): EasyConnect 和 aTrust 客户端的开源实现
- [zhangt2333/actions-easyconnect](https://github.com/zhangt2333/actions-easyconnect): Github Actions: run code with EasyConnect VPN
- [CoolSpring8/rwppa](https://github.com/CoolSpring8/rwppa): 将浙江大学网页版 RVPN 模拟为本地 HTTP 代理 - (ZJU) RVPN Web Portal Proxy Adapter

## 版权及许可证

> Copyright © 2020 contributors
>
> This work is free. You can redistribute it and/or modify it under the  
> terms of the Do What The Fuck You Want To Public License, Version 2,  
> as published by Sam Hocevar. See the COPYING file for more details. 
>
>        DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE  
>                    Version 2, December 2004  
>
> Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>  
>
> Everyone is permitted to copy and distribute verbatim or modified  
> copies of this license document, and changing it is allowed as long  
> as the name is changed.  
>  
>            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE  
>   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION  
>  
>  0. You just DO WHAT THE FUCK YOU WANT TO. 
