#!/bin/bash

## dailybak - daily backup utility - 2010-2015 - willy tarreau <w@1wt.eu>
##
## Principle: sends data using rsync to the backup server, uses the last known
## backup as a reference, then updates the link to the last known backup. The
## backup logs are also archived on the remote server.
##
## Usage: dailybak -s <server> [-p <passfile>] -b <backup> -l <log> [-n <name>]
##                 [ -e <exclude> ]* [ -k <period> ]* [-P] [ -L | <fs>* ]
##
##   -s <server>  : name/address of the remote server
##   -p <passfile>: path to a file containing the server account's password
##   -b <backup>  : name of the backup module on this server
##   -l <log>     : name of the log module on this server
##   -n <name>    : use this name as local host name for backups
##   -e <exclude> : pattern to exclude (may appear multiple times)
##   -k [dur:cnt] : add a conservation rule to only keep <cnt> backups over the
##                  next <dur> days past the previous period, eg 2/wk, 1/mo,
##                  1/q, 1/yr, 2/3yr : -k 7:2 -k 24:1 -k 60:1 -k 275:1 -k 730:2
##   -P           : purge instead of just listing outdated backups with -k
##   -L           : only list all backups existing on the remote server
##   <fs>         : absolute path to directories to backup. A "." in the middle
##                  will mark the relative path (see man rsync -R).

# Storage format :
#   - <remote>::<backup>/<host>/<date>
#     contains all the data. <date> may be replaced with "LAST" which is a
#     symlink to the latest successful backup.
#     The date uses format <YYYYMMDD-HHMMSS>. A similar name followed by
#     "-OK" will also be created as a symlink to this one if the backup
#     succeeded.
#   - <remote>::<log>/<host>
#     contains all the log files

PASSFILE=
REMOTE=
BACKUP=
BACKPFX=
EXCLUDE=( )
LOG=
TEMP=
HOST="$(hostname)"
SCRIPT="$0"
TMPDIR="${TMPDIR:-/tmp}"
LIST_ONLY=
PERIODS=( )
PURGE=

# list of good and bad backup dirs, with their respective age in days
GOOD_DIR=( )
GOOD_AGE=( )
BAD_DIR=( )
BAD_AGE=( )

# list of all backups in the form of [ <dir> <age> "SUCCESS"|"FAILURE" ]
ALL_BK=( )

die() {
	echo "Fatal: $*"
	exit 1
}

