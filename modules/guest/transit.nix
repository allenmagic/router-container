{ interface, fakeIpCidrs, pkgs }:
{ lib, ... }:

with lib;

let
  routeScript = pkgs.writeShellScript "router-transit-routes" ''
    set -eu
    IP=${pkgs.iproute2}/bin/ip
    # 隧道可能延迟出现（VPN 客户端要先登录），所以持续轮询而不是只做一次
    while true; do
      if "$IP" link show ${interface} >/dev/null 2>&1; then
        ${concatMapStringsSep "\n        " (cidr:
          ''"$IP" route replace ${cidr} dev ${interface} 2>/dev/null || true'')
          fakeIpCidrs}
      fi
      sleep 3
    done
  '';
in
{
  # 契约的落地：隧道解析器给被墙域名发 fake-IP，客户端拿到之后发往该地址，
  # 必须按这些网段把它送进隧道，否则会走默认路由直连出去。
  #
  # VPN 自己也可能建同样的路由（route replace 幂等，重复无害）。
  systemd.services.router-transit-routes = {
    description = "把 fake-IP 网段路由进隧道";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${routeScript}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
