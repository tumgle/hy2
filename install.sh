#!/bin/bash
# 一键：本机端口跳跃，或中转到落地机，并开机加载。
# 不安装 v2node / hysteria 程序。v2node 需要已经在听 UDP 443。
# 密码只用来打印分享链接，不写入规则或开机服务。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/hy2/main/install.sh)
#   sudo ./install.sh
#   sudo ./install.sh --server example.com --password '密码' --sni bing.com
#   sudo ./install.sh --landing 203.0.113.10 --server relay.example.com --password '密码'

set -euo pipefail

RAW_BASE=https://raw.githubusercontent.com/tumgle/hy2/main
HOP=""
RELAY=""
WORK=""

LISTEN=443
START=30000
END=50000
RANGE="${START}:${END}"
SNI_DEFAULT=bing.com

LANDING=""
LANDING_SET=0
SERVER=""
PASSWORD=""
SNI=""

usage() {
    cat <<EOF
一键设置 Hysteria2 端口跳跃。端口固定为 UDP ${START}:${END} -> ${LISTEN}，并开机加载。

用法:
  bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/hy2/main/install.sh)
  sudo ./install.sh
  sudo ./install.sh --server example.com --password '密码' --sni bing.com
  sudo ./install.sh --landing 203.0.113.10 --server relay.example.com --password '密码'

选项:
  --landing IP    落地机公网 IP。留空则只做本机跳跃
  --server HOST   客户端要连的域名。中转时填中转域名
  --password TEXT 分享链接里的密码，不会写进文件
  --sni NAME      TLS SNI，默认 ${SNI_DEFAULT}
  -h, --help      显示帮助

示例落地 IP 是文档地址 203.0.113.10，请换成自己的。
EOF
}

die() {
    echo "错误: $*" >&2
    exit 1
}

run_root() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || die "需要 root。请用 root 打开终端后再执行"
        sudo "$@"
    fi
}

