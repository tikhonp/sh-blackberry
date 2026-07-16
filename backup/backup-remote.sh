#!/bin/sh
# Guarded rsync push of the local backup mirror to a remote fleet node.
#
# Usage: backup-remote.sh [-n] <label> <user@host>
#   -n  rsync --dry-run; also skips trash pruning. Safe for trial runs.
#
# Guards, in order:
#   lock           skip if a run for <label> is already in progress
#   source canary  abort if $BACKUP_SRC/.backup-canary is missing (HDD not mounted)
#   target canary  abort if <host>:$BACKUP_DEST/.backup-canary is missing (remote disk
#                  not mounted). One-time setup while the disk IS mounted:
#                  ssh <user@host> 'touch /data/.backup-canary'
#   deletion cap   rsync --max-delete: a run may delete at most $BACKUP_MAX_DELETE files
#   trash          deleted/overwritten files are moved (same-disk rename) to
#                  $BACKUP_DEST/.trash/<date>/ on the receiver instead of destroyed,
#                  pruned after $BACKUP_TRASH_RETENTION_DAYS days
#
# Env knobs (all optional):
#   BACKUP_MAX_DELETE (500), BACKUP_TRASH_RETENTION_DAYS (30), BACKUP_BWLIMIT (unset),
#   BACKUP_SRC (/data), BACKUP_DEST (/data)

set -u

DRY_RUN=""
if [ "${1:-}" = "-n" ]; then
    DRY_RUN=1
    shift
fi

if [ $# -ne 2 ]; then
    echo "usage: $0 [-n] <label> <user@host>" >&2
    exit 64
fi

LABEL=$1
REMOTE=$2

SRC=${BACKUP_SRC:-/data}
DEST=${BACKUP_DEST:-/data}
MAX_DELETE=${BACKUP_MAX_DELETE:-500}
RETENTION_DAYS=${BACKUP_TRASH_RETENTION_DAYS:-30}
BWLIMIT=${BACKUP_BWLIMIT:-}
CANARY=.backup-canary
TRASH=$DEST/.trash
SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o ConnectTimeout=30"
LOCK_DIR=/tmp/backup-remote-$LABEL.lock
LOCK_MAX_AGE_MIN=$((23 * 60))

log() { echo "[backup-remote:$LABEL] $*"; }
err() { echo "[backup-remote:$LABEL] $*" >&2; }

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$LOCK_MAX_AGE_MIN 2>/dev/null)" ]; then
        log "WARNING: removing stale lock $LOCK_DIR (older than ${LOCK_MAX_AGE_MIN}min)"
        rmdir "$LOCK_DIR" 2>/dev/null
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            err "CRITICAL: cannot acquire lock $LOCK_DIR"
            exit 1
        fi
    else
        log "previous run for '$LABEL' still in progress, skipping"
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
trap 'exit 1' INT TERM HUP

if [ ! -e "$SRC/$CANARY" ]; then
    err "CRITICAL: source canary $SRC/$CANARY missing — is the backup HDD mounted?"
    err "(one-time setup while it is mounted: touch $SRC/$CANARY)"
    exit 1
fi

if [ -z "$(find "$SRC" -mindepth 1 -maxdepth 1 ! -name "$CANARY" 2>/dev/null | head -n 1)" ]; then
    err "CRITICAL: source $SRC is empty — refusing to sync"
    exit 1
fi

# shellcheck disable=SC2086  # SSH_OPTS must word-split
if ! ssh $SSH_OPTS "$REMOTE" "test -e $DEST/$CANARY"; then
    err "CRITICAL: target canary $REMOTE:$DEST/$CANARY missing — is the remote backup disk mounted?"
    err "(one-time setup while it is mounted: ssh $REMOTE 'touch $DEST/$CANARY')"
    exit 1
fi

if [ -z "$DRY_RUN" ]; then
    log "pruning $REMOTE:$TRASH entries older than $RETENTION_DAYS days"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$REMOTE" "if [ -d $TRASH ]; then find $TRASH -mindepth 1 -maxdepth 1 -mtime +$RETENTION_DAYS -exec rm -rf {} \\; ; fi" \
        || log "WARNING: trash prune on $REMOTE failed, continuing"
fi

STAMP=$(date +%Y-%m-%d)
EXTRA_ARGS=""
[ -n "$BWLIMIT" ] && EXTRA_ARGS="--bwlimit=$BWLIMIT"
[ -n "$DRY_RUN" ] && EXTRA_ARGS="$EXTRA_ARGS --dry-run"

log "starting sync $SRC/ -> $REMOTE:$DEST/ (max-delete=$MAX_DELETE, trash=$TRASH/$STAMP)${DRY_RUN:+ [DRY RUN]}"
START=$(date +%s)

# shellcheck disable=SC2086  # EXTRA_ARGS must word-split
rsync -a --numeric-ids \
    --delete-delay --max-delete="$MAX_DELETE" \
    --backup --backup-dir="$TRASH/$STAMP" \
    --exclude="/.trash/" \
    --partial-dir=.rsync-partial \
    --timeout=600 --stats \
    $EXTRA_ARGS \
    -e "ssh $SSH_OPTS" \
    "$SRC/" "$REMOTE:$DEST/"
RC=$?

DURATION=$(($(date +%s) - START))

case $RC in
    0)
        log "OK: sync to $REMOTE finished in ${DURATION}s"
        ;;
    24)
        log "OK (warning): some source files vanished during transfer (rsync code 24), finished in ${DURATION}s"
        ;;
    25)
        err "CRITICAL: deletion cap hit — rsync stopped deleting after $MAX_DELETE files."
        err "Inspect what happened before doing anything else. If the deletions are legitimate"
        err "(big cleanup), raise BACKUP_MAX_DELETE in .env for one run. Nothing is lost:"
        err "displaced files are in $REMOTE:$TRASH/$STAMP"
        exit 25
        ;;
    *)
        err "ERROR: rsync to $REMOTE failed with exit code $RC after ${DURATION}s"
        exit $RC
        ;;
esac
exit 0
