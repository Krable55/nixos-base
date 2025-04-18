{ config, lib, pkgs, ... }:

let
  cfg = config.custom.backup;

  scriptFile = pkgs.buildEnv {
    name = "rsync-backup-wrapper";
    paths = [ (pkgs.writeShellScriptBin "rsync-backup" (builtins.readFile cfg.scriptPath)) ];
    pathsToLink = [ "/bin" ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/rsync-backup \
        --prefix PATH : ${lib.makeBinPath [ pkgs.rsync pkgs.coreutils pkgs.findutils pkgs.gnused ]}
    '';
  };

in {
  options.custom.backup = {
    enable = lib.mkEnableOption "Enable rsync-based backup service";

    scriptPath = lib.mkOption {
      type = lib.types.path;
      default = ./.bin/rsync.sh;
      description = "Path to the rsync backup script file (e.g. ./.bin/rsync.sh).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd OnCalendar value (e.g. daily, weekly, or specific time).";
    };

    srcDir = lib.mkOption {
      type = lib.types.path;
      default = "/";
      description = "Source directory to back up.";
    };

    targetDir = lib.mkOption {
      type = lib.types.path;
      default = "/media/data/backup";
      description = "Target directory where backups are stored.";
    };

    includePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of relative paths to include in the rsync backup (passed as --include).";
    };

    retention = {
      daily = lib.mkOption { type = lib.types.int; default = 3; description = "Number of daily backups to keep."; };
      weekly = lib.mkOption { type = lib.types.int; default = 2; description = "Number of weekly backups to keep."; };
      monthly = lib.mkOption { type = lib.types.int; default = 3; description = "Number of monthly backups to keep."; };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ scriptFile ];

    systemd.services.rsync-backup = {
      description = "Rsync Backup Job";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HOME=/root"
          "SRC=${cfg.srcDir}"
          "BCKP=${cfg.targetDir}"
          "DAILY=${toString cfg.retention.daily}"
          "WEEKLY=${toString cfg.retention.weekly}"
          "MONTHLY=${toString cfg.retention.monthly}"
          ''INCLUDE=${lib.concatStringsSep " " cfg.includePaths}''
        ];
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
