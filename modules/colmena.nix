{ config, lib, pkgs, ... }:

let
  cfg = config.custom.colmena;
in {
  options.custom.colmena = {
    enable = lib.mkEnableOption "Enable Colmena for managing NixOS clusters";

    user = lib.mkOption {
      type = lib.types.str;
      default = "colmena";
      description = "System user to run Colmena commands as (optional)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "colmena";
      description = "Group for the Colmena user";
    };

    manifestDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/colmena";
      description = "Path to store Colmena manifest files";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.colmena ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.manifestDir;
      createHome = true;
    };

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.manifestDir} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
