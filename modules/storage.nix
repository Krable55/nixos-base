{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.storage;

  mounts = lib.filter (x: x != null) [
    (if cfg.enableMediaMount then {
      mountPoint = "/mnt/media";
      device = "192.168.50.154:/MediaCenter";
    } else null)
    (if cfg.enableProxmoxMount then {
      mountPoint = "/mnt/proxmox";
      device = "192.168.50.154:/Proxmox";
    } else null)
  ];
in {
  options.custom.storage = {
    enableMediaMount = mkOption {
      type = types.bool;
      default = false;
      description = "Enable mounting the /mnt/media share.";
    };

    enableProxmoxMount = mkOption {
      type = types.bool;
      default = false;
      description = "Enable mounting the /mnt/proxmox share.";
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group that owns the mounted paths.";
    };

    groupMembers = mkOption {
      type = types.listOf types.str;
      default = [ "kyle" ];
      description = "Users in the group for the mounts.";
    };
  };

  config = {
    users.groups.${cfg.group} = {
      members = cfg.groupMembers;
    };

    systemd.tmpfiles.rules = map (m:
      "d ${m.mountPoint} 0775 ${cfg.group} ${cfg.group} -"
    ) mounts;

    fileSystems = builtins.listToAttrs (map (m: {
      name = m.mountPoint;
      value = {
        device = m.device;
        fsType = "nfs";
        options = [ "defaults" "x-systemd.automount" ];
      };
    }) mounts);
  };
}
