# 纯直连：不做任何代理，客户端出网走 WAN 的 NAT。
#
# 它存在的意义是让"路由器"本身可独立验证——先确认 NAT / DHCP / DNS 都对，
# 再叠 VPN。也用于没有可用 VPN 客户端的场合（例如 arm64 上没有 x86-64 的包）。
{
  lib,
  ...
}:

{
  router.vpn = {
    transit = {
      interface = null;
      fakeIpCidrs = [ ];
      dnsUpstream = null;
    };
    # guestModules 留空：不需要往容器里注入任何东西
  };
}
