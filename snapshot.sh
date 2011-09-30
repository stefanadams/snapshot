#!/bin/sh

end () {
    rm -f /var/run/snapshot/$CODE/$SERVER.pid
    if [ "$1" == "ok" ]; then exit 0
    elif [ "$1" == "partial" ]; then exit 1
    elif [ "$1" == "err" ]; then exit 2
    elif [ "$1" == "fail" ]; then exit 3
    else exit 255
    fi
}

[ ! -e /backup/snapshots ] && { echo Snapshots not configured on this machine.; exit; }

unset OS MONITOR DAYS KEEP CODE SERVER STORE DATE LASTRUN

if [ "$2" ]; then
    CODE="$1"
    SERVER="$2"
elif [ "$1" ]; then
    declare -a SPLIT
    SPLIT=(`echo ${1//\// }`);
    CODE=${SPLIT[0]};
    SERVER=${SPLIT[1]};
fi
if [ -z "$CODE" -o -z "$SERVER" ]; then
    echo Usage: $FUNCNAME Code server
    exit
fi

# Read configurations
[ -e /backup/snapshots/.config ] && . /backup/snapshots/.config
[ -e /backup/snapshots/$CODE/.config ] && . /backup/snapshots/$CODE/.config
[ -e /backup/snapshots/$CODE/$SERVER/.config ] && . /backup/snapshots/$CODE/$SERVER/.config

# Check running user, partitions, disk space, and acls
if [ -z "$NOPARTCHECK" ]; then
    case "$-" in
        *i*)
            if ! /bin/df /backup/snapshots | grep -q /backup/snapshots >/dev/null; then
                unset yn
                echo -n "For the safety of your system, it's recommended that the snapshots get their own partition.  Check /backup for its own partition? [Y/n] "; read yn;
                [ "$yn" != "n" -a "$yn" != "N" ] || exit;
                if ! /bin/df /backup | grep -q /backup >/dev/null; then
                    /bin/df -h
                    unset yn
                    echo -n "For the safety of your system, it's recommended that the snapshots get their own partition.  Proceed anyway? [y/N] "; read yn;
                    [ "$yn" != "y" -a "$yn" != "Y" ] && exit;
                fi
            fi ;;
        *) echo "For the safety of your system, it's recommended that the snapshots get their own partition."; exit;;
    esac
fi
if [ "$MINFREE" ]; then
    FREE=$(/bin/df -P /backup/snapshots | tail -1 | awk '{print $4}')
    if [ "$FREE" -lt "$MINFREE" ]; then
        echo "Only $FREE bytes free, minimum $MINFREE bytes free requested.  Aborting."
        exit
    fi
fi
if [ -z "$NOACLCHECK" ]; then
    if ! mount | grep $(/bin/df -P /backup/snapshots/ | tail -1 | cut -f1 -d' ') | grep -q acl; then
        echo "It is recommended that you backup extended ACLs but the partition storing the backups does not support ACLs.  Enable? [Y/n] "; read yn;
        [ "$yn" != "n" -a "$yn" != "N" ] || exit;
        mount -o remount,acl $(/bin/df -P /backup/snapshots/ | tail -1 | cut -f1 -d' ')
        if ! mount | grep $(/bin/df -P /backup/snapshots/ | tail -1 | cut -f1 -d' ') | grep -q acl; then
            echo "Tried enabling ACL support on the backup data partition but failed.  Continue anyway? [y/N] "; read yn;
            [ "$yn" != "y" -a "$yn" != "Y" ] && exit;
        fi
    fi
fi

DATE=$(date +"%Y%m%d%H:%M:%S")
STORE=/backup/snapshots/$CODE/$SERVER/$DATE
mkdir -p $STORE

