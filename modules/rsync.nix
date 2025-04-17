{ config, pkgs, lib, ... }:

{
  options.backup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable rsync-based backup service.";
    };

    sourceDirs = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      description = "Attribute set mapping systemd service names to source directories to back up.";
    };

    targetDir = lib.mkOption {
      type = lib.types.path;
      description = "Backup destination directory (e.g., NFS mount or NAS).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd timer interval (e.g., daily, hourly).";
    };

    retention = {
      daily = lib.mkOption {
        type = lib.types.int;
        default = 7;
        description = "Number of daily backup logs to keep.";
      };

      weekly = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Number of weekly backup logs to keep.";
      };

      monthly = lib.mkOption {
        type = lib.types.int;
        default = 12;
        description = "Number of monthly backup logs to keep.";
      };

      yearly = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of yearly backup logs to keep.";
      };
    };
  };

  config = lib.mkIf config.backup.enable {
    systemd.tmpfiles.rules = [
      "d /var/log 0755 root root -"
    ];

    systemd.services.rsync-backup = {
      description = "Compressed Backup Job";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/bash -c " +
          lib.escapeShellArg (
            let
              backupCommands = lib.attrValues (lib.mapAttrs (
                service path:
                  ''
                    if systemctl is-active --quiet '' + service + ''; then
                      tarball="${path}/../$(basename ${path})-$(date +%Y-%m-%d_%H-%M-%S).tar.gz";
                      tar -czf "$tarball" -C "$(dirname ${path})" "$(basename ${path})" && \
                      /run/current-system/sw/bin/rsync -a "$tarball" "" + toString config.backup.targetDir + "/" | tee -a "$logfile" && \
                      rm -f "$tarball";
                    fi
                  ''
              ) config.backup.sourceDirs);
            in
              "timestamp=\"$(date +%Y-%m-%d_%H-%M-%S)\"; logfile=/var/log/rsync-backup-$timestamp.log; " +
              builtins.concatStringsSep " && " backupCommands
          );
      };
    };

    systemd.timers.rsync-backup = {
      description = "Run compressed rsync backup periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = config.backup.interval;
        Persistent = true;
      };
    };

    systemd.services.rsync-prune-logs = {
      description = "Prune old rsync backup logs";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/run/current-system/sw/bin/bash -c " +
          lib.escapeShellArg ''
            find /var/log -name 'rsync-backup-*.log' | \
            sort -r | \
            awk -v keep_daily=''' + builtins.toString config.backup.retention.daily + ''' \
                -v keep_weekly=''' + builtins.toString config.backup.retention.weekly + ''' \
                -v keep_monthly=''' + builtins.toString config.backup.retention.monthly + ''' \
                -v keep_yearly=''' + builtins.toString config.backup.retention.yearly + ''' \
                'BEGIN {
                  daily = 0; weekly = 0; monthly = 0; yearly = 0;
                }
                {
                  cmd = "basename " $0;
                  cmd | getline fname;
                  close(cmd);

                  split(fname, parts, /[-_.]/);
                  year = parts[3]; month = parts[4]; day = parts[5];

                  if (daily < keep_daily && day >= strftime("%d", systime() - 86400*7)) {
                    daily++;
                  } else if (weekly < keep_weekly && day >= strftime("%d", systime() - 86400*30)) {
                    weekly++;
                  } else if (monthly < keep_monthly && month >= strftime("%m", systime() - 86400*365)) {
                    monthly++;
                  } else if (yearly < keep_yearly) {
                    yearly++;
                  } else {
                    system("rm -f " $0);
                  }
                }'
          '';
      };
    };

    systemd.timers.rsync-prune-logs = {
      description = "Prune old rsync backup logs periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
