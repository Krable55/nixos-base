{ config, lib, pkgs, ... }:

let
  cfg = config.custom.storage;
in {
  options.custom.storage = {
    enable = lib.mkEnableOption "Enable storage mounts";

    useMediaMount = lib.mkEnableOption "Mount media share";
    useProxmoxMount = lib.mkEnableOption "Mount proxmox share";
  };

  config = lib.mkIf cfg.enable {
    users.groups.${config.custom.group} = {
      members = config.custom.groupMembers;
    };

    fileSystems = lib.mkMerge ([
      (lib.mkIf cfg.useMediaMount {
        "/mnt/media" = {
          device = "192.168.50.154:/MediaCenter";
          fsType = "nfs";
          options = [ "defaults" "x-systemd.automount" ];
        };
      })
      (lib.mkIf cfg.useProxmoxMount {
        "/mnt/proxmox" = {
          device = "192.168.50.154:/Proxmox";
          fsType = "nfs";
          options = [ "defaults" "x-systemd.automount" ];
        };
      })
    ]);

    systemd.tmpfiles.rules = [
      (lib.mkIf cfg.useMediaMount "d /mnt/media 0775 ${config.custom.group} ${config.custom.group} -")
      (lib.mkIf cfg.useProxmoxMount "d /mnt/proxmox 0775 ${config.custom.group} ${config.custom.group} -")
    ];
  };
}
