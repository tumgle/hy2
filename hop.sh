#!/bin/bash
# 落地机 Hysteria2 端口跳跃：把一段 UDP 转到本机 v2node 监听端口。
# 中转机不要用这个脚本。
#
# 客户端分享链接用 mport（连字符）。密码、服务器、sni 换成自己的:
#   hysteria2://密码@服务器:30000/?mport=30000-50000&insecure=1&sni=SNI
# 官方 hysteria 不读 mport，端口直接写 30000-50000。Clash Meta 用 ports。

set -euo pipefail

LISTEN=443
RANGE="30000:50000"
IFACE=""
ACTION="apply"
PERSIST=0

usage() {
    cat <<'EOF'
落地机端口跳跃。把客户端的 UDP 端口段转到本机 v2node 监听端口。

用法:
  sudo ./hop.sh
  sudo ./hop.sh --range 30000:50000 --listen 443
  sudo ./hop.sh --iface eth0
  sudo ./hop.sh --delete
  sudo ./hop.sh --persist

选项:
  --range START:END   跳跃端口，默认 30000:50000（冒号）
  --listen PORT       v2node 监听端口，默认 443
  --iface NAME        网卡，默认取默认路由的网卡
  --delete            删除本脚本添加的规则
  --persist           开机自动重新应用（systemd）
  -h, --help          显示帮助

面板「连接端口」用连字符，例如 30000-50000。这里用冒号。
服务端口不要落在跳跃范围里。

客户端:
  hysteria2://密码@服务器:30000/?mport=30000-50000&insecure=1&sni=SNI
官方 hysteria 把范围写在端口上。Clash Meta 用 ports，不用 mport。
EOF
}

die() {
    echo "错误: $*" >&2
    exit 1
}

need_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --range)
                RANGE="${2:-}"
                shift 2
                ;;
            --listen)
                LISTEN="${2:-}"
                shift 2
                ;;
            --iface)
                IFACE="${2:-}"
                shift 2
                ;;
            --delete)
                ACTION="delete"
                shift
                ;;
            --persist)
                PERSIST=1
                shift
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

validate_port() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || die "端口无效: $n"
    (( n >= 1 && n <= 65535 )) || die "端口超出范围: $n"
}

validate() {
    [[ "$RANGE" =~ ^([0-9]+):([0-9]+)$ ]] || die "范围要用冒号，例如 30000:50000"
    START="${BASH_REMATCH[1]}"
    END="${BASH_REMATCH[2]}"
    validate_port "$START"
    validate_port "$END"
    validate_port "$LISTEN"
    (( START < END )) || die "起始端口必须小于结束端口"
    if (( LISTEN >= START && LISTEN <= END )); then
        die "服务端口 $LISTEN 不能落在跳跃范围 $RANGE 内"
    fi
    if [[ -z "$IFACE" ]]; then
        IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    fi
    [[ -n "$IFACE" ]] || die "没有找到默认网卡，请用 --iface 指定"
    ip link show "$IFACE" &>/dev/null || die "网卡不存在: $IFACE"
}

nft_range() {
    echo "${START}-${END}"
}

rule_exists_iptables() {
    iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination ":$LISTEN" &>/dev/null
}

delete_iptables() {
    local removed=0
    while rule_exists_iptables; do
        iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination ":$LISTEN"
        removed=1
    done
    if [[ "$removed" -eq 1 ]]; then
        echo "已删除 iptables 规则: $IFACE UDP $RANGE -> :$LISTEN"
    else
        echo "没有匹配的 iptables 规则"
    fi
}

apply_iptables() {
    delete_iptables >/dev/null
    if command -v nft &>/dev/null && nft list table inet hysteria_porthop &>/dev/null; then
        nft delete table inet hysteria_porthop
        echo "已去掉旧的 nft 表 hysteria_porthop，避免两套规则叠在一起"
    fi
    iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination ":$LISTEN"
    echo "已添加 iptables 规则: $IFACE UDP $RANGE -> 本机 $LISTEN"
    echo
    iptables -t nat -L PREROUTING -n -v --line-numbers
}

