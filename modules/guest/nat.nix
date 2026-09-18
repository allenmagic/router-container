# 容器内的转发与 NAT。
#
# guest/ 下的文件都是**函数**：它们在容器内求值，读不到宿主侧的 router.* 选项，
# 所以参数必须由 modules/container.nix 显式传进来。
{ wanInterface }:
{ ... }:

{
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    # macvlan/隧道混用时非对称路由很常见，关掉反向路径过滤
    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    # 整套设计只做 IPv4；v6 显式关掉，免得半吊子转发引入难查的问题
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };

  # 直连流量出 WAN 口时改源地址，否则回包从上游直接绕回下游设备、绕开本容器
  networking.nftables.enable = true;
  networking.nftables.tables.router-snat = {
    family = "ip";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${wanInterface}" masquerade
      }
    '';
  };
}
