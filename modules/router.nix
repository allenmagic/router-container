{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.router;

  transit = cfg.vpn.transit;

  # 客户端 DNS 的首选上游是隧道解析器（fake-IP 来源），公网 DNS 兜底。
  # strict-order 保证按声明顺序回落——隧道正常时不会混进公网应答，
  # 否则被墙域名可能拿到污染 IP，fake-IP 不触发，分流失效。
  dnsUpstreams = (optional (transit.dnsUpstream != null) transit.dnsUpstream)
    ++ cfg.fallbackDnsServers;

  # 隧道靠 fake-IP 分流：这些网段必须路由进隧道，否则客户端拿到 fake-IP
  # 之后会走默认路由直连出去。
  # VPN 自己也可能建（yunshu-headless 的 yunshu-routes 就做这件事），
  # route replace 是幂等的，重复无害。
  fakeIpRouteScript = pkgs.writeShellScript "router-transit-routes" ''
    set -eu
    IP=${pkgs.iproute2}/bin/ip
    while true; do
      if "$IP" link show ${transit.interface} >/dev/null 2>&1; then
        ${concatMapStringsSep "\n      " (cidr:
          ''"$IP" route replace ${cidr} dev ${transit.interface} 2>/dev/null || true'')
          transit.fakeIpCidrs}
      fi
      sleep 3
    done
  '';
in
{
  options.router = {
    enable = mkEnableOption "声明式路由器容器（bridge 接入 + NAT + DHCP/DNS）";

    name = mkOption {
      type = types.str;
      default = "router";
      description = "容器名。";
    };

    # ── 宿主侧 ────────────────────────────────────────────────────────
    hostLanPort = mkOption {
      type = types.str;
      example = "lan0";
      description = "宿主机上要挂进 LAN 桥的物理口（按 MAC 锚定的名字）。";
    };

    hostBridge = mkOption {
      type = types.str;
      default = "br-lan";
      description = ''
        LAN 桥名。

        LAN 走 bridge 而不是 macvlan 是刻意的：macvlan 下宿主机看不见容器间
        流量（排障只能靠猜）、跨容器 DNAT 不工作、carrier 还要等父口才就绪
        （会造成服务启动竞态）。bridge 下这些都是普通 L2。
      '';
    };

    hostAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.10.2/24";
      description = "宿主机在桥上的地址。null = 不配。";
    };

    hostDefaultGateway = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "宿主机的默认路由。";
    };

    # ── 容器内 ────────────────────────────────────────────────────────
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

        nspawn 只能有一个桥接接口（--network-bridge 不作用于 --network-veth-extra），
        所以 WAN 侧维持 macvlan —— 它本来也没出过问题，上游 DHCP 实测正常。
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

    fallbackDnsServers = mkOption {
      type = types.listOf types.str;
      default = [ "223.5.5.5" "119.29.29.29" ];
      description = "隧道解析器不应答时的降级上游。";
    };

    # ── VPN 契约（由 VPN 实现填写，路由器只读）────────────────────────
    vpn.transit = {
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
          不做 fake-IP（例如裸 WireGuard），就只能在 DNS 上游里省掉隧道解析器，
          退化成按 IP 段分流。**
        '';
      };

      dnsUpstream = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.251.1.1";
        description = "隧道解析器地址，作为客户端 DNS 的首选上游。null = 只用公网 DNS。";
      };
    };

    vpn.guestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = ''
        VPN 实现要注入**容器内**的模块（daemon、登录、转发等）。
        路由器不认识它们，只负责塞进容器的 config.imports。
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vpn.transit.interface == null || transit.fakeIpCidrs != [ ];
        message = "router.vpn.transit.interface 有值时 fakeIpCidrs 不能为空，否则 fake-IP 会走默认路由直连出去";
      }
    ];

    # ── 宿主侧：建桥并把 LAN 口挂上去 ─────────────────────────────────
    systemd.network = {
      netdevs."10-${cfg.hostBridge}" = {
        netdevConfig = {
          Kind = "bridge";
          Name = cfg.hostBridge;
        };
        bridgeConfig.STP = false;
      };

      networks = {
        "20-${cfg.hostLanPort}" = {
          matchConfig.Name = cfg.hostLanPort;
          networkConfig.Bridge = cfg.hostBridge;
        };

        "30-${cfg.hostBridge}" = {
          matchConfig.Name = cfg.hostBridge;
          networkConfig = {
            DHCP = "no";
            LinkLocalAddressing = "no";
            IPv6AcceptRA = "no";
          } // optionalAttrs (cfg.hostAddress != null) {
            Address = cfg.hostAddress;
          } // optionalAttrs (cfg.hostDefaultGateway != null) {
            Gateway = cfg.hostDefaultGateway;
          };
        };
      };
    };

    # ── 容器 ─────────────────────────────────────────────────────────
    containers.${cfg.name} = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      # WAN 侧：macvlan 直连物理口，容器自己向上游要 DHCP
      macvlans = [ "${cfg.wanParent}:${cfg.wanInterface}" ];
      enableTun = true;

      config = { config, lib, pkgs, ... }: {
        imports = cfg.vpn.guestModules;

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
          dhcpcd.extraConfig = "nohook resolv.conf";
          resolvconf.enable = false;

          firewall = {
            filterForward = true;
            extraForwardRules = "iifname \"${cfg.lanInterface}\" accept";
            allowedTCPPorts = [ 53 ];
            allowedUDPPorts = [ 53 67 ]; # 53 DNS，67 DHCP 服务端
          };
        };

        # 容器自身的解析：隧道解析器优先，公网兜底。不能交给 WAN 的 DHCP 下发
        # ——登录 VPN 客户端要先把控制面域名解析出来，那时隧道还没起来。
        environment.etc."resolv.conf" = {
          mode = "0644";
          text = ''
            ${concatMapStringsSep "\n" (s: "nameserver ${s}") dnsUpstreams}
          '';
        };

        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
          "net.ipv4.conf.all.rp_filter" = 0;
          "net.ipv4.conf.default.rp_filter" = 0;
          "net.ipv4.conf.all.send_redirects" = 0;
          "net.ipv4.conf.default.send_redirects" = 0;
          "net.ipv6.conf.all.disable_ipv6" = 1;
          "net.ipv6.conf.default.disable_ipv6" = 1;
        };

        # 直连出口的 NAT
        networking.nftables.enable = true;
        networking.nftables.tables.router-snat = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              oifname "${cfg.wanInterface}" masquerade
            }
          '';
        };

        # 客户端 DNS：本机 dnsmasq，上游隧道解析器优先。
        # **不要改回"把 53 DNAT 到别的容器"**：macvlan 下跨容器 DNAT 实测不通，
        # 且目标不可达时客户端 DNS 会整个断掉，本地解析器则永远在场。
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            interface = cfg.lanInterface;
            bind-dynamic = true;
            strict-order = true;
            no-resolv = true;
            server = dnsUpstreams;
          } // optionalAttrs (cfg.dhcpRange != null) {
            dhcp-authoritative = true;
            dhcp-range = [ cfg.dhcpRange ];
            dhcp-option = map (o: "${cfg.lanInterface},${o}") cfg.dhcpOptions;
          };
        };

        systemd.services.router-transit-routes = mkIf (transit.interface != null && transit.fakeIpCidrs != [ ]) {
          description = "把 fake-IP 网段路由进隧道";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${fakeIpRouteScript}";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };
  };
}
