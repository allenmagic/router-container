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
      example = "wan";
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

    macAddresses = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        host0 = "02:00:00:02:00:11";
        eth1 = "02:00:00:02:00:12";
      };
      description = ''
        容器内接口的固定 MAC。nspawn 每次重建容器都随机生成，漂了的后果是
        上游 DHCP 租约变化、上游按 MAC 绑定失效、宿主 ARP 表认成新设备。
      '';
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
        ++ optional (cfg.macAddresses != { })
          (import ./guest/mac.nix { inherit (cfg) macAddresses; inherit pkgs; })
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
          # nohook：/etc/resolv.conf 是下面写死的 store 符号链接，dhcpcd 写它会报错。
          # hostname：dhcpcd **默认不发** hostname（option 12），不写这行上游设备列表
          # 里只有 MAC，而我们的 MAC 是本地管理地址，一堆容器看起来一模一样。
          dhcpcd.extraConfig = ''
            nohook resolv.conf
            hostname ${cfg.name}
          '';
          resolvconf.enable = false;

          firewall = {
            filterForward = true;
            extraForwardRules = ''
              # 隧道 MTU 小于 1500，LAN 客户端发满包进去会被丢。clamp MSS 防 PMTUD 黑洞。
              tcp flags syn tcp option maxseg size set rt mtu
              iifname "${cfg.lanInterface}" accept
            '';
            allowedTCPPorts = [ 53 ];
            allowedUDPPorts = [ 53 67 ]; # 53 DNS，67 DHCP 服务端

            # 路由器不能用 strict（NixOS 默认）：它会生成一条 prerouting 优先级、
            # policy drop 的 rpfilter 链，只放行"源地址能从同一接口路由回去"的包。
            # 多宿主机 + 隧道（fake-IP → tun0）的非对称路径会被误伤。
            # 注意 nat.nix 里的 rp_filter sysctl 管不到这条链——那是内核层，这是 nftables 层。
            checkReversePath = "loose";
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
