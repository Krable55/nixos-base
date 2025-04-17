{ config, lib, pkgs, ... }:

let
  cfg = config.custom.backup;

  # Reference to your script in the repo
  scriptFile = pkgs.writeShellScriptBin "rsync-backup" (builtins.readFile ./rsync.sh);

in {
  options.custom.backup = {
    enable = lib.mkEnableOption "Enable rsync-based backup service";
    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd OnCalendar value (e.g. daily, weekly, or specific time).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ scriptFile ];

    systemd.services.rsync-backup = {
      description = "Rsync Backup Job";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${scriptFile}/bin/rsync-backup";
      };
    };

    systemd.timers.rsync-backup = {
      description = "Run rsync backup periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };
  };
}
