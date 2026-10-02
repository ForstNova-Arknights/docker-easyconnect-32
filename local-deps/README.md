# local-deps

`Dockerfile.cli-armhf` takes the EasyConnect packages from this directory so the
(emulated, therefore slow) image build does not depend on flaky downloads.

The packages are **not** part of this repository — they are Sangfor's property
and each one is tens of megabytes.  Fetch them once on the build host:

```sh
./fetch.sh
```

| file | where it comes from |
|---|---|
| `easyconn_7.6.8.2-ubuntu_amd64.deb` | [shmilee/scripts](https://github.com/shmilee/scripts/releases/download/v0.0.1/easyconn_7.6.8.2-ubuntu_amd64.deb) — the command line client used by the upstream `cli` image |
| `EasyConnect_x64.deb` | `download.sangfor.com.cn` — provides `conf_7.6.3` |
| `EasyConnect_x64_7_6_7_3.deb` | `download.sangfor.com.cn` — provides `conf_7.6.7` |
