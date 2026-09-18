{ lanInterface, upstreams, dhcpRange, dhcpOptions }:
{ lib, ... }:

with lib;

{
  # 客户端 DNS 由本机 dnsmasq 提供，上游隧道解析器优先、公网兜底。
  #
  # **不要改回"把 53 DNAT 到别的容器"**：macvlan 下跨容器 DNAT 实测不通，
  # 而且目标不可达时客户端 DNS 会整个断掉，不是降级。本地解析器则永远在场，
  # 上游选错最多是解析慢或拿到真实 IP。
  services.dnsmasq = {
    enable = true;
    # 不接管容器自身的解析：容器的 resolv.conf 由 container.nix 写死，
    # 让 dnsmasq 覆盖它会绕一圈。
    resolveLocalQueries = false;

    settings = {
      interface = lanInterface;
      # bind-dynamic 而非 bind-interfaces：接口/地址变化时自动跟随
      bind-dynamic = true;

      # 上游顺序即优先级。strict-order 保证按声明顺序回落，隧道正常时不会
      # 混进公网应答——否则被墙域名可能拿到污染 IP，fake-IP 不触发，分流失效。
      strict-order = true;
      no-resolv = true;
      server = upstreams;
    } // optionalAttrs (dhcpRange != null) {
      dhcp-authoritative = true;
      dhcp-range = [ dhcpRange ];
      dhcp-option = map (o: "${lanInterface},${o}") dhcpOptions;
    };
  };
}