delete_nft() {
    if command -v nft &>/dev/null && nft list table inet hysteria_porthop &>/dev/null; then
        nft delete table inet hysteria_porthop
        echo "已删除 nft 表 hysteria_porthop"
    else
        echo "没有 nft 表 hysteria_porthop"
    fi
}

apply_nft() {
    command -v nft &>/dev/null || die "没有 iptables，也没有 nft"
    delete_nft >/dev/null
    if command -v iptables &>/dev/null; then
        delete_iptables >/dev/null
    fi
    nft -f - <<EOF
table inet hysteria_porthop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$IFACE" udp dport $(nft_range) counter redirect to :$LISTEN
  }
}
EOF
    echo "已添加 nft 规则: $IFACE UDP $(nft_range) -> 本机 $LISTEN"
    echo
    nft list table inet hysteria_porthop
}

backend() {
    if command -v iptables &>/dev/null; then
        echo iptables
    elif command -v nft &>/dev/null; then
        echo nft
    else
        die "没有 iptables 或 nft。Debian/Ubuntu 可安装: apt-get install -y iptables"
    fi
}

# 一键 curl 会把脚本放在临时目录。开机服务改用固定副本，避免重启后文件消失。
persist_bin() {
    local bin name dest
    bin=$(readlink -f "$0")
    name=$(basename "$bin")
    case "$bin" in
        /tmp/*|/var/tmp/*|/dev/fd/*|/proc/self/fd/*) ;;
        *)
            if [[ -z "${TMPDIR:-}" || "$bin" != "${TMPDIR%/}"/* ]]; then
                printf '%s' "$bin"
                return
            fi
            ;;
    esac
    dest="/usr/local/lib/hy2/$name"
    mkdir -p /usr/local/lib/hy2
    cp -f "$bin" "$dest"
    chmod 755 "$dest"
    printf '%s' "$dest"
}

persist_unit() {
    local bin unit
    bin=$(persist_bin)
    unit=/etc/systemd/system/hysteria-hop.service
    cat > "$unit" <<EOF
[Unit]
Description=Hysteria2 landing port hop
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$bin --iface $IFACE --listen $LISTEN --range $RANGE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-hop.service
    echo "已启用开机服务 hysteria-hop.service"
}

unpersist_unit() {
    if systemctl list-unit-files hysteria-hop.service &>/dev/null; then
        systemctl disable --now hysteria-hop.service &>/dev/null || true
        rm -f /etc/systemd/system/hysteria-hop.service
        systemctl daemon-reload
        echo "已关闭开机服务 hysteria-hop.service"
    fi
}

main() {
    parse_args "$@"
    validate
    need_root
    local kind
    kind=$(backend)
    echo "落地机端口跳跃"
    echo "  网卡: $IFACE"
    echo "  跳跃: UDP $RANGE"
    echo "  转到本机: $LISTEN"
    echo "  方式: $kind"
    echo
    if [[ "$ACTION" == "delete" ]]; then
        if [[ "$kind" == "iptables" ]]; then
            delete_iptables
        fi
        delete_nft
        unpersist_unit
        exit 0
    fi
    echo "客户端分享链接（密码、服务器、sni 自填）:"
    echo "  hysteria2://密码@服务器:${START}/?mport=${START}-${END}&insecure=1&sni=SNI"
    echo "官方 hysteria 端口写 ${START}-${END}。Clash Meta 用 ports: ${START}-${END}。"
    echo
    if [[ "$kind" == "iptables" ]]; then
        apply_iptables
    else
        apply_nft
    fi
    if [[ "$PERSIST" -eq 1 ]]; then
        persist_unit
    else
        echo
        echo "规则在本次开机有效。要开机自动加载，再执行: $0 --persist --iface $IFACE --listen $LISTEN --range $RANGE"
    fi
}

main "$@"
