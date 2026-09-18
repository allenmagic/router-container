{ config, lib, ... }:

with lib;

let
  cfg = config.router;

  # 客户端 DNS 首选上游是隧道解析器（fake-IP 来源），公网兜底
  upstreams = (optional (cfg.vpn.transit.dnsUpstream != null) cfg.vpn.transit.dnsUpstream)
    ++ cfg.fallbackDnsServers;
in
{
  options.router = {
    name = mkOption {
      type = types.str;
      default = "router";
      description = "容器名。";
    };

    lanInterface = mkOption {
      type = types.str;
      default = "host0";
      description = ''
        容器内 LAN 口名。**不是可随意改的**：nspawn 的 --network-veth 创建的
        容器侧接口固定叫 host0，改名要额外的 udev 规则，而 macvlan 时代那套
        `.link` 改名静默失效过一次，不值得再赌。
      '';
    };

    wanParent = mkOption {
      type = types.str;
      example = "wan0";
      description = ''
        WAN 侧做 macvlan 的父口。

        nspawn 只能有一个桥接接口（--network-bridge 不作用于
        --network-veth-extra），所以 WAN 侧维持 macvlan——它本来也没出过
        问题，上游 DHCP 实测正常。
      '';
    };

    wanInterface = mkOption {
      type = types.str;
      default = "eth1";
      description = "容器内 WAN 口名。";
    };

    address = mkOption {
      type = types.str;
      example = "192.168.10.1";
      description = "容器 LAN 地址，同时是客户端的网关与 DNS（由 DHCP 下发）。";
    };

    prefixLength = mkOption {
      type = types.int;
      default = 24;
    };

    fallbackDnsServers = mkOption {
      type = types.listOf types.str;
      default = [ "223.5.5.5" "119.29.29.29" ];
      description = "隧道解析器不应答时的降级上游。";
    };

    dhcpRange = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "host0,192.168.10.100,192.168.10.200,255.255.255.0,12h";
      description = "DHCP 地址池。null = 不做 DHCP。";
    };

    dhcpOptions = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "3,192.168.10.1" "6,192.168.10.1" ];
      description = "额外的 DHCP option（不含接口名前缀）。";
    };
  };

  config = mkIf cfg.enable {
    containers.${cfg.name} = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      macvlans = [ "${cfg.wanParent}:${cfg.wanInterface}" ];
      enableTun = true;

      config = { config, lib, pkgs, ... }: {
        imports = [
          (import ./guest/nat.nix { inherit (cfg) wanInterface; })
          (import ./guest/dns.nix {
            inherit (cfg) lanInterface dhcpRange dhcpOptions;
            inherit upstreams;
          })
        ]
        ++ optional (cfg.vpn.transit.interface != null && cfg.vpn.transit.fakeIpCidrs != [ ])
          (import ./guest/transit.nix {
            inherit (cfg.vpn.transit) interface fakeIpCidrs;
            inherit pkgs;
          })
        ++ cfg.vpn.guestModules;

        system.stateVersion = "26.05";
        networking.hostName = cfg.name;

        networking = {
          interfaces.${cfg.lanInterface}.ipv4.addresses = [
            {
              address = cfg.address;
              prefixLength = cfg.prefixLength;
            }
          ];
          interfaces.${cfg.wanInterface}.useDHCP = true;
          # dhcpcd 别去写 /etc/resolv.conf：那是下面写死的 store 符号链接
          dhcpcd.extraConfig = "nohook resolv.conf";
          resolvconf.enable = false;

          firewall = {
            filterForward = true;
            extraForwardRules = ''iifname "${cfg.lanInterface}" accept'';
            allowedTCPPorts = [ 53 ];
            allowedUDPPorts = [ 53 67 ]; # 53 DNS，67 DHCP 服务端
          };
        };

        # 容器自身的解析：隧道解析器优先、公网兜底。不能交给 WAN 的 DHCP 下发
        # ——登录 VPN 客户端要先把控制面域名解析出来，那时隧道还没起来。
        environment.etc."resolv.conf" = {
          mode = "0644";
          text = concatMapStringsSep "\n" (s: "nameserver ${s}") upstreams;
        };
      };
    };
  };
}
