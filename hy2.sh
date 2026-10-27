#!/bin/bash
# Hysteria2 端口工具：本机跳跃，或中转机转发。

DIR=$(cd "$(dirname "$0")" && pwd)
HOP="$DIR/hop.sh"
RELAY="$DIR/relay.sh"

IFACE=""
PORT_START=30000
PORT_END=50000
LISTEN=443
LANDING=""

die() {
    echo "错误: $*" >&2
    exit 1
}

pause() {
    read -r -p "按回车继续..." _
}

detect_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

list_ifaces() {
    echo "网卡:"
    ip -br link | awk '{print "  " $1 "  " $2}'
    local def
    def=$(detect_iface)
    if [[ -n "$def" ]]; then
        echo "默认路由网卡: $def"
    else
        echo "没有找到默认路由网卡"
    fi
}

ensure_iface() {
    if [[ -z "$IFACE" ]]; then
        IFACE=$(detect_iface)
    fi
}

range_spec() {
    echo "${PORT_START}:${PORT_END}"
}

prompt_value() {
    local __var="$1" __prompt="$2" __default="$3" __reply
    read -r -p "$__prompt [$__default]: " __reply
    if [[ -n "$__reply" ]]; then
        printf -v "$__var" '%s' "$__reply"
    else
        printf -v "$__var" '%s' "$__default"
    fi
}

split_range() {
    local raw="$1"
    raw=${raw//-/:}
    if [[ "$raw" == *:* ]]; then
        PORT_START=${raw%%:*}
        PORT_END=${raw##*:}
    fi
}

configure_ports() {
    echo
    echo "单独配置端口。直接回车保持当前值。"
    echo "跳跃范围也可以一次输入 30000:50000 或 30000-50000。"
    local start end listen
    prompt_value start "跳跃起始端口" "$PORT_START"
    if [[ "$start" == *:* || "$start" == *-* ]]; then
        split_range "$start"
    else
        PORT_START=$start
        prompt_value end "跳跃结束端口" "$PORT_END"
        PORT_END=$end
    fi
    prompt_value listen "服务端口（v2node 监听）" "$LISTEN"
    LISTEN=$listen
    echo "当前端口: 跳跃 ${PORT_START}:${PORT_END}  服务端口 $LISTEN"
}

choose_iface() {
    echo
    list_ifaces
    ensure_iface
    local name
    prompt_value name "使用网卡" "$IFACE"
    if ! ip link show "$name" &>/dev/null; then
        echo "网卡不存在: $name"
        return 1
    fi
    IFACE=$name
    echo "已选择网卡: $IFACE"
}

show_rules() {
    echo
    if command -v iptables &>/dev/null; then
        echo "---- iptables PREROUTING ----"
        iptables -t nat -L PREROUTING -n -v --line-numbers
        echo
        echo "---- iptables POSTROUTING ----"
        iptables -t nat -L POSTROUTING -n -v --line-numbers
    else
        echo "未安装 iptables"
    fi
    if command -v nft &>/dev/null && nft list table inet hysteria_porthop &>/dev/null; then
        echo
        echo "---- nft hysteria_porthop ----"
        nft list table inet hysteria_porthop
    fi
    if command -v ss &>/dev/null; then
        echo
        echo "---- v2node UDP ----"
        ss -ulnp | grep v2node || echo "没有看到 v2node 的 UDP 监听"
    fi
}

run_hop() {
    bash "$HOP" --iface "$IFACE" --listen "$LISTEN" --range "$(range_spec)" "$@"
}

run_relay() {
    [[ -n "$LANDING" ]] || die "还没有落地 IP"
    bash "$RELAY" --landing "$LANDING" --iface "$IFACE" --listen "$LISTEN" --range "$(range_spec)" "$@"
}

confirm() {
    local reply
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

local_menu() {
    while true; do
        ensure_iface
        echo
        echo "======== 本机 Hysteria2 ========"
        echo "网卡: ${IFACE:-未选择}"
        echo "跳跃: ${PORT_START}:${PORT_END}"
        echo "服务端口: $LISTEN"
        echo "1) 应用规则"
        echo "2) 配置端口"
        echo "3) 检测并选择网卡"
        echo "4) 查看规则"
        echo "5) 删除规则"
        echo "6) 开机自动加载"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                choose_iface || { pause; continue; }
                echo "将把 UDP ${PORT_START}:${PORT_END} 转到本机 $LISTEN（网卡 $IFACE）"
                confirm "确认应用?" || continue
                run_hop || true
                pause
                ;;
            2)
                configure_ports
                pause
                ;;
            3)
                choose_iface || true
                pause
                ;;
            4)
                show_rules
                pause
                ;;
            5)
                confirm "删除本机 ${PORT_START}:${PORT_END} -> $LISTEN 的规则?" || continue
                run_hop --delete || true
                pause
                ;;
            6)
                confirm "开机自动应用当前本机规则?" || continue
                run_hop --persist || true
                pause
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项"
                ;;
        esac
    done
}

configure_landing() {
    local ip
    prompt_value ip "落地机公网 IP" "${LANDING:-}"
    LANDING=$ip
    echo "落地 IP: $LANDING"
}

relay_menu() {
    while true; do
        ensure_iface
        echo
        echo "======== 中转机 Hysteria2 ========"
        echo "网卡: ${IFACE:-未选择}"
        echo "跳跃: ${PORT_START}:${PORT_END}"
        echo "落地: ${LANDING:-未设置}:$LISTEN"
        echo "1) 应用转发"
        echo "2) 配置端口"
        echo "3) 配置落地 IP"
        echo "4) 检测并选择网卡"
        echo "5) 查看规则"
        echo "6) 删除规则"
        echo "7) 开机自动加载"
        echo "0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                [[ -n "$LANDING" ]] || configure_landing
                choose_iface || { pause; continue; }
                echo "将把 UDP ${PORT_START}:${PORT_END} 转到 $LANDING:$LISTEN（网卡 $IFACE）"
                confirm "确认应用?" || continue
                run_relay || true
                pause
                ;;
            2)
                configure_ports
                pause
                ;;
            3)
                configure_landing
                pause
                ;;
            4)
                choose_iface || true
                pause
                ;;
            5)
                show_rules
                pause
                ;;
            6)
                [[ -n "$LANDING" ]] || configure_landing
                confirm "删除转到 $LANDING:$LISTEN 的规则，以及同范围的本机 to::$LISTEN ?" || continue
                run_relay --delete || true
                pause
                ;;
            7)
                [[ -n "$LANDING" ]] || configure_landing
                confirm "开机自动应用当前中转规则?" || continue
                run_relay --persist || true
                pause
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项"
                ;;
        esac
    done
}

main_menu() {
    [[ -x "$HOP" && -x "$RELAY" ]] || die "缺少 hop.sh 或 relay.sh"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "请用 root 运行: sudo $0"
    fi
    while true; do
        ensure_iface
        echo
        echo "======== Hysteria2 端口 ========"
        echo "检测到的网卡: ${IFACE:-无}"
        echo "1) 本机 Hysteria2 设置"
        echo "2) 中转机 Hysteria2 设置"
        echo "3) 检测网卡"
        echo "0) 退出"
        read -r -p "请选择: " choice
        case "$choice" in
            1) local_menu ;;
            2) relay_menu ;;
            3)
                list_ifaces
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项"
                ;;
        esac
    done
}

main_menu
