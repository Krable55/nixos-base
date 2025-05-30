#!/bin/bash

set -euo pipefail

# === Functions ===

remove () {
  COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
  while [ $COUNT -gt "$2" ]; do
    OLDEST=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
    echo "Too many backups ($COUNT > $2) in $1" >> "$LOG"
    echo "Removing: $OLDEST" >> "$LOG"
    rm -r --interactive=never "$OLDEST" >> "$LOG"
    COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
  done
}

move_and_remove () {
  NEWFILES=()
  COUNT=0
  while IFS= read -r -d $'\0'; do
    NEWFILES+=("$REPLY")
    ((COUNT+=1))
  done < <(find "$1" -maxdepth 1 -mindepth 1 -type d -ctime -"$3" -printf "%p\0")

  if [ $COUNT -eq 0 ]; then
    OLDEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
    if [ -n "${OLDEST:-}" ]; then
      echo "Moving $OLDEST from $2 to $1" >> "$LOG"
      mv "$OLDEST" "$1" >> "$LOG"
    fi
  fi

  remove "$1" "$4"
}

# === Defaults & Config ===

SRC="${SRC:-/}"
BCKP="${BCKP:-/var/lib}"
DAILY="${DAILY:-3}"
WEEKLY="${WEEKLY:-2}"
MONTHLY="${MONTHLY:-3}"
DRY_RUN="${DRY_RUN:-false}"
INCLUDE="${INCLUDE:-}"

# Parse INCLUDE from environment safely
INCLUDE_RAW="${INCLUDE:-}"
IFS=' ' read -r -a INCLUDE_PATHS <<< "$INCLUDE_RAW"

# Period definitions
WEEK=7
MONTH=30

# Folder layout
MANUALP="manual"
DAILYP="daily"
WEEKLYP="weekly"
MONTHLYP="monthly"
LOGSP="logs"

# Load /etc and user config if present
[ -f "/etc/nmbckp/vars" ] && . "/etc/nmbckp/vars"
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  [ -f "$XDG_CONFIG_HOME/nmbckp/vars" ] && . "$XDG_CONFIG_HOME/nmbckp/vars"
else
  [ -f "$HOME/.config/nmbckp/vars" ] && . "$HOME/.config/nmbckp/vars"
fi

# Ensure backup directories exist
for d in "$MANUALP" "$DAILYP" "$WEEKLYP" "$MONTHLYP" "$LOGSP"; do
  mkdir -p "$BCKP/$d"
done

# Determine backup name
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

# Determine link-dest
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

# rsync options
OPTS="-aAXiH --numeric-ids --prune-empty-dirs"
[[ "$DRY_RUN" == "true" ]] && OPTS="$OPTS --dry-run"

# Build include/exclude rules
INCLUDE_FLAGS=()
if [ "${#INCLUDE_PATHS[@]}" -gt 0 ]; then
  for path in "${INCLUDE_PATHS[@]}"; do
    INCLUDE_FLAGS+=( "--include=/$path/***" )
  done
  INCLUDE_FLAGS+=( "--include=*/" "--exclude=*" )
  echo "Parsed INCLUDE paths: ${INCLUDE_PATHS[*]}" >> "$LOG"
else
  echo "Warning: No INCLUDE paths specified. Backup may be empty." >> "$LOG"
fi


# Run rsync
echo "Running rsync: rsync $OPTS ${INCLUDE_FLAGS[*]} $LINK $SRC/ $BCKP/$FOLDER/$NAME/" >> "$LOG"
rsync $OPTS "${INCLUDE_FLAGS[@]}" $LINK "$SRC/" "$BCKP/$FOLDER/$NAME/" >> "$LOG"

# Update latest symlink
if [ -L "$BCKP/$LAST" ]; then
  echo "Removing old symlink $BCKP/$LAST" >> "$LOG"
  rm -f "$BCKP/$LAST"
fi

ln -s "$BCKP/$FOLDER/$NAME" "$BCKP/$LAST" || echo "Failed to create symlink." >> "$LOG"

# Promote + Rotate
move_and_remove "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" "$MONTH" "$MONTHLY"
move_and_remove "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" "$WEEK" "$WEEKLY"
remove "$BCKP/$DAILYP" "$DAILY"

# Link latest
LATESTDIR=""
for DIR in "$FOLDER" "$MONTHLYP" "$WEEKLYP"; do
  if [ -e "$BCKP/$DIR/$NAME" ]; then
    LATESTDIR="$BCKP/$DIR/$NAME"
    break
  fi
done

if [ -z "$LATESTDIR" ] && [ -n "${2:-}" ]; then
  NEWEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -zr | grep -zom 1 ".*" | sed 's/[^ ]* //')
  LATESTDIR="$NEWEST"
fi

if [ -n "${LATESTDIR:-}" ]; then
  ln -sf "$LATESTDIR" "$BCKP/last"
  echo "Symlink to latest backup: $LATESTDIR" >> "$LOG"
fi

# === Archive all but the latest ===
BACKUP_DIR="$BCKP/$FOLDER"
LAST_REALPATH=$(readlink -f "$BCKP/last")

echo "Archiving old backups in $BACKUP_DIR (excluding $LAST_REALPATH)" >> "$LOG"

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
  dir_real=$(readlink -f "$dir")
  if [[ "$dir_real" != "$LAST_REALPATH" ]]; then
    tarball="$dir.tar.gz"
    if [ -d "$dir" ] && [ ! -f "$dir.tar.gz" ]; then
     echo "Compressing $dir → $dir.tar.gz" >> "$LOG"
     tar -czf "$dir.tar.gz" -C "$(dirname "$dir")" "$(basename "$dir")" && rm -rf "$dir"
    fi
  fi
done
