{ macAddresses, lanInterface, pkgs }:
{ lib, ... }:

with lib;

{
  # 把 nspawn 建的网络接口整成我们配置里预期的样子。两件事：
  #
  # ① **改名**：容器侧 veth 的名字随 systemd 版本变——man 页写的是 host0，
  #    但 systemd 260 实测给的是 eth0。写死任何一个都会在换版本时静默失配
  #    （地址配不上、MAC 改不了、dnsmasq 找不到接口），所以按接口类型找出来
  #    主动改名，不赌默认值。
  #
  # ② **固定 MAC**：nspawn 每次重建都随机生成，漂了的后果是上游 DHCP 租约
  #    变化、按 MAC 绑定失效、宿主 ARP 表认成新设备。
  #
  # 用 oneshot 直接 ip link set，而不是容器内 udev `.link`：这类接口是 nspawn
  # 在宿主 netns 建好再移进来的，容器内 udev 收不到设备添加事件，`.link` 静默
  # 无效（macvlan 时代验证过）。
  systemd.services.router-prepare-interfaces = {
    description = "改名 nspawn 的 veth 并固定各接口 MAC";
    before = [ "network-pre.target" ];
    wantedBy = [ "network-pre.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ip=${pkgs.iproute2}/bin/ip

      # veth 是唯一需要改名的（macvlan/tun 由 nspawn 按我们给的名字建）
      for i in $(${pkgs.coreutils}/bin/ls /sys/class/net); do
        [ "$i" = "lo" ] && continue
        case "$i" in "${lanInterface}") continue ;; esac
        if "$ip" -d link show "$i" 2>/dev/null | grep -qw veth; then
          "$ip" link set "$i" down
          "$ip" link set "$i" name "${lanInterface}"
          "$ip" link set "${lanInterface}" up
        fi
      done

      ${concatMapStringsSep "\n"
        (iface: "\"$ip\" link set ${iface} address ${macAddresses.${iface}}")
        (attrNames macAddresses)}
    '';
  };
}
