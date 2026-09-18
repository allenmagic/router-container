{ config, lib, ... }:

with lib;

let
  cfg = config.router;
in
{
  imports = [
    ./bridge.nix
    ./contract.nix
    ./container.nix
  ];

  options.router.enable = mkEnableOption "声明式路由器容器（bridge 接入 + NAT + DHCP/DNS）";

  config = mkIf cfg.enable { };
}