# Minimum minutes between snapshots
[ -e $STORE/../latest ] && MYLASTRUN=$(readlink $STORE/../latest | sed -e 's#^.*\([0-9]\{8\}\)\([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*#\1 \2#')
MYLASTRUN=$((($(date +%s)-$(date -d "$MYLASTRUN" +%s))/60))
[ -z "$MYLASTRUN" ] && MYLASTRUN=$((($(date +%s)-$(date -d "19700101 00:00:00" +%s))/60))
[ $MYLASTRUN -lt ${LASTRUN:-60} ] && { echo Snapshot for $CODE:$SERVER last run less than ${LASTRUN:-60} minutes ago.; exit; }

[ ! -e /var/run/snapshot ] && mkdir -p /var/run/snapshot
[ ! -e /var/run/snapshot/$CODE ] && mkdir -p /var/run/snapshot/$CODE
[ -e /var/run/snapshot/$CODE/$SERVER.pid ] && { echo Already running for $CODE:$SERVER.; exit; }
echo $$ > /var/run/snapshot/$CODE/$SERVER.pid

# Remove archives greater than DAYS days old as long as there will remain at least KEEP archives less than X days old
echo Removing empty archives and archives older than ${DAYS:-14} days but keeping at least ${KEEP:-7} non-empty archives...
find $STORE/.. -maxdepth 1 -type d -mmin +1 -empty -delete
RECENT=$(find $STORE/.. -mindepth 1 -maxdepth 1 -type d ! -name ".*" -mtime -$((${DAYS:-14}-1)) | wc -l)
[ "$RECENT" -gt "${KEEP:-7}" ] && find $STORE/.. -mindepth 1 -maxdepth 1 -type d ! -name ".*" -mtime +${DAYS:-14} -exec rm -rf '{}' \; -print

# Take the snapshot!
echo Taking snapshot of $CODE:$SERVER...
if [ -z "$OS" ] && ssh -qq -n -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no Administrator@$SERVER 'test -e /cygdrive'; then
    rsync -e "ssh -l Administrator" -vazqhPF --stats --timeout 300 --delete --delete-excluded --log-file=$STORE.log --link-dest=$STORE/../latest $SERVER:/ $STORE
else
    rsync -e ssh -vazqhAXPF --stats --timeout 300 --delete --delete-excluded --log-file=$STORE.log --exclude /backup/snapshots --exclude /dev --exclude /proc --exclude /sys --link-dest=$STORE/../latest $SERVER:/ $STORE
fi
ret=$?
if [ "$ret" -eq 0 ]; then
    echo "+ Success, updating latest"
    mv $STORE.log $STORE/../$DATE-ok-$ret.log
    mv $STORE $STORE/../$DATE-ok-$ret
    rm -i -f $STORE-ok-$ret/../latest $STORE-ok-$ret/../latest.log
    ln -s $STORE-ok-$ret.log $STORE-ok-$ret/../latest.log
    ln -s $STORE-ok-$ret $STORE-ok-$ret/../latest
    end ok
elif [ "$ret" -eq 23 -o "$ret" -eq 24 ]; then
    echo "+ Success with some transfer errors, updating latest"
    mv $STORE.log $STORE/../$DATE-warn-$ret.log
    mv $STORE $STORE/../$DATE-warn-$ret
    rm -i -f $STORE-warn-$ret/../latest $STORE-warn-$ret/../latest.log
    ln -s $STORE-warn-$ret.log $STORE-warn-$ret/../latest.log
    ln -s $STORE-warn-$ret $STORE-warn-$ret/../latest
    end partial
elif [ "$ret" -eq 6 -o "$ret" -eq 20 -o "$ret" -eq 25 -o "$ret" -eq 30 -o "$ret" -eq 130 ]; then
    echo "  NOT updating latest but keeping archive -- Error: $ret"
    mv $STORE.log $STORE/../$DATE-err-$ret.log
    mv $STORE $STORE/../$DATE-err-$ret
    end err
else
    echo "- NOT updating latest and dumping archive -- Error: $ret"
    rm -rf $STORE
    end fail
fi
