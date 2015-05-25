#!/bin/bash

## dailybak - daily backup utility - 2010-2015 - willy tarreau <w@1wt.eu>
##
## Principle: sends data using rsync to the backup server, uses the last known
## backup as a reference, then updates the link to the last known backup. The
## backup logs are also archived on the remote server.
##
## Usage: dailybak -s <server> -b <backup> -l <log> [ -n <name> ]
##                 [ -e <exclude> ]* <fs>*
##
##   -s <server>  : name/address of the remote server
##   -b <backup>  : name of the backup module on this server
##   -l <log>     : name of the log module on this server
##   -n <name>    : use this name as local host name for backups
##   -e <exclude> : pattern to exclude (may appear multiple times)
##   <fs>         : directories to backup. The root must be named "rootfs" and
##                  not "/" so that the name appears correctly as a directory
##                  name on the backup server.

# Storage format :
#   - <remote>::<backup>/<host>/<date>
#     contains all the data. <date> may be replaced with "LAST" which is a
#     symlink to the latest successful backup.
#   - <remote>::<log>/<host>
#     contains all the log files

REMOTE=
BACKUP=
LOG=
TEMP=
HOST="$(hostname)"
SCRIPT="$0"
TMPDIR="${TMPDIR:-/tmp}"

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

mktemp() {
	TEMP="$TMPDIR/${SCRIPT##*/}.$$.$RANDOM"
	while ! mkdir -m 0700 "$TEMP"; do
		TEMP="$TMPDIR/${SCRIPT##*/}.$$.$RANDOM"
	done
}

deltemp() {
	[ -z "$TEMP" ] || rm -rf "$TEMP"
}

while [ -n "$1" -a -z "${1##-*}" ]; do
	case "$1" in
		"-s") REMOTE="$2" ; shift ;;
		"-b") BACKUP="$2" ; shift ;;
		"-l") LOG="$2" ; shift ;;
		"-e") EXCLUDE[${#EXCLUDE[@]}]="$2" ; shift ;;
		"-n") HOST="$2" ; shift ;;
		"-h"|"--help") usage ;;
		"--") shift ; break ;;
		*) usage "Unknown argument : '$1'" ;;
	esac
	shift
done

if [ -z "$HOST" ]; then
	usage "Unknown local hostname. Force it with '-n'."
fi

if [ -z "$REMOTE" -o -z "$BACKUP" -o -z "$LOG" ]; then
	usage "All of remote, backup and log must be specified."
fi

if [ $# -eq 0 ]; then
	usage "Nothing to do!"
fi

DATE="$(date +%Y%m%d-%H%M%S)"

mktemp

# compute the exclude args (-e foo -e bar ...)
EXCLARG=( )
for excl in "${EXCLUDE[@]}"; do
	EXCLARG[${#excl[@]}]="-e"
	EXCLARG[${#excl[@]}]="$excl"
done

FSLIST=( "$@" )

echo "###### $(date) : Creating ${HOST} on $REMOTE::$BACKUP ######"
mkdir -p "${TEMP}/${HOST}" || die
rsync -x -vaSH --stats "${TEMP}/${HOST}" "$REMOTE::$BACKUP/" || die

echo "###### $(date) : Creating ${HOST} on $REMOTE::$LOG ######"
rsync -x -vaSH --stats "${TEMP}/${HOST}" "$REMOTE::$LOG/" || die

echo "###### $(date) : Creating ${HOST}/${DATE} on $REMOTE::$BACKUP ######"
mkdir -p "${TEMP}/${HOST}/${DATE}" || die
rsync -x -vaSH --stats "${TEMP}/${HOST}/${DATE}" "$REMOTE::$BACKUP/${HOST}/"

echo "###### $(date) : Preparation done, starting backup now ######"

ret2=0
for fs in "${FSLIST[@]}"; do
	# src="" for rootfs
	src="${fs#rootfs}"
	src="${src%/}"
	dst="${fs#/}"
	dst="${dst//\//.}"

	echo "###### $(date) : Saving $fs to $REMOTE::$BACKUP ######"

	rsync --log-file="$TEMP/backup-$HOST-$DATE-${dst//\//.}.log" -x -vaSH --stats \
	      "${EXCLARG[@]}" --link-dest="/${HOST}/LAST/${dst}" \
	      "${src}/" "$REMOTE::$BACKUP/${HOST}/${DATE}/${dst}"

	ret=$?
	[ $ret2 -eq 0 ] && ret2=$ret
	echo "return code: $ret (since start of backup: $ret2)" >> \
	     "$TEMP/backup-$HOST-$DATE-${dst//\//.}.log"

	echo "###### $(date) : $fs done (ret=$ret, final=$ret2) ######"
done

rsync -x -vaSH --stats "$TEMP"/backup-*.log "$REMOTE::$LOG/${HOST}/"

# in case of success, update LAST to point to the current backup
if [ $ret2 -eq 0 ]; then
	echo "###### $(date) : Updating the LAST link on $REMOTE::$BACKUP ######"
	ln -sf "$DATE" "$TEMP/LAST"
	rsync -x --delete -vaSH --stats "${TEMP}/LAST" "$REMOTE::$BACKUP/${HOST}/"
	ret=$?
	echo "###### $(date) : LAST done (ret=$ret) ######"
	echo "###### $(date) : Backup complete, removing temp dir $TEMP ######"
else
	echo "###### $(date) : Errors found (ret2=$ret2), NOT updating the LAST link on $REMOTE::$BACKUP ######"
	echo "###### $(date) : NOT removing temp dir $TEMP ######"
fi

exit $ret2
