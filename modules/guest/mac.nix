{ macAddresses, pkgs }:
{ lib, ... }:

with lib;

{
  # nspawn 每次重建容器都给接口随机 MAC。漂了的后果是上游 DHCP 租约变化、
  # 上游按 MAC 绑定失效、宿主 ARP 表认成新设备——所以必须逐个固定。
  #
  # 用 oneshot 直接 ip link set，而不是容器内 udev `.link`：macvlan 时代的
  # 经验是 `.link` 对这类接口静默无效（容器内 udev 收不到设备添加事件）。
  systemd.services.router-fix-macs = {
    description = "固定容器内接口的 MAC";
    before = [ "network-pre.target" ];
    wantedBy = [ "network-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = concatMapStringsSep "\n"
      (iface: "${pkgs.iproute2}/bin/ip link set ${iface} address ${macAddresses.${iface}}")
      (attrNames macAddresses);
  };
}