# displays an optional message followed by the calling syntax, then exits. If a
# message was passed, the exit status is non-zero as it's assumed to be an error
# message.
usage() {
	[ $# -eq 0 ] || echo "$*"
	grep "^##" "$SCRIPT" | cut -c4-
	[ $# -eq 0 ]
	exit $?
}

# creates a temporary directory and returns it in TEMP, does nothing
# if TEMP was already created.
mktemp() {
	[ -z "$TEMP" ] || return 0
	TEMP="$TMPDIR/${SCRIPT##*/}.$$.$RANDOM"
	while ! mkdir -m 0700 "$TEMP"; do
		TEMP="$TMPDIR/${SCRIPT##*/}.$$.$RANDOM"
	done
}

# removes a possibly existing temporary directory and unsets TEMP
deltemp() {
	[ -z "$TEMP" ] || rm -rf "$TEMP"
	TEMP=
}

# fills {GOOD|BAD}_{DIR|AGE}[] and ALL_BK[] with the list, age and statuses of
# the backups found on the server.
check_existing() {
	local bk now age
	local list=( )
	local last=""

	# resets a possible previously established list
	GOOD_DIR=( ); GOOD_AGE=( ); BAD_DIR=( ); BAD_AGE=( ); ALL_BK=( )

	# builds a list of all dated backups dirs, with failed links placed
	# immediately after the directory name. Also ignore dead links.

	list=( $(set -o pipefail; \
	         rsync --no-h --list-only ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/" | \
	         cut -c44- | grep '^[0-9]' | sort)
	     )
	[ $? = 0 ] || return $?

	now=$(date +%s)
	for bk in "${list[@]}" ""; do
		if [ -n "$last" ]; then
			# convert to "YYYYMMDD-HHMMSS" to "YYYYMMDD HH:MM:SS", then to days,
			# rounded up by 0.5 day. Failed conversions keep an age of zero.
			if age=$(date +%s -d "${last:0:8} ${last:9:2}:${last:11:2}:${last:13:2}" 2>/dev/null); then
				age=$(((now - age + 43200) / 86400))
			else
				age=0
			fi
		fi

		if [ -n "$bk" -a -z "${bk##*-OK}" ]; then
			if [ -n "$last" -a "$last" = "${bk%-OK}" ]; then
				GOOD_DIR[${#GOOD_DIR[@]}]="$last"
				GOOD_AGE[${#GOOD_AGE[@]}]="$age"
				ALL_BK[${#ALL_BK[@]}]="$last $age SUCCESS"
			fi
			last=""
		else
			if [ -n "$last" ]; then
				BAD_DIR[${#BAD_DIR[@]}]="$last"
				BAD_AGE[${#BAD_AGE[@]}]="$age"
				ALL_BK[${#ALL_BK[@]}]="$last $age FAILURE"
			fi
			last="$bk"
		fi
	done
	return 0
}

# creates the target directory and log file. Returns 0 on success otherwise
# non-zero.
prepare_backup() {
	echo "###### $(date) : Creating ${HOST} on $REMOTE::$BACKUP ######"
	mkdir -p "${TEMP}/${HOST}" || return 1
	rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/" || return 1

	echo "###### $(date) : Creating ${HOST} on $REMOTE::$LOG ######"
	rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$LOG/" || return 1

	echo "###### $(date) : Creating ${HOST}/${DATE} on $REMOTE::$BACKUP ######"
	mkdir -p "${TEMP}/${HOST}/${DATE}" || return 1
	rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}/${DATE}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/" || return 1

	echo "###### $(date) : Preparation done ######"
}

# performs a complete backup of the requested fslist. Returns 0 on success
# otherwise non-zero. Note: a failure to upload the log file is not counted as
# a backup failure.
perform_backup() {
	local ret ret2

	echo "###### $(date) : Saving (${FSLIST[@]}) to $REMOTE::$BACKUP ######"

	# compute the exclude args (--exclude foo --exclude bar ...). We start by
	# excluding the temporary directory in order not to save our log file.
	EXCLARG=( --exclude "${TEMP}/" )
	for excl in "${EXCLUDE[@]}"; do
		EXCLARG[${#excl[@]}]="--exclude"
		EXCLARG[${#excl[@]}]="$excl"
	done

	rsync --log-file="$TEMP/backup-$HOST-$DATE.log" -x -vaSHR --stats \
	      "${EXCLARG[@]}" --link-dest="${BACKPFX}/${HOST}/LAST/" \
	      "${FSLIST[@]}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/${DATE}/"
	ret=$?
	ret2=$ret
	echo "return code: $ret" >> "$TEMP/backup-$HOST-$DATE.log"
	echo "###### $(date) : done ret=$ret ######"

	echo "###### $(date) : Uploading the log file to $REMOTE::$LOG ######"
	rsync -x -vaSH --no-R --stats "$TEMP"/backup-*.log ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$LOG/${HOST}/"
	ret=$?
	echo "###### $(date) : done ret=$ret ######"

	# in case of success, update LAST to point to the current backup
	if [ $ret2 -ne 0 ]; then
		echo "###### $(date) : Errors found (ret2=$ret2), NOT updating the LAST link on $REMOTE::$BACKUP ######"
		return $ret2
	fi

	echo "###### $(date) : Updating the LAST link and adding the OK link on $REMOTE::$BACKUP ######"
	ln -sf "$DATE" "$TEMP/LAST"
	ln -sf "$DATE" "$TEMP/${DATE}-OK"
	rsync -x --delete -vaSH --no-R --stats "${TEMP}/LAST" "${TEMP}/${DATE}-OK" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
	ret=$?
	echo "###### $(date) : LAST done (ret=$ret) ######"
	return 0
}

# Deletes (or only reports a backup) to be deleted in $2 with good
# or bad backup status in $1 ("good" or "bad") and optional age in
# $3.
delete_backup() {
	if [ -n "$PURGE" ]; then
		# in order to purge, we upload an empty dir over the one we
		# want to kill. The trick is to use '/***' to remove the dir
		# contents as well as the entry. For the symlink, we upload
		# the empty dir over the link itself.
		mktemp
		mkdir -p "$TEMP/empty" || return 1

		if [ "$1" = "good" ]; then
			echo "Deleting successful backup $2 (age $3 days)"
			rsync -r --delete --include "/$2/***" --exclude='*' "$TEMP/empty/" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
			rsync -r --delete --include "/$2-OK" --exclude='*' "$TEMP/empty/" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
		elif [ "$1" = "bad" ]; then
			echo "Deleting failed backup $2 (age $3 days)"
			rsync -r --delete --include "/$2/***" --exclude='*' "$TEMP/empty/" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
		fi
	else
		if [ "$1" = "good" ]; then
			echo "Would delete successful backup $2 (age $3 days)"
		elif [ "$1" = "bad" ]; then
			echo "Would delete failed backup $2 (age $3 days)"
		fi
	fi
}

# Evaluates what entries to kill inside a period. $1 is the oldest date to
# study. $2 is the first one *not* studied. $3 is the max number of
# entries to keep within that period. $4 indicates what was found in the
# previous period :
#   0 = period is empty
#   1 = period contains only failed backups
#   2 = period contains at least one good backup
#   3 = period contains all expected full backups
#
# The same value is returned so that it can be passed to compute the next
# period. The fact that the incompleteness of the last period was covered
# is also accounted for.
#
# Successful backups and failed backups are kept using the same algorithm,
# except that successful ones are always considered first and that failed
# backups are only considered as a complement for successful ones so that
# they are always removed after there are enough remaining total backups
# left.
purge_period() {
	local from=$1 to=$2 max=$3 last=$4
	local good=0 bad=0 back

	back=$((${#GOOD_AGE[@]} - 1))
	while [ $back -ge 0 ] && [ ${GOOD_AGE[back]} -le $from ]; do
		if [ ${GOOD_AGE[back]} -ge $to ]; then
			((good++))
		fi
		((back--));
	done

	back=$((${#BAD_AGE[@]} - 1))
	while [ $back -ge 0 ] && [ ${BAD_AGE[back]} -le $from ]; do
		[ ${BAD_AGE[back]} -lt $to ] || ((bad++))
		((back--));
	done

	# remove extra good entries from the lastest ones to the oldest ones
	back=$((${#GOOD_AGE[@]} - 1))
	while [ $back -ge 0 -a $good -gt $max ] && [ ${GOOD_AGE[back]} -le $from ]; do
		if [ ${GOOD_AGE[back]} -ge $to ]; then
			if [ $last -ge 3 ]; then
				delete_backup good "${GOOD_DIR[back]}" "${GOOD_AGE[back]}"
			else
				last=3
			fi
			((good--))
		fi
		((back--));
	done

	# now remove remaining failed backups if not needed. They're counted
	# like successful ones in order to plug holes.
	back=$((${#BAD_AGE[@]} - 1))
	while [ $back -ge 0 -a $((good + bad)) -gt $max ] && [ ${BAD_AGE[back]} -le $from ]; do
		if [ ${BAD_AGE[back]} -ge $to ]; then
			if [ $last -ge 1 ]; then
				delete_backup bad "${BAD_DIR[back]}" "${BAD_AGE[back]}"
			else
				last=1
			fi
			((bad--))
		fi
		((back--));
	done

	[ $good -ge $((max + (last < 3))) ] && return 3
	[ $good -gt 0 ] && return 2
	[ $bad -ge $((max + (last < 1))) ] && return 1
	return 0
}

# Iterates over all conservation periods from most recent to oldest and runs
# the purge with the appropriate arguments. Each period is known as <days:cnt>
# where <days> is the number of days after the previous period, and <cnt> is
# the max number of entries to keep. For example, the four following periods :
#
#   <7:2> <31:1> <91:1> <366:1>
#
# will have for effect to keep 2 backups over the last 7 days, 1 over the
# last 8..38 days, 1 over the last 39..130 days, 1 over the last 130..495
# days. The following periods will keep one backup over the last week, 1
# over the last month, one over the last quarter and one over the last year :
#
#   <7:1> <24:1> <60:1> <275:1>
#
# There's an implicit closing period starting after the last one with cnt=0
# to flush whatever older is found (68 years back, ~= 2^31 seconds).
# The current day's backup is always kept.
#
purge_old() {
	local from to cnt last
	local period

	# Consider today's backup to know how to start
	if [ ${#GOOD_AGE[@]} -gt 0 ] && [ ${GOOD_AGE[${#GOOD_AGE[@]}-1]} -eq 0 ]; then
		# good backup for today
		last=3
	elif [ ${#BAD_AGE[@]} -gt 0 ] && [ ${BAD_AGE[${#BAD_AGE[@]}-1]} -eq 0 ]; then
		# failed backup for today
		last=1
	else
		# no backup for today
		last=0
	fi

	from=0
	for period in ${PERIODS[@]} ""; do
		to=$((from + 1))
		from=24837; cnt=0
		if [ -n "$period" ]; then
			from=$((${period%:*} + to - 1))
			cnt="${period##*:}"
		fi
		purge_period "$from" "$to" "$cnt" "$last"
		last=$?
	done
	return 0
}

#
# MAIN entry point
#
while [ -n "$1" -a -z "${1##-*}" ]; do
	case "$1" in
		"-s") REMOTE="$2" ; shift ;;
		"-p") PASSFILE="$2" ; shift ;;
		"-b") BACKUP="$2" ; shift ;;
		"-l") LOG="$2" ; shift ;;
		"-e") EXCLUDE[${#EXCLUDE[@]}]="$2" ; shift ;;
		"-k") if [ -z "$2" -o -n "${2##*:*}" ]; then
			      usage "Fatal: Invalid period '$2', must be <days:count>."
		      fi
		      PERIODS[${#PERIODS[@]}]="$2" ;
		      shift ;;
		"-n") HOST="$2" ; shift ;;
		"-h"|"--help") usage ;;
		"-L") LIST_ONLY=1 ;;
		"-P") PURGE=1 ;;
		"--") shift ; break ;;
		*) usage "Fatal: Unknown argument : '$1'" ;;
	esac
	shift
done

if [ -z "$HOST" ]; then
	usage "Fatal: Unknown local hostname. Force it with '-n'."
fi

if [ -z "$REMOTE" -o -z "$BACKUP" ]; then
	usage "Fatal: Both remote and backup must be specified."
fi

FSLIST=( "$@" )

if [ -z "$LIST_ONLY" -a ${#FSLIST[@]} -eq 0 -a ${#PERIODS[@]} -eq 0 ]; then
	usage "Fatal: Nothing to do!"
fi

# if the remote backup contains a slash, everything that follows the first "/"
# is a directory prefix.
if [ -z "${BACKUP##*/*}" ]; then
	BACKPFX="${BACKUP#*/}"
	BACKPFX="/${BACKPFX%/}"
else
	BACKPFX="/"
fi

DATE="$(date +%Y%m%d-%H%M%S)"

if [ -n "$LIST_ONLY" ]; then
	check_existing || exit $?
	(echo "Directory_name  Age Status"
	 echo "--------------- --- -------"
	 for i in "${ALL_BK[@]}"; do
		echo $i
	 done) | column -t
	exit 0
fi

ret=0
if [ ${#FSLIST[@]} -gt 0 ]; then
	if [ -z "$LOG" ]; then
		usage "Fatal: The log module must be specified (-l)."
	fi

	for fs in "${FSLIST[@]}"; do
		[ -e "$fs" ] || die "FS <$fs> doesn't exist".
		if [ "$fs" = "/" -o "${fs%/}" = "/var" -o "${fs%/}" = "/usr" \
		     -o "${fs%/}" = "/etc" -o "${fs%/}" = "/root" \
		     -o "${fs%/}" = "/home" -o "${fs%/}" = "/opt" \
		     -o "${fs%/}" = "/boot" ] && [ "$(id -u)" != "0" ]; then
			die "Saving $fs requires to be run by root."
		fi
	done

	mktemp

	prepare_backup && perform_backup
	ret=$?

	if [ $ret -eq 0 ]; then
		echo "###### $(date) : Backup complete, removing temp dir $TEMP ######"
	else
		echo "###### $(date) : NOT removing temp dir $TEMP ######"
	fi
fi

# take care of old backups purge if needed
if [ ${#PERIODS[@]} -gt 0 ]; then
	check_existing || exit $?
	purge_old
fi

# only remove the temporary directory if there was no backup error
[ $ret -ne 0 ] || deltemp
exit $ret
