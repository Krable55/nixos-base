#!/bin/bash

set -euo pipefail

# Two functions to handle automatic backup directories
remove () {
  COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
  while [ $COUNT -gt $2 ]; do
    OLDEST=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
    echo "Too many backups ($COUNT > $2) in $1" >> "$LOG"
    echo "Running: rm -r --interactive=never $OLDEST" >> "$LOG"
    rm -r --interactive=never "$OLDEST" >> "$LOG"
    COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
  done
}

move_and_remove () {
  NEWFILES=()
  COUNT=0
  while IFS=  read -r -d $'\0'; do
    NEWFILES+=("$REPLY")
    ((COUNT+=1))
  done < <(find "$1" -maxdepth 1 -mindepth 1 -type d -ctime -$3 -printf "%p\0")

  if [ $COUNT -eq 0 ]; then
    OLDEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
    if [ ! -z $OLDEST ]; then
      echo "Moving $OLDEST from $2 to $1" >> "$LOG"
      mv "$OLDEST" "$1" >> "$LOG"
    fi
  fi
  remove "$1" $4
}

# Set defaults (can be overridden via env)
SRC="${SRC:-/}"
BCKP="${BCKP:-/media/data/backup}"
DAILY="${DAILY:-3}"
WEEKLY="${WEEKLY:-2}"
MONTHLY="${MONTHLY:-3}"
INCLUDE=()

# Load INCLUDE from environment (space-separated string → array)
[ -n "${INCLUDE:-}" ] && IFS=' ' read -r -a INCLUDE <<< "$INCLUDE"

# Relative backup folders
MANUALP="manual"
DAILYP="daily"
WEEKLYP="weekly"
MONTHLYP="monthly"
LOGSP="logs"

# Load user/system config files if present
[ -f "/etc/nmbckp/vars" ] && . "/etc/nmbckp/vars"
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  [ -f "$XDG_CONFIG_HOME/nmbckp/vars" ] && . "$XDG_CONFIG_HOME/nmbckp/vars"
else
  [ -f "$HOME/.config/nmbckp/vars" ] && . "$HOME/.config/nmbckp/vars"
fi

# Ensure backup subdirs exist
for d in "$MANUALP" "$DAILYP" "$WEEKLYP" "$MONTHLYP" "$LOGSP"; do
  mkdir -p "$BCKP/$d"
done

# Determine archive name and folder type
if [ -n "${1:-}" ]; then
  FOLDER="$MANUALP"
  NAME="$1"
else
  FOLDER="$DAILYP"
  TODAY=$(find "$BCKP/$FOLDER" -maxdepth 1 -mindepth 1 -type d -ctime -1 -printf "a" | wc -c)
  if [ "$TODAY" -gt 0 ]; then
    echo "Backup already performed in last 24h. Exiting."
    exit 0
  fi
  NAME=$(date +%Y-%m-%d_%H-%M)
fi

LOG="$BCKP/$LOGSP/$NAME.log"

# Determine previous backup link
if [ -n "${2:-}" ]; then
  LAST="$2"
else
  LAST="last"
fi

if [ -e "$BCKP/$LAST" ]; then
  LINK="--link-dest=$BCKP/$LAST/"
else
  LINK="--"
fi

OPTS="-aAXiH"
INCLUDES=( "${INCLUDE[@]/#/--include=}" )

# Add final catch-all exclude to skip everything else
INCLUDES+=( "--include=*/" "--exclude=*" )

# Run rsync
echo "Running: rsync $OPTS ${INCLUDES[*]} $LINK $SRC $BCKP/$FOLDER/$NAME/" >> "$LOG"
rsync $OPTS "${INCLUDES[@]}" $LINK "$SRC" "$BCKP/$FOLDER/$NAME/" >> "$LOG" || echo "rsync failed" >> "$LOG"

# Update symlink
[ -L "$BCKP/$LAST" ] && rm -f "$BCKP/$LAST"
ln -s "$BCKP/$FOLDER/$NAME" "$BCKP/$LAST" 2>>"$LOG"

# Promote and rotate backups
move_and_remove "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" "$MONTH" "$MONTHLY"
move_and_remove "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" "$WEEK" "$WEEKLY"
remove "$BCKP/$DAILYP" "$DAILY"
