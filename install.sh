#!/bin/bash
# 一键打开菜单：本机端口跳跃，或中转机转发。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/hy2/main/install.sh)

set -euo pipefail

RAW_BASE=https://raw.githubusercontent.com/tumgle/hy2/main
DEST=/usr/local/lib/hy2

die() {
    echo "错误: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
打开 Hysteria2 端口菜单。

  bash <(curl -fsSL ${RAW_BASE}/install.sh)

1) 本机 Hysteria2 设置
2) 中转机 Hysteria2 设置
3) 检测网卡

菜单里可以改端口、选网卡、查看规则、删除规则、开机加载。
脚本安装到 ${DEST}。
EOF
}

# bash <(curl) 的脚本在 /dev/fd 上，sudo 读不到。先复制成普通文件再提权。
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    [[ -z "${HY2_REEXEC:-}" ]] || die "需要 root"
    command -v sudo >/dev/null 2>&1 || die "需要 root。请用 root 打开终端后再执行"
    tmp=$(mktemp)
    src=${BASH_SOURCE[0]}
    origin=""
    # /dev/fd 只能读一次，bash 已经把它当脚本读完，再复制会得到空文件。
    if [[ "$src" != /dev/fd/* && "$src" != /proc/self/fd/* && -f "$src" ]]; then
        cp -f "$src" "$tmp"
        origin=$(cd "$(dirname "$src")" && pwd)
    else
        command -v curl >/dev/null 2>&1 || die "需要 curl"
        curl -fsSL "${RAW_BASE}/install.sh" -o "$tmp"
    fi
    chmod 755 "$tmp"
    exec sudo env HY2_REEXEC=1 HY2_ORIGIN="$origin" bash "$tmp" "$@"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -gt 0 ]]; then
    die "这个命令只打开菜单。端口和落地 IP 在菜单里设置。未知参数: $1"
fi

mkdir -p "$DEST"
src=${HY2_ORIGIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
if [[ -f "$src/hop.sh" && -f "$src/relay.sh" && -f "$src/hy2.sh" ]]; then
    cp -f "$src/hop.sh" "$src/relay.sh" "$src/hy2.sh" "$DEST/"
else
    command -v curl >/dev/null 2>&1 || die "需要 curl 才能下载脚本"
    for name in hop.sh relay.sh hy2.sh; do
        echo "下载 ${name}"
        curl -fsSL "${RAW_BASE}/${name}" -o "$DEST/$name"
    done
fi
chmod 755 "$DEST/hop.sh" "$DEST/relay.sh" "$DEST/hy2.sh"
[[ -s "$DEST/hop.sh" && -s "$DEST/relay.sh" && -s "$DEST/hy2.sh" ]] || die "缺少 hop.sh、relay.sh 或 hy2.sh"

echo "打开菜单。脚本目录: $DEST"
exec bash "$DEST/hy2.sh"
