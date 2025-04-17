backupScript = ''
  #!/bin/bash
  set -eo pipefail  # NOTE: no -u

  SRC="${cfg.srcDir:-/var/lib}"
  BCKP="${cfg.targetDir:-/backup}"

  DAILYP="daily"
  WEEKLYP="weekly"
  MONTHLYP="monthly"
  LOGSP="logs"
  LAST="last"

  DAILY=${cfg.retention.daily:-3}
  WEEKLY=${cfg.retention.weekly:-2}
  MONTHLY=${cfg.retention.monthly:-3}

  mkdir -p "$BCKP/$DAILYP" "$BCKP/$WEEKLYP" "$BCKP/$MONTHLYP" "$BCKP/$LOGSP"

  NAME=$(date +%Y-%m-%d_%H-%M)
  LOG="$BCKP/$LOGSP/$NAME.log"

  TODAY_COUNT=$(find "$BCKP/$DAILYP" -mindepth 1 -maxdepth 1 -type d -ctime -1 2>/dev/null | wc -l || echo 0)

  if [ "$TODAY_COUNT" -gt 0 ]; then
    echo "Backup already run today, exiting." >> "$LOG"
    exit 0
  fi

  if [ -d "$BCKP/$LAST" ]; then
    LINK="--link-dest=$BCKP/$LAST"
  else
    LINK=""
  fi

  echo "Running rsync at $(date)" >> "$LOG"
  rsync -aAXiH ${includes} --include='*/' --exclude='*' $LINK "$SRC/" "$BCKP/$DAILYP/$NAME/" >> "$LOG" 2>&1 || {
    echo "rsync failed with exit code $?" >> "$LOG"
  }

  ln -snf "$BCKP/$DAILYP/$NAME" "$BCKP/$LAST"

  remove_old() {
    local dir="$1"
    local keep="$2"
    mapfile -t OLD <<< "$(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -n | head -n -"$keep" | awk '{print $2}')"
    for path in "''${OLD[@]}"; do
      echo "Removing old backup: $path" >> "$LOG"
      rm -rf "$path"
    done
  }

  promote_if_needed() {
    local target="$1"
    local source="$2"
    local age="$3"
    local keep="$4"

    local recent
    recent=$(find "$target" -mindepth 1 -maxdepth 1 -type d -ctime -"$age" | wc -l)

    if [ "$recent" -eq 0 ]; then
      local oldest
      oldest=$(find "$source" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -n | head -n 1 | awk '{print $2}')
      if [ -n "$oldest" ] && [ -d "$oldest" ]; then
        echo "Promoting $oldest to $target" >> "$LOG"
        mv "$oldest" "$target/"
      fi
    fi

    remove_old "$target" "$keep"
  }

  promote_if_needed "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" "$MONTH" "$MONTHLY"
  promote_if_needed "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" "$WEEK" "$WEEKLY"
  remove_old "$BCKP/$DAILYP" "$DAILY"
'';
