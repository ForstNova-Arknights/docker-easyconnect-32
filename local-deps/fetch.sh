#!/bin/sh
#
# Fetch the EasyConnect deb packages that Dockerfile.cli-armhf needs.
# They are Sangfor's property and are deliberately not kept in this repository.
#
#   ./fetch.sh
#
set -eu
cd "$(dirname "$0")"

# The upstream URL is
#   https://github.com/shmilee/scripts/releases/download/v0.0.1/easyconn_7.6.8.2-ubuntu_amd64.deb
# The gh-proxy.com prefix is only a mirror for networks where github.com is slow.
# Set GH_PROXY to the empty string to download straight from github.com
# (no colon in the expansion, so an empty value really means "no proxy").
GH_PROXY=${GH_PROXY-https://gh-proxy.com/}

fetch() {
    url=$1
    out=$2
    if [ -s "$out" ]; then
        echo "already have $out"
        return 0
    fi
    echo "fetching $out"
    curl -fSL --retry 3 -o "$out" "$url"
}

fetch "${GH_PROXY}https://github.com/shmilee/scripts/releases/download/v0.0.1/easyconn_7.6.8.2-ubuntu_amd64.deb" \
      easyconn_7.6.8.2-ubuntu_amd64.deb
fetch "http://download.sangfor.com.cn/download/product/sslvpn/pkg/linux_01/EasyConnect_x64.deb" \
      EasyConnect_x64.deb
fetch "http://download.sangfor.com.cn/download/product/sslvpn/pkg/linux_767/EasyConnect_x64_7_6_7_3.deb" \
      EasyConnect_x64_7_6_7_3.deb

ls -l
