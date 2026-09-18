{ config, lib, ... }:

with lib;

let
  cfg = config.router;
in
{
  options.router = {
    hostLanPort = mkOption {
      type = types.str;
      example = "lan";
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
  };

  config = mkIf cfg.enable {
    systemd.network = {
      netdevs."10-${cfg.hostBridge}" = {
        netdevConfig = {
          Kind = "bridge";
          Name = cfg.hostBridge;
        };
        bridgeConfig.STP = false;
      };

      networks = {
        # 物理口只做二层，不配地址
        "20-${cfg.hostLanPort}" = {
          matchConfig.Name = cfg.hostLanPort;
          networkConfig.Bridge = cfg.hostBridge;
        };

        # WAN 口：同样不配地址，但**必须由 networkd 管起来才会 UP**。
        # 少了这份配置链接会一直是 DOWN 状态，挂在它上面的 macvlan 拿不到载波，
        # 而 nspawn 的网络建立是一步完成的——macvlan 失败会连 LAN 侧的 veth
        # 一起中止，容器里既没有 WAN 也没有 host0，boot 卡在等 network-online。
        "20-${cfg.wanParent}" = {
          matchConfig.Name = cfg.wanParent;
          networkConfig = {
            DHCP = "no";
            LinkLocalAddressing = "no";
            IPv6AcceptRA = "no";
          };
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
  };
}
