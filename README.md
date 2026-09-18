# router-container

声明式路由器容器：**bridge 接入 + NAT + DHCP/DNS + 可插拔 VPN**。

它把"路由器"和"用哪个 VPN"分开：路由器只管转发、地址、DHCP/DNS；VPN 只提供
三项契约（隧道接口、fake-IP 网段、隧道解析器地址）和要跑在容器里的模块。

## 用法

```nix
{
  imports = [ inputs.router-container.nixosModules.router ];

  router = {
    enable = true;
    hostLanPort = "lan";        # 宿主机上要挂进桥的物理口
    hostAddress = "192.168.10.2/24";
    hostDefaultGateway = "192.168.10.1";
    wanParent = "wan";          # WAN 侧 macvlan 的父口
    address = "192.168.10.1";   # 客户端的网关与 DNS

    dhcpRange = "lan,192.168.10.100,192.168.10.200,255.255.255.0,12h";
    dhcpOptions = [ "3,192.168.10.1" "6,192.168.10.1" ];

    # nspawn 每次重建都随机生成 MAC，不固定的话上游租约与按 MAC 绑定都会漂
    macAddresses = {
      lan = "02:00:00:02:00:11";
      wan = "02:00:00:02:00:12";
    };

    vpn = inputs.router-container.vpns.yunshu;   # 换实现就换这一行
  };
}
```

`vpn = inputs.router-container.vpns.none` 是纯直连（不做代理），用来先把
NAT / DHCP / DNS 单独验证通过。

## 网络模型

| 侧 | 接法 | 为什么 |
|---|---|---|
| LAN | **bridge**（nspawn veth → `br-lan`，容器内叫 `lan`） | macvlan 下宿主机看不见容器间流量、跨容器 DNAT 不工作、carrier 要等父口就绪（造成服务启动竞态）；bridge 下这些都是普通 L2 |
| WAN | **macvlan**（父口 `wan`，容器内叫 `wan`） | nspawn 的 `--network-bridge` 只作用于 `--network-veth` 那一个接口，容器只能有一个桥接口；WAN 侧 macvlan 本来也没出过问题 |

两侧的名字都是**我们起的**（`lanInterface` / `wanInterface`，默认 `lan` / `wan`），
按作用命名，与宿主机上的物理口一致。WAN 侧 nspawn 直接按这个名字建 macvlan；
LAN 侧要多一步：`modules/guest/mac.nix` 按"是不是 veth"找出 nspawn 建的容器侧接口
再改名 —— 因为它的名字随 systemd 版本变（man 页写 `host0`，systemd 260 实测给 `eth0`），
写死任何一个换版本就静默失配。

⚠️ 改了 `lanInterface` 要同步 `dhcpRange` 的第一段（那是接口名，不会被自动补上）。

## 契约

VPN 实现提供（见 `vpns.*` 的输出）：

```nix
{
  transit = {
    interface;      # 隧道接口名，null = 无隧道
    fakeIpCidrs;    # 隧道解析器会返回假地址的网段，必须路由进隧道
    dnsUpstream;    # 隧道解析器地址，作为客户端 DNS 的首选上游
  };
  guestModules = [ ... ];   # 注入容器 config.imports
}
```

`fakeIpCidrs` 与 `dnsUpstream` 是绑在一起的：解析器给被墙域名发假地址，
客户端拿到后发往该地址，路由器按这个网段把它送进隧道。**替代实现若不做
fake-IP（例如裸 WireGuard），就只能在 `dnsUpstream` 里省掉隧道解析器，
退化成按 IP 段分流。**

`interface` 有值而 `fakeIpCidrs` 为空会触发断言——那种情况下 fake-IP 会
走默认路由直连出去，静默失效。