cleanup() {
    if [[ -n "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

sibling_helpers() {
    local src dir
    src=${BASH_SOURCE[0]}
    dir=$(dirname "$src")
    [[ -f "$dir/hop.sh" && -f "$dir/relay.sh" ]] || return 1
    dir=$(cd "$dir" && pwd)
    HOP="$dir/hop.sh"
    RELAY="$dir/relay.sh"
}

fetch_helpers() {
    command -v curl >/dev/null 2>&1 || die "需要 curl 才能下载 hop.sh 和 relay.sh"
    WORK=$(mktemp -d)
    echo "旁边没有 hop.sh / relay.sh，下载到临时目录"
    curl -fsSL "${RAW_BASE}/hop.sh" -o "$WORK/hop.sh"
    curl -fsSL "${RAW_BASE}/relay.sh" -o "$WORK/relay.sh"
    [[ -s "$WORK/hop.sh" && -s "$WORK/relay.sh" ]] || die "下载 hop.sh 或 relay.sh 失败"
    chmod 755 "$WORK/hop.sh" "$WORK/relay.sh"
    HOP="$WORK/hop.sh"
    RELAY="$WORK/relay.sh"
}

locate_helpers() {
    if sibling_helpers; then
        return
    fi
    fetch_helpers
}

need_value() {
    [[ $# -ge 2 ]] || die "$1 需要一个值"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --landing)
                need_value "$@"
                LANDING="$2"
                LANDING_SET=1
                shift 2
                ;;
            --server)
                need_value "$@"
                SERVER="$2"
                shift 2
                ;;
            --password)
                need_value "$@"
                PASSWORD="$2"
                shift 2
                ;;
            --sni)
                need_value "$@"
                SNI="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1（用 --help 查看）"
                ;;
        esac
    done
}

prompt_landing() {
    [[ "$LANDING_SET" -eq 1 ]] && return
    if [[ ! -t 0 ]]; then
        LANDING=""
        return
    fi
    read -r -p "落地公网 IP（本机跳跃直接回车）: " LANDING
}

prompt_sni() {
    if [[ -n "$SNI" ]]; then
        return
    fi
    if [[ ! -t 0 ]]; then
        SNI="$SNI_DEFAULT"
        return
    fi
    prompt_required SNI "SNI" "" "$SNI_DEFAULT"
}

prompt_required() {
    local __var="$1" __prompt="$2" __secret="${3:-}" __default="${4:-}"
    local current reply
    current="${!__var}"
    [[ -n "$current" ]] && return
    if [[ ! -t 0 ]]; then
        die "缺少${__prompt}。请在终端运行，或传入对应参数"
    fi
    if [[ -n "$__secret" ]]; then
        read -r -s -p "${__prompt}: " reply
        echo
    elif [[ -n "$__default" ]]; then
        read -r -p "${__prompt} [${__default}]: " reply
        reply="${reply:-$__default}"
    else
        read -r -p "${__prompt}: " reply
    fi
    printf -v "$__var" '%s' "$reply"
}

validate_port_range() {
    (( START < END )) || die "跳跃范围无效"
    if (( LISTEN >= START && LISTEN <= END )); then
        die "服务端口 $LISTEN 不能落在跳跃范围 ${START}:${END} 内"
    fi
}

validate_ip() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || die "落地 IP 无效: $ip"
    for o in "${BASH_REMATCH[@]:1}"; do
        (( o <= 255 )) || die "落地 IP 无效: $ip"
    done
}

validate() {
    validate_port_range
    if [[ -n "$LANDING" ]]; then
        validate_ip "$LANDING"
    fi
    [[ -n "$SERVER" ]] || die "缺少服务器域名"
    [[ "$SERVER" != *@* && "$SERVER" != */* && "$SERVER" != *:* && "$SERVER" != *" "* ]] || die "服务器只填域名或 IP，不要带端口、账号或协议"
    [[ -n "$PASSWORD" ]] || die "缺少密码"
    if [[ -z "$SNI" ]]; then
        SNI="$SNI_DEFAULT"
    fi
}

root_has() {
    run_root bash -c 'command -v "$1" >/dev/null 2>&1' bash "$1"
}

ensure_iptables() {
    root_has iptables && return
    command -v apt-get >/dev/null 2>&1 || die "中转需要 iptables。Debian/Ubuntu: apt-get install -y iptables"
    echo "未找到 iptables，将安装"
    run_root apt-get update
    run_root apt-get install -y iptables
}

ensure_firewall() {
    if root_has iptables || root_has nft; then
        return
    fi
    command -v apt-get >/dev/null 2>&1 || die "没有 iptables 或 nft。Debian/Ubuntu: apt-get install -y iptables"
    echo "未找到 iptables 或 nft，将安装 iptables"
    run_root apt-get update
    run_root apt-get install -y iptables
}

relay_landing_from_unit() {
    local unit=/etc/systemd/system/hysteria-relay.service line
    [[ -f "$unit" ]] || return 0
    line=$(sed -n 's/.*--landing[[:space:]]\([^[:space:]]*\).*/\1/p' "$unit" | head -n 1)
    printf '%s' "$line"
}

apply_local() {
    local old
    old=$(relay_landing_from_unit)
    if [[ -n "$old" ]]; then
        echo "去掉已有中转: $old"
        ensure_iptables
        run_root bash "$RELAY" --landing "$old" --listen "$LISTEN" --range "$RANGE" --delete
    fi
    ensure_firewall
    echo "应用本机端口跳跃并开机加载"
    run_root bash "$HOP" --listen "$LISTEN" --range "$RANGE" --persist
}

apply_relay() {
    local old
    ensure_iptables
    old=$(relay_landing_from_unit)
    if [[ -n "$old" && "$old" != "$LANDING" ]]; then
        echo "去掉旧的落地: $old"
        run_root bash "$RELAY" --landing "$old" --listen "$LISTEN" --range "$RANGE" --delete
    fi
    run_root bash "$HOP" --listen "$LISTEN" --range "$RANGE" --delete
    echo "应用中转并开机加载"
    run_root bash "$RELAY" --landing "$LANDING" --listen "$LISTEN" --range "$RANGE" --persist
}

urlencode() {
    local LC_ALL=C s="$1" i byte out=""
    for ((i = 0; i < ${#s}; i++)); do
        byte=${s:i:1}
        case "$byte" in
            [a-zA-Z0-9._~-]) out+="$byte" ;;
            *) printf -v out '%s%%%02X' "$out" "'$byte" ;;
        esac
    done
    printf '%s' "$out"
}

print_link() {
    local auth host sni
    auth=$(urlencode "$PASSWORD")
    host=$(urlencode "$SERVER")
    sni=$(urlencode "$SNI")
    echo
    echo "客户端分享链接:"
    echo "  hysteria2://${auth}@${host}:${START}/?mport=${START}-${END}&insecure=1&sni=${sni}"
    echo "密码没有写入防火墙规则或开机服务。"
    echo "官方 hysteria 不读 mport，端口写成 ${START}-${END}。Clash Meta 用 ports: ${START}-${END}。"
}

main() {
    parse_args "$@"
    prompt_landing
    prompt_required SERVER "服务器域名（中转时填中转域名）"
    prompt_required PASSWORD "密码" secret
    prompt_sni
    validate
    locate_helpers
    [[ -f "$HOP" && -f "$RELAY" ]] || die "缺少 hop.sh 或 relay.sh"
    echo
    echo "将要设置"
    echo "  跳跃: UDP ${RANGE}"
    echo "  服务端口: ${LISTEN}"
    echo "  服务器: ${SERVER}"
    echo "  SNI: ${SNI}"
    if [[ -n "$LANDING" ]]; then
        echo "  模式: 中转 -> ${LANDING}:${LISTEN}"
    else
        echo "  模式: 本机跳跃 -> ${LISTEN}"
    fi
    echo
    if [[ -n "$LANDING" ]]; then
        apply_relay
    else
        apply_local
    fi
    print_link
}

main "$@"
