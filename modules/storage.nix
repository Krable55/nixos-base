{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.storage;
in {
  options.custom.storage = {
    mounts = mkOption {
      type = with types; listOf (submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Name of the mount (used as directory name)";
          };
          host = mkOption {
            type = types.str;
            description = "IP or hostname of the NFS server";
          };
          remotePath = mkOption {
            type = types.str;
            description = "Exported remote NFS path (e.g., /MediaCenter)";
          };
          mountPoint = mkOption {
            type = types.str;
            default = config.custom.storage.mountBase + "/${config.name}";
            description = "Where to mount this NFS share";
          };
        };
      });
      default = [];
      description = "List of NFS mounts to create.";
    };

    mountBase = mkOption {
      type = types.str;
      default = "/mnt";
      description = "Base directory for all NFS mounts.";
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group that will own the mounted paths.";
    };

    groupMembers = mkOption {
      type = types.listOf types.str;
      default = [ "kyle" ];
      description = "Users who should be in the media group.";
    };
  };

  config = {
    users.groups.${cfg.group} = {
      members = cfg.groupMembers;
    };

    systemd.tmpfiles.rules = map (mount:
      "d ${mount.mountPoint} 0775 ${cfg.group} ${cfg.group} -"
    ) cfg.mounts;

    fileSystems = builtins.listToAttrs (map (mount: {
      name = mount.mountPoint;
      value = {
        device = "${mount.host}:${mount.remotePath}";
        fsType = "nfs";
        options = [ "defaults" "x-systemd.automount" ];
      };
    }) cfg.mounts);
  };
}
