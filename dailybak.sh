#!/bin/bash

## dailybak - daily backup utility - 2010-2015 - willy tarreau <w@1wt.eu>
##
## Principle: sends data using rsync to the backup server, uses the last known
## backup as a reference, then updates the link to the last known backup. The
## backup logs are also archived on the remote server.
##
## Usage: dailybak -s <server> [-p <passfile>] -b <backup> -l <log> [-n <name>]
##                 [ -e <exclude> ]* [ -L | <fs>* ]
##
##   -s <server>  : name/address of the remote server
##   -p <passfile>: path to a file containing the server account's password
##   -b <backup>  : name of the backup module on this server
##   -l <log>     : name of the log module on this server
##   -n <name>    : use this name as local host name for backups
##   -e <exclude> : pattern to exclude (may appear multiple times)
##   -L           : only list backups existing on the remote server
##   <fs>         : absolute path to directories to backup. A "." in the middle
##                  will mark the relative path (see man rsync -R).

# Storage format :
#   - <remote>::<backup>/<host>/<date>
#     contains all the data. <date> may be replaced with "LAST" which is a
#     symlink to the latest successful backup.
#     The date uses format <YYYYMMDD-HHMMSS>. A similar name followed by
#     "-FAILED" may also be created as a symlink to this one if the backup
#     failed.
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
		"-p") PASSFILE="$2" ; shift ;;
		"-b") BACKUP="$2" ; shift ;;
		"-l") LOG="$2" ; shift ;;
		"-e") EXCLUDE[${#EXCLUDE[@]}]="$2" ; shift ;;
		"-n") HOST="$2" ; shift ;;
		"-h"|"--help") usage ;;
		"-L") LIST_ONLY=1 ;;
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
	rsync --no-h --list-only ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
	exit $?
fi

if [ -z "$LOG" ]; then
	usage "Fatal: The log module must be specified (-l)."
fi

if [ $# -eq 0 ]; then
	usage "Fatal: Nothing to do!"
fi

mktemp

# compute the exclude args (--exclude foo --exclude bar ...). We start by
# excluding the temporary directory in order not to save our log file.
EXCLARG=( --exclude "${TEMP}/" )
for excl in "${EXCLUDE[@]}"; do
	EXCLARG[${#excl[@]}]="--exclude"
	EXCLARG[${#excl[@]}]="$excl"
done

FSLIST=( "$@" )

for fs in "${FSLIST[@]}"; do
	[ -e "$fs" ] || die "FS <$fs> doesn't exist".
done

echo "###### $(date) : Creating ${HOST} on $REMOTE::$BACKUP ######"
mkdir -p "${TEMP}/${HOST}" || die
rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/" || die

echo "###### $(date) : Creating ${HOST} on $REMOTE::$LOG ######"
rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$LOG/" || die

echo "###### $(date) : Creating ${HOST}/${DATE} on $REMOTE::$BACKUP ######"
mkdir -p "${TEMP}/${HOST}/${DATE}" || die
rsync -x -vaSH --stats --no-R "${TEMP}/${HOST}/${DATE}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"

echo "###### $(date) : Preparation done, starting backup now ######"


echo "###### $(date) : Saving (${FSLIST[@]}) to $REMOTE::$BACKUP ######"
rsync --log-file="$TEMP/backup-$HOST-$DATE.log" -x -vaSHR --stats \
	"${EXCLARG[@]}" --link-dest="${BACKPFX}/${HOST}/LAST/" \
	"${FSLIST[@]}" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/${DATE}/"
ret=$?
ret2=$ret
echo "return code: $ret" >> "$TEMP/backup-$HOST-$DATE.log"
echo "###### $(date) : done ret=$ret ######"

rsync -x -vaSH --no-R --stats "$TEMP"/backup-*.log ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$LOG/${HOST}/"

# in case of success, update LAST to point to the current backup
if [ $ret2 -eq 0 ]; then
	echo "###### $(date) : Updating the LAST link on $REMOTE::$BACKUP ######"
	ln -sf "$DATE" "$TEMP/LAST"
	rsync -x --delete -vaSH --no-R --stats "${TEMP}/LAST" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
	ret=$?
	echo "###### $(date) : LAST done (ret=$ret) ######"
	echo "###### $(date) : Backup complete, removing temp dir $TEMP ######"
	rm -rf "$TEMP"
else
	ln -sf "$DATE" "$TEMP/${DATE}-FAILED"
	rsync -x --delete -vaSH --no-R --stats "${TEMP}/${DATE}-FAILED" ${PASSFILE:+--password-file "$PASSFILE"} "$REMOTE::$BACKUP/${HOST}/"
	ret=$?
	echo "###### $(date) : Errors found (ret2=$ret2), NOT updating the LAST link on $REMOTE::$BACKUP ######"
	echo "###### $(date) : NOT removing temp dir $TEMP ######"
fi

exit $ret2
