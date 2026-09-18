{ config, lib, ... }:

with lib;

let
  cfg = config.router;
in
{
  # VPN 契约：由 VPN 实现填写，路由器只读。
  #
  # 这是"路由器"和"用哪个 VPN"之间唯一的接口。它刻意用**普通 attrset** 而不是
  # NixOS option——VPN 实现不需要知道路由器存在，路由器也不认识任何具体 VPN。
  options.router.vpn = {
    transit = {
      interface = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tun0";
        description = "隧道接口名。null = 没有隧道（纯直连）。";
      };

      fakeIpCidrs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "198.18.0.0/15" ];
        description = ''
          隧道解析器会返回假地址的网段。必须路由进隧道。

          这个契约是"域名级分流"的前提：解析器给被墙域名发 fake-IP，客户端
          拿到之后发往该地址，路由器按这里的网段把它送进隧道。**替代实现若
          不做 fake-IP（例如裸 WireGuard），就只能在 dnsUpstream 里省掉隧道
          解析器，退化成按 IP 段分流。**
        '';
      };

      dnsUpstream = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.251.1.1";
        description = "隧道解析器地址，作为客户端 DNS 的首选上游。null = 只用公网 DNS。";
      };
    };

    guestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = ''
        VPN 实现要注入**容器内**的模块（daemon、登录、转发等）。
        路由器不认识它们，只负责塞进容器的 config.imports。
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.vpn.transit.interface == null || cfg.vpn.transit.fakeIpCidrs != [ ];
        message = ''
          router.vpn.transit.interface 有值时 fakeIpCidrs 不能为空：
          否则隧道解析器发来的 fake-IP 会走默认路由直连出去，分流静默失效。
        '';
      }
    ];
  };
}
