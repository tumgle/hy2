#!/bin/bash
# 中转机转发：把一段 UDP 转到落地机的服务端口。
# 不要把流量转到中转机自己的 :443。
#
# 客户端连中转域名，不是落地 IP。mport 用连字符:
#   hysteria2://密码@中转域名:30000/?mport=30000-50000&insecure=1&sni=SNI

set -euo pipefail

LISTEN=443
RANGE="30000:50000"
IFACE=""
LANDING=""
ACTION="apply"
PERSIST=0

usage() {
    cat <<'EOF'
中转机转发。把客户端的 UDP 端口段转到落地机公网 IP 的服务端口。

用法:
  sudo ./relay.sh --landing 203.0.113.10
  sudo ./relay.sh --landing 203.0.113.10 --range 30000:50000 --listen 443
  sudo ./relay.sh --landing 203.0.113.10 --delete

选项:
  --landing IP        落地机公网 IP，必填
  --range START:END   客户端跳跃端口，默认 30000:50000（冒号）
  --listen PORT       落地机 v2node 端口，默认 443
  --iface NAME        网卡，默认取默认路由的网卡
  --delete            删除转到该落地机的规则，并删掉同范围的本机 to::443
  --persist           开机自动重新应用（systemd），并打开 ip_forward
  -h, --help          显示帮助

落地机公网 IP 在落地机上执行: curl -4 -s ifconfig.me
面板「连接端口」用连字符，例如 30000-50000。这里用冒号。

客户端连中转域名:
  hysteria2://密码@中转域名:30000/?mport=30000-50000&insecure=1&sni=SNI
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
            --landing)
                LANDING="${2:-}"
                shift 2
                ;;
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

validate_ip() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || die "落地 IP 无效: $ip"
    for o in "${BASH_REMATCH[@]:1}"; do
        (( o <= 255 )) || die "落地 IP 无效: $ip"
    done
}

validate() {
    [[ -n "$LANDING" ]] || die "缺少 --landing。例: --landing 203.0.113.10"
    validate_ip "$LANDING"
    [[ "$RANGE" =~ ^([0-9]+):([0-9]+)$ ]] || die "范围要用冒号，例如 30000:50000"
    START="${BASH_REMATCH[1]}"
    END="${BASH_REMATCH[2]}"
    validate_port "$START"
    validate_port "$END"
    validate_port "$LISTEN"
    (( START < END )) || die "起始端口必须小于结束端口"
    if (( LISTEN >= START && LISTEN <= END )); then
        die "落地端口 $LISTEN 落在转发范围 $RANGE 内，会把这段里的 $LISTEN 也转走"
    fi
    if [[ -z "$IFACE" ]]; then
        IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    fi
    [[ -n "$IFACE" ]] || die "没有找到默认网卡，请用 --iface 指定"
    ip link show "$IFACE" &>/dev/null || die "网卡不存在: $IFACE"
    command -v iptables &>/dev/null || die "没有 iptables。Debian/Ubuntu 可安装: apt-get install -y iptables"
}

delete_matching() {
    local table=$1 chain=$2
    shift 2
    local removed=0
    while iptables -t "$table" -C "$chain" "$@" &>/dev/null; do
        iptables -t "$table" -D "$chain" "$@"
        removed=1
    done
    echo "$removed"
}

delete_rules() {
    local n
    n=$(delete_matching nat PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination "$LANDING:$LISTEN")
    if [[ "$n" -eq 1 ]]; then echo "已删除: $RANGE -> $LANDING:$LISTEN"; fi
    n=$(delete_matching nat PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination ":$LISTEN")
    if [[ "$n" -eq 1 ]]; then echo "已删除本机规则: $RANGE -> :$LISTEN"; fi
    n=$(delete_matching nat POSTROUTING -p udp -d "$LANDING" --dport "$LISTEN" -j MASQUERADE)
    if [[ "$n" -eq 1 ]]; then echo "已删除 MASQUERADE: $LANDING:$LISTEN"; fi
    n=$(delete_matching filter FORWARD -p udp -d "$LANDING" --dport "$LISTEN" -j ACCEPT)
    if [[ "$n" -eq 1 ]]; then echo "已删除 FORWARD: $LANDING:$LISTEN"; fi
    return 0
}

apply_rules() {
    delete_rules >/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "$RANGE" -j DNAT --to-destination "$LANDING:$LISTEN"
    iptables -t nat -A POSTROUTING -p udp -d "$LANDING" --dport "$LISTEN" -j MASQUERADE
    iptables -I FORWARD 1 -p udp -d "$LANDING" --dport "$LISTEN" -j ACCEPT
    echo "已转发: $IFACE UDP $RANGE -> $LANDING:$LISTEN"
    echo
    iptables -t nat -L PREROUTING -n -v --line-numbers
    echo
    echo "确认目标是 $LANDING:$LISTEN，不是 to::$LISTEN"
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
    unit=/etc/systemd/system/hysteria-relay.service
    mkdir -p /etc/sysctl.d
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-hysteria-relay.conf
    cat > "$unit" <<EOF
[Unit]
Description=Hysteria2 relay forward
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$bin --landing $LANDING --iface $IFACE --listen $LISTEN --range $RANGE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-relay.service
    echo "已启用开机服务 hysteria-relay.service"
}

unpersist_unit() {
    if systemctl list-unit-files hysteria-relay.service &>/dev/null; then
        systemctl disable --now hysteria-relay.service &>/dev/null || true
        rm -f /etc/systemd/system/hysteria-relay.service
        systemctl daemon-reload
        echo "已关闭开机服务 hysteria-relay.service"
    fi
}

main() {
    parse_args "$@"
    validate
    need_root
    echo "中转机转发"
    echo "  网卡: $IFACE"
    echo "  跳跃: UDP $RANGE"
    echo "  落地: $LANDING:$LISTEN"
    echo
    if [[ "$ACTION" == "delete" ]]; then
        delete_rules
        unpersist_unit
        echo
        iptables -t nat -L PREROUTING -n -v --line-numbers
        exit 0
    fi
    echo "客户端连中转域名，不连落地 IP。密码和 sni 自填:"
    echo "  hysteria2://密码@中转域名:${START}/?mport=${START}-${END}&insecure=1&sni=SNI"
    echo "官方 hysteria 端口写 ${START}-${END}。Clash Meta 用 ports: ${START}-${END}。"
    echo
    apply_rules
    if [[ "$PERSIST" -eq 1 ]]; then
        persist_unit
    else
        echo
        echo "规则在本次开机有效。要开机自动加载，再执行:"
        echo "  $0 --persist --landing $LANDING --iface $IFACE --listen $LISTEN --range $RANGE"
    fi
}

main "$@"
