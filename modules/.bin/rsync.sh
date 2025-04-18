#!/bin/bash

set -euo pipefail

# Two functions to handle automatic backup directories
remove () {
  # This function checks if there are too many backups in the directory. If yes, it deletes the oldest one.
	# $1: directory $2: maximum number of backups

	# Count the number of backups in the directory
	COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)

	# find -printf "a": for every directory/file found prints an a character
	# wc -c: counts the number of characters
	
	# if we have more backups than the max number, delete the oldest one
	while [ $COUNT -gt $2 ]; do
		OLDEST=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
		echo "Too many backups ($COUNT > $2) in $1" >> "$LOG"
		echo "Running: rm -r --interactive=never $OLDEST" >> "$LOG"
		rm -r --interactive=never "$OLDEST" >> "$LOG"
		# echo "$OLDEST" -r
		COUNT=$(find "$1" -maxdepth 1 -mindepth 1 -type d -printf "a" | wc -c)
	done
}

move_and_remove () {
	# This function checks if the youngest backup in the primary folder too old, and if yes, moves the oldest from the
	# secondary folder here, than checks if there are too many backups, and if yes, deletes the oldest.
	# $1: primary directory $2: secondary directory (no trailing slash!)
	# $3: the max age of youngest backup in days in primary directory
	# $4: the maximum number of backups in the primary directory
	
	# We count the number of backups that are younger than the limit
	NEWFILES=()
	COUNT=0
	while IFS=  read -r -d $'\0'; do
		NEWFILES+=("$REPLY")
		((COUNT+=1))
	done < <(find "$1" -maxdepth 1 -mindepth 1 -type d -ctime -$3 -printf "%p\0")
	# https://stackoverflow.com/questions/16085958/find-the-files-that-have-been-changed-in-last-24-hours
	# https://stackoverflow.com/questions/23356779/how-can-i-store-the-find-command-results-as-an-array-in-bash#23357277
	
	# read
	#  -r: backslash characters treated as characters
	#  -d $'\0': the input is null-separated
	#  $REPLY: the default variable the read command reads into
	# find
	#  -maxdepth 1 -mindepth 1: only the directories right inside backup
	#  -type d: only directories
	#  -ctime: only files modified in the previous n days (negative number)
	#  -printf "%p\0": lists the filenames with zero termination

	# echo ${NEWFILES[@]}
	# echo $COUNT
	
	# If there is no backup younger than the limit, we move the oldest from the secondary directory
	if [ $COUNT -eq 0 ]; then
		OLDEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -z | grep -zom 1 ".*" | sed 's/[^ ]* //')
		if [ ! -z $OLDEST ]; then
			echo "There is no backup younger than $3 in $1. Moving the oldest backup from $2." >> "$LOG"
			echo "Running: mv $OLDEST $1" >> "$LOG"
			mv "$OLDEST" "$1" >> "$LOG"
			#echo "$OLDEST" "$1"
		fi
	fi
	
	# https://superuser.com/questions/552600/how-can-i-find-the-oldest-file-in-a-directory-tree
		
	# find
	#  -printf "%C+ %p\0": list the last status change date and directory names listed with null character separation
	# sort -z: reads from a zero terminated list
	# grep
	#  -z: zero terminated list
	#  -o: only prints the matching part, not the whole line
	#  -m 1: stop reading after 1 line
	# sed 's/[^ ]* //'
	#  's' scrpt: replace string: 's/regexp/replacement/flags'
	#  regexp: [^ ]: starts with anything but space
	#          *: any character string (or nothing)
	#           : an ending space
	
	# Remove the oldest backup if we have too many
	remove $1 $4
}


# Set defaults (can be overridden via env)
SRC="${SRC:-/}"
BCKP="${BCKP:-/var/lib}"
DAILY="${DAILY:-3}"
WEEKLY="${WEEKLY:-2}"
MONTHLY="${MONTHLY:-3}"
INCLUDE=()

# Load INCLUDE from environment (space-separated string → array)
[ -n "${INCLUDE:-}" ] && IFS=' ' read -r -a INCLUDE <<< "$INCLUDE"

# we define the lengths calendar periods and the number of backups to keep
WEEK=7		# a week is seven days
MONTH=30	# a month is 30 days
DAILY=3		# we keep 3 daily backups
WEEKLY=2	# we keep 2 weekly backups
MONTHLY=3	# we keep 3 monthly backups

# Relative backup folders
MANUALP="manual"
DAILYP="daily"
WEEKLYP="weekly"
MONTHLYP="monthly"
LOGSP="logs"

# we source the file in /etc/nmbckp/vars so the system administrator's variables
# are loaded.
[ -f "/etc/nmbckp/vars" ] && . "/etc/nmbckp/vars" 

