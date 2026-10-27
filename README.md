# Hysteria2 端口跳跃与中转机转发

适用于 [v2board](https://github.com/wyx2685/v2board) 面板和 [v2node](https://github.com/wyx2685/v2node) 落地。Hysteria2 端口跳跃和中转是两件事，分开配。

v2node 只监听一个 UDP 端口（服务端口）。客户端在一段端口里来回跳（连接端口）。这段端口要在到达 v2node 之前，被转到服务端口。

| 位置 | 作用 |
|---|---|
| 面板「连接端口」 | 写给客户端的跳跃范围，例如 `30000-50000` |
| 面板「服务端口」 | v2node 实际监听的端口，例如 `443` |
| 落地机 | 只跑 v2node，监听服务端口 |
| 中转机 | 把跳跃范围转到落地机的 `公网IP:服务端口` |

下面用连接端口 `30000-50000`、服务端口 `443` 做例子。面板里用 `-`，iptables 里用 `:`。

## 一键

在 VPS 上粘贴这一条。它会打开菜单，提示从终端读取。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tumgle/hy2/main/install.sh)
```

```text
1) 本机 Hysteria2 设置
2) 中转机 Hysteria2 设置
3) 检测网卡
```

本机菜单可以应用规则、改端口、选网卡、查看规则、删除规则、开机加载。中转菜单多一项落地公网 IP。默认跳跃端口是 UDP `30000:50000`，服务端口是 `443`，都可以在菜单里改。

脚本会装到 `/usr/local/lib/hy2`。三个脚本已经在同一目录时，`sudo ./install.sh` 用旁边的文件，不再下载。

## 面板

节点类型选 **v2node**，协议选 **Hysteria2**。

| 字段 | 值 |
|---|---|
| 连接端口 | `30000-50000` |
| 服务端口 | `443` |
| 证书模式 | **自签名** |
| Allow Insecure | 打开 |
| Server Name(SNI) | 与订阅里的 `sni` 一致，例如 `bing.com` |
| 权限组 | 包含要使用的用户组 |

证书模式要在「安全性 → 编辑配置」里**重新点一次「自签名」**再提交。只显示着「自签名」、实际值仍是「无证书(关闭TLS)」时，v2node 会报 `hysteria: tls config is nil` 并反复重启。

`连接端口` 这一列最长 11 个字符。`30000-50000` 刚好 11 个字符，不要再加别的端口。

这台机器上的 v2node 必须接这个 Hysteria2 节点的 ID。`/etc/v2node/config.yml` 里的 `NodeID` 如果是另一条 VLESS 节点，Hysteria2 订阅不会通。

保存后在落地机执行：

```bash
systemctl restart v2node
ss -ulnp | grep v2node
```

应看到 v2node 监听 **UDP 443**。

## 落地机：只做端口跳跃

在落地机上运行菜单，选 **1) 本机 Hysteria2 设置**。里面可以单独改端口、检测网卡、查看规则、删除规则、开机自动加载。

```bash
sudo ./hy2.sh
```

也可以不用菜单：

```bash
sudo ./hop.sh
sudo ./hop.sh --range 30000:50000 --listen 443 --iface eth0
sudo ./hop.sh --delete
sudo ./hop.sh --persist
```

服务端口不要落在跳跃范围里，脚本会拒绝这种参数。安全组放行 **UDP 443** 和 **UDP 30000–50000**。客户端连上后，规则的 `pkts` 应从 0 往上涨。

## 中转机转发

中转机不跑 v2node。它把客户端发来的 UDP `30000-50000` 转到落地机公网 IP 的 `443`。

先在落地机查公网 IP：

```bash
curl -4 -s ifconfig.me; echo
```

然后在**中转机**上运行菜单，选 **2) 中转机 Hysteria2 设置**。先配落地 IP 和端口，再应用转发。脚本会打开 IPv4 转发，并删掉同范围的本机 `to::443`。

```bash
sudo ./hy2.sh
```

也可以不用菜单：

```bash
sudo ./relay.sh --landing 落地公网IP
sudo ./relay.sh --landing 落地公网IP --range 30000:50000 --listen 443
sudo ./relay.sh --landing 落地公网IP --delete
sudo ./relay.sh --persist --landing 落地公网IP
```

正确结果只有一条：

```text
DNAT  udp dpts:30000:50000  to:落地公网IP:443
```

`to::443` 是错的，流量会留在中转机上。

中转机安全组放行 **UDP 30000–50000**。落地机安全组放行来自中转机 IP 的 **UDP 443**。

落地机上那条转到本机 `443` 的规则可以留着。中转流量到达落地机时目的端口已经是 `443`，不会再走那条规则。

面板里这个节点的「节点地址」填中转域名。连接端口仍是 `30000-50000`，服务端口仍是 `443`。

[dport.sh](https://github.com/feinhunter/dport) 只会转到本机端口，默认还是 `10595:11596 → 10593`。中转不要用它。

## 订阅

客户端重新拉取后，Clash Meta 应类似：

```yaml
- name: test
  type: hysteria2
  server: 中转域名
  skip-cert-verify: true
  sni: bing.com
  udp: true
  port: 30000
  ports: 30000-50000
```

`port` 是范围里的第一个端口，`ports` 才是跳跃范围。`skip-cert-verify` 必须是 `true`（自签证书）。Clash Meta 不用 `mport`。

v2rayN 等分享链接把同一段写成查询参数 `mport`（连字符）。密码、服务器、sni 换成自己的。中转时服务器填中转域名：

```text
hysteria2://密码@服务器:30000/?mport=30000-50000&insecure=1&sni=bing.com
```

官方 Hysteria2 客户端不读 `mport`，把范围写在端口上：`服务器:30000-50000`。

## 核对

```bash
# 落地机：v2node 在听 443
ss -ulnp | grep v2node

# 中转机：目标是落地公网 IP，不是 to::443
iptables -t nat -L PREROUTING -n -v
```

从外网连中转域名的 `30000`，能完成 Hysteria2 握手即整条链路是通的。连上之后中转机上这条 DNAT 的 `pkts` 会上涨。

不加 `--persist` 时，这些规则重启后会消失。需要开机自动加载时，再执行一次带 `--persist` 的命令。

## 故障

| 现象 | 原因 |
|---|---|
| `hysteria: tls config is nil`，v2node 一直重启 | 证书模式是「无证书(关闭TLS)」。改成「自签名」并重新点选后提交 |
| 证书错误，`certificate signed by unknown authority` | 订阅里 `skip-cert-verify` 仍是 `false`。打开 Allow Insecure，重新拉取订阅 |
| 中转机 `pkts` 一直是 0 | 客户端端口不在 `30000-50000`，或安全组没放行这段 UDP |
| 认证失败，HTTP `404` | 链路是通的。落地机 `NodeID` 不是这个 Hysteria2 节点，或该节点权限组不包含这个用户 |
| 日志里节点是 `vless` | `/etc/v2node/config.yml` 的 `NodeID` 接错了节点 |
| 只转一个端口，大约 30 秒后断开 | 客户端会换端口。中转必须转发整段 `30000:50000` |
