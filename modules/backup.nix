{ config, pkgs, lib, ... }:

let
  cfg = config.custom.backup;
  includes = builtins.concatStringsSep " " (map (name: "--include='${name}'") cfg.includeDirs);
  backupScript = ''
    #!/bin/bash
    set -euo pipefail

    SRC="${toString cfg.srcDir}"
    BCKP="${toString cfg.targetDir}"

    WEEK=7
    MONTH=30
    DAILY=${toString cfg.retention.daily}
    WEEKLY=${toString cfg.retention.weekly}
    MONTHLY=${toString cfg.retention.monthly}

    MANUALP="manual"
    DAILYP="daily"
    WEEKLYP="weekly"
    MONTHLYP="monthly"
    LOGSP="logs"

    for d in "$MANUALP" "$DAILYP" "$WEEKLYP" "$MONTHLYP" "$LOGSP"; do
      mkdir -p "$BCKP/$d"
    done

    if [ -n "${1:-}" ]; then
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

    if [ -n "${2:-}" ]; then
      LAST="$2"
    else
      LAST="last"
    fi

    if [ -e "$BCKP/$LAST" ]; then
      LINK="--link-dest=$BCKP/$LAST/"
    else
      LINK=""
    fi

    echo "Running rsync..." >> "$LOG"
    rsync -aAXiH ${includes} --include='*/' --exclude='*' $LINK "$SRC/" "$BCKP/$FOLDER/$NAME/" >> "$LOG" 2>&1 || echo "rsync failed" >> "$LOG"

    if [ -L "$BCKP/$LAST" ]; then
      echo "Removing old symlink $BCKP/$LAST" >> "$LOG"
      rm -f "$BCKP/$LAST"
    fi

    ln -s "$BCKP/$FOLDER/$NAME" "$BCKP/$LAST" 2>>"$LOG"

    remove() {
      COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
      while [ $COUNT -gt $2 ]; do
        OLDEST=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
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
          echo "Moving $OLDEST from $2 to $1" >> "$LOG"
          mv "$OLDEST" "$1" >> "$LOG"
        fi
      fi

      remove "$1" $4
    }

    move_and_remove "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" $MONTH $MONTHLY
    move_and_remove "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" $WEEK $WEEKLY
    remove "$BCKP/$DAILYP" $DAILY
  '';

in {
  options.custom.backup = {
    enable = lib.mkEnableOption "Enable rsync-based backup service";
    srcDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib";
      description = "Directory to back up from.";
    };
    includeDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Subdirectories to include under srcDir.";
    };
    targetDir = lib.mkOption {
      type = lib.types.path;
      description = "Target backup directory.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd timer OnCalendar interval.";
    };
    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log";
      description = "Directory where backup logs are written.";
    };
    retention = {
      daily = lib.mkOption { type = lib.types.int; default = 3; };
      weekly = lib.mkOption { type = lib.types.int; default = 2; };
      monthly = lib.mkOption { type = lib.types.int; default = 3; };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.rsync ];

    environment.etc."rsync-backup.sh" = {
      text = backupScript;
      mode = "0755";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.logDir} 0755 root root -"
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
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };
  };
}