# we source the files in the user's config directory to get the custom setup.
# the user's custom variables should be set up in the file "vars" in
# their $XDG_CONFIG_HOME/nmbckp directory, or if that is not specified, in their
# Load user/system config files if present
[ -f "/etc/nmbckp/vars" ] && . "/etc/nmbckp/vars"
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  [ -f "$XDG_CONFIG_HOME/nmbckp/vars" ] && . "$XDG_CONFIG_HOME/nmbckp/vars"
else
  [ -f "$HOME/.config/nmbckp/vars" ] && . "$HOME/.config/nmbckp/vars"
fi

# we check if the required folders exist, if not, we create them
for TESTDIR in "$MANUALP" "$DAILYP" "$WEEKLYP" "$MONTHLYP" "$LOGSP"; do
	if [ ! -d "$BCKP/$TESTDIR" ]; then
		mkdir "$BCKP/$TESTDIR"
	fi
done

# If the script is called with a parameter, that will be used as the archive name,
# otherwise the current date and time will be used.
if [ -n "${1:-}" ]; then
	FOLDER="$MANUALP"
	NAME="$1"
else
	FOLDER="$DAILYP"
	TODAY=$(find "$BCKP/$FOLDER" -maxdepth 1 -mindepth 1 -type d -ctime -1 -printf "a" | wc -c)
	if [ $TODAY -gt 0 ]; then
		echo "Backup already performed in the last 24 hours. Exiting..."
		exit 0
	fi
	NAME=$(date +%Y-%m-%d_%H-%M)
fi

LOG="$BCKP/$LOGSP/$NAME.log"

# If the script is called with a second parameter, that will be the directory to
# compare to, otherwise the defalut will be used.
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

# -a: rlptgoD
# -r: recursive copy
# -l: preserve symlinks
# -pt: preserve permissions and times
# -go: preserve group and owner
# -D: preserves special devices as is
# -A: preserves ACLs
# -X: preserve extended attributes
# -i: output change summary
# -H: keep hard links as hard links
OPTS="-aAXiH" 

# we check if there is a anything to link to and if there is, we use it as a linked reference
if [ -e "$BCKP/$LAST" ]; then
	LINK="--link-dest=$BCKP/$LAST/"
else
	LINK="--" 	# If I leave this empty, then when calling the rsnyc operation,
			# it would be passed as an empty source parameter between quotes,
			# resulting in copying the files not just from target but from the
			# current directory.
fi

# Shell array populated from $INCLUDE (space-separated)
IFS=' ' read -r -a INCLUDE_PATHS <<< "$INCLUDE"

# Expand to rsync flags
INCLUDE_FLAGS=()
for path in "${INCLUDE_PATHS[@]}"; do
  INCLUDE_FLAGS+=( "--include=/$path/***" )
done

# Add directory includes and final exclude
INCLUDE_FLAGS+=( "--include=*/" "--exclude=*" )

# Run rsync
echo "Running: rsync $OPTS ${INCLUDE_FLAGS[@]} $LINK $SRC $BCKP/$FOLDER/$NAME/" >> "$LOG"
rsync $OPTS "${INCLUDE_FLAGS[@]}" $LINK "$SRC/" "$BCKP/$FOLDER/$NAME/" >> "$LOG"

# removes the link to the last one and creates a link to the new one
if [ -L "$BCKP/$LAST" ]; then
	echo "Removing symbolic link to previous backup" >> "$LOG"
	echo "Running: rm -f \"$BCKP/$LAST\"" >> "$LOG"
	rm -f "$BCKP/$LAST"
fi

# Promote and rotate backups
move_and_remove "$BCKP/$MONTHLYP" "$BCKP/$WEEKLYP" "$MONTH" "$MONTHLY"
move_and_remove "$BCKP/$WEEKLYP" "$BCKP/$DAILYP" "$WEEK" "$WEEKLY"

# create the symbolic link to the latest backup
if [ -e "$BCKP/$FOLDER/$NAME" ]; then
	LATESTDIR="$BCKP/$FOLDER/$NAME"
elif [ -e "$BCKP/$MONTHLYP/$NAME" ]; then
	LATESTDIR="$BCKP/$MONTHLYP/$NAME"
elif [ -e "$BCKP/$WEEKLYP/$NAME" ]; then
	LATESTDIR="$BCKP/$WEEKLYP/$NAME"
else
	NEWEST=$(find "$2" -maxdepth 1 -mindepth 1 -type d -printf "%C+ %p\0" | sort -zr | grep -zom 1 ".*" | sed 's/[^ ]* //')
	# sort -r: sorts in reverse order
	if [ ! -z $NEWEST ]; then
		LATESTDIR=$NEWEST
	fi
fi
if [ ! -z $LATESTDIR ]; then
	echo "Creating symbolic link to the latest backup" >> "$LOG"
	echo "Running: ln -s \"$LATESTDIR\" \"$BCKP/last\""  >> "$LOG"
	ln -s "$LATESTDIR" "$BCKP/last" || echo "An error occured while creating symbolic link." >> "$LOG"
	#ln -s: creates symbolic link
fi

remove "$BCKP/$DAILYP" "$DAILY"
