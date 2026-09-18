{
  description = "声明式路由器容器：bridge 接入 + NAT + DHCP/DNS + 可插拔 VPN";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    yunshu-nix = {
      url = "github:allenmagic/yunshu-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, yunshu-nix, ... }:
    let
      # YunShu 的"我是什么"：三项契约 + 容器内要跑的模块。
      # 三项契约由路由器的 router.transit 消费，路由器不认识 YunShu。
      #
      # fakeIpCidrs 与 dnsUpstream 是绑在一起的：隧道解析器给被墙域名发
      # 198.18.0.0/15 的假地址，客户端拿到之后发往该地址，路由器按这个网段
      # 把它送进 tun0。少任何一项，分流都不成立。
      yunshuVpn = {
        transit = {
          interface = "tun0";
          fakeIpCidrs = [ "198.18.0.0/15" ];
          dnsUpstream = "10.251.1.1";
        };

        guestModules = [
          yunshu-nix.nixosModules.yunshu-headless
          # 开箱可用的默认值：部署方用额外的模块覆盖差异项即可
          # （corpCode / spAddr / package 等）。
          ({ lib, ... }: {
            services.yunshu = {
              enable = true;
              loginOnStart = true;
            };
          })
        ];
      };
    in
    {
      nixosModules = {
        # 路由器本体：拥有容器、桥、NAT、DHCP/DNS。不认识任何具体 VPN。
        router = ./modules/router.nix;

        # VPN 实现：纯直连（不做代理）。
        vpn-none = ./modules/vpn/none.nix;
      };

      # 现成的 VPN 描述符，形如 { transit = {...}; guestModules = [ ... ]; }
      vpns = {
        yunshu = yunshuVpn;
        none = {
          transit = {
            interface = null;
            fakeIpCidrs = [ ];
            dnsUpstream = null;
          };
          guestModules = [ ];
        };
      };
    };
}
