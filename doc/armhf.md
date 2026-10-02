# 32 位（armhf / `linux/arm/v7`）平台构建说明

本仓库是 [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect)
的一个分支，增加了在 **32 位 ARM（armhf）** 上构建纯命令行版镜像的能力。

上游的 `Dockerfile.cli` 依赖发行版的 `qemu-user` 包在 armhf 上模拟 amd64 的
EasyConnect 二进制，这条路现在已经走不通了（原因见下）。本分支改为**自行交叉
编译一个打过补丁的 `qemu-x86_64`**，并把它打进镜像。

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
[`qemu-armhf/qemu-9.2.3-so_original_dst.patch`](../qemu-armhf/qemu-9.2.3-so_original_dst.patch)。

> 已知未处理的缺口：`do_setsockopt()` 有同样风格的白名单，不认识
> `IP_TRANSPARENT`(19)，guest 无法**设置**该选项。EasyConnect 需要的是
> `getsockopt` 方向，故未改动。

## 使用

镜像可以直接构建：

```bash
# 1. 先抓取 EasyConnect 的 deb 包（体积大，故不进 git）
cd local-deps && ./fetch.sh && cd ..

# 2. 构建 armhf 镜像
docker buildx build --platform linux/arm/v7 \
    -f Dockerfile.cli-armhf -t docker-easyconnect:cli-armhf .
```

运行方式与上游 `cli` 镜像完全一致：

```bash
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti \
    -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 \
    -e EC_VER=7.6.3 -e CLI_OPTS="-d vpnaddress -u username -p password" \
    docker-easyconnect:cli-armhf
```

仓库中已经附带了编译好的静态 armhf 二进制
[`qemu-armhf/qemu-x86_64`](../qemu-armhf/qemu-x86_64)（2.8 MB），所以上一步的
第 2 条命令可以直接使用，无需自己编译 QEMU。

## 自行编译 QEMU

```bash
./qemu-armhf/build.sh          # 在 x86-64 的 Debian/Ubuntu 上运行
```

脚本会装依赖、下载 QEMU 9.2.3、打补丁、交叉编译并 strip，最终产出
`qemu-armhf/qemu-x86_64`。细节（依赖列表、configure 参数、注意事项）见
[`qemu-armhf/README.md`](../qemu-armhf/README.md)。

## 验证

`qemu-armhf/test/run_verify.sh` 会在**各自独立的 network namespace** 中跑四个
用例（不会改动宿主机网络）：先加一条
`iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 -j REDIRECT --to-ports 18080`，
再让测试程序连接 `127.0.0.1:18081`（被重定向到它自己的 `:18080` 监听），最后打印
`SO_ORIGINAL_DST` 报告出来的地址——正确时应为**重定向前的 18081**。

| # | 运行方式 | `SO_ORIGINAL_DST` | 结果 |
|---|---|---|---|
| 1 | 原生 x86_64（基准） | `127.0.0.1:18081` | PASS |
| 2 | 打过补丁的 `qemu-x86_64`（x86-64 宿主） | `127.0.0.1:18081` | PASS |
| 3 | **本仓库的 armhf `qemu-x86_64`**，外层用打过补丁的 `qemu-arm` | `127.0.0.1:18081` | PASS |
| 4 | 本仓库的 armhf `qemu-x86_64`，外层用发行版未打补丁的 `qemu-arm`（对照） | `errno=92` ENOPROTOOPT | FAIL |

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
