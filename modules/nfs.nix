{ config, lib, ... }:

let
  cfg = config.custom.nfs;

  mkMount = name: mount:
    lib.nameValuePair "/mnt/${name}" {
      device = mount.device;
      fsType = "nfs";
      options = mount.options or [ "x-systemd.automount" "noauto" "_netdev" ];
    };

  mkTmpfileRule = name: mount:
    let
      mode = mount.mode or "0755";
      owner = mount.owner or "root";
      group = mount.group or "root";
    in
      "d /mnt/${name} ${mode} ${owner} ${group} -";

in {
  options.custom.nfs = {
    enable = lib.mkEnableOption "Enable declarative NFS mounts";

    mounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          device = lib.mkOption {
            type = lib.types.str;
            description = "NFS device string, e.g., 192.168.1.100:/share";
          };

          options = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "x-systemd.automount" "noauto" "_netdev" ];
            description = "Mount options for the NFS share";
          };

          mode = lib.mkOption {
            type = lib.types.str;
            default = "0755";
            description = "Permissions for the mount point directory";
          };

          owner = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Owner of the mount point directory";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Group of the mount point directory";
          };
        };
      });

      default = {};
      description = "Set of NFS mounts keyed by name (used as subfolder under /mnt)";
    };
  };

  config = lib.mkIf cfg.enable {
    # services.nfs.client.enable = true;

    fileSystems = lib.mapAttrs' mkMount cfg.mounts;

    systemd.tmpfiles.rules = lib.mapAttrsToList mkTmpfileRule cfg.mounts;
  };
}
