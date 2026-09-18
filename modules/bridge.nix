{ config, lib, ... }:

with lib;

let
  cfg = config.router;
in
{
  options.router = {
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
