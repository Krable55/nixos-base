{ config, pkgs, lib, ... }:

{
  options.backup = {
    srcDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib";
      description = "Directory to back up from.";
    };
    retention = {
      daily = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of daily backups to keep.";
      };
      weekly = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Number of weekly backups to keep.";
      };
      monthly = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Number of monthly backups to keep.";
      };
    };
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable rsync-based backup service with snapshot retention.";
    };

    includeDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of directories under /var/lib to include in backup.";
    };

    targetDir = lib.mkOption {
      type = lib.types.path;
      description = "Backup target directory (e.g., NFS mount or external disk).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd timer interval for the backup job.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log";
      description = "Directory where backup logs are written.";
    };
  };

  config = lib.mkIf config.backup.enable {
    environment.etc."rsync-backup.sh".text =
      let
        includes = builtins.concatStringsSep "\n" (map (name: "--include=${name}") config.backup.includeDirs);
        logDir = toString config.backup.logDir;
        backupTarget = toString config.backup.targetDir;
      in
        ''
        #!/bin/bash
        set -euo pipefail

        SRC="${toString config.backup.srcDir}"
        BCKP="${backupTarget}"
        INCLUDE=(${builtins.concatStringsSep " " config.backup.includeDirs})

        WEEK=7
        MONTH=30
        DAILY=${toString config.backup.retention.daily}
        WEEKLY=${toString config.backup.retention.weekly}
        MONTHLY=${toString config.backup.retention.monthly}

        MANUALP="manual"
        DAILYP="daily"
        WEEKLYP="weekly"
        MONTHLYP="monthly"
        LOGSP="logs"

        remove() {
          COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
          while [ $COUNT -gt $2 ]; do
            OLDEST=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
            echo "Too many backups ($COUNT > $2) in $1" >> "$LOG"
            echo "Removing $OLDEST" >> "$LOG"
            rm -r --interactive=never "$OLDEST" >> "$LOG"
            COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
          done
        }

        move_and_remove() {
          NEWFILES=()
          COUNT=0
          while IFS=  read -r -d $'\0'; do
            NEWFILES+=("$REPLY")
            ((COUNT+=1))
          done < <(find "$1" -maxdepth 1 -mindepth 1 -type d -ctime -$3 -printf "%p\0")

          if [ $COUNT -eq 0 ]; then
            OLDEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
            if [ ! -z "$OLDEST" ]; then
              echo "No recent backup in $1. Moving $OLDEST from $2" >> "$LOG"
              mv "$OLDEST" "$1" >> "$LOG"
            fi
          fi

          remove "$1" $4
        }

        for d in "$MANUALP" "$DAILYP" "$WEEKLYP" "$MONTHLYP" "$LOGSP"; do
          mkdir -p "$BCKP/$d"
        done

        if [ "$1" != "" ]; then
          FOLDER="$MANUALP"
          NAME="$1"
        else
          FOLDER="$DAILYP"
          TODAY=$(find "$BCKP/$FOLDER" -maxdepth 1 -mindepth 1 -type d -ctime -1 -printf "a" | wc -c)
          if [ $TODAY -gt 0 ]; then
            echo "Backup already performed in last 24h. Exiting."
            exit 0
          fi
          NAME=$(date +%Y-%m-%d_%H-%M)
        fi

        LOG="$BCKP/$LOGSP/$NAME.log"

        if [ "$2" != "" ]; then
          LAST="$2"
        else
          LAST="last"
        fi

        if [ -e "$BCKP/$LAST" ]; then
          LINK="--link-dest=$BCKP/$LAST/"
        else
          LINK=""
        fi

        INCLUDE_ARGS=("${config.backup.includeDirs}" "--include=*/" "--exclude=*")

        echo "Running rsync..." >> "$LOG"
        rsync -aAXiH ${includes} --include='*/' --exclude='*' $LINK "$SRC/" "$BCKP/$FOLDER/$NAME/" >> "$LOG" 2>&1 || echo "rsync failed" >> "$LOG"

        if [ -L "$BCKP/$LAST" ]; then
          echo "Removing old symlink $BCKP/$LAST" >> "$LOG"
          rm -f "$BCKP/$LAST"
        fi

        ln -s "$BCKP/$FOLDER/$NAME" "$BCKP/$LAST" 2>>"$LOG"

        move_and_remove "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" $MONTH $MONTHLY
        move_and_remove "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" $WEEK $WEEKLY
        remove "$BCKP/$DAILYP" $DAILY
        '';

    systemd.tmpfiles.rules = [
      "d ${config.backup.logDir} 0755 root root -"
    ];

    systemd.services.rsync-backup = {
      description = "Rsync Backup Job";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/etc/rsync-backup.sh";
      };
    };

    systemd.timers.rsync-backup = {
      description = "Run rsync backup periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = config.backup.interval;
        Persistent = true;
      };
    };
  };
}
