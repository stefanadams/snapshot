#!/bin/sh

snapshot () {
    [ ! -e /backup/snapshots ] && { echo Snapshots not configured on this machine.; return; }

    unset OS MONITOR DAYS KEEP CODE SERVER STORE DATE

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
        return
    fi

    # Read configurations
    [ -e /backup/snapshots/.config ] && . /backup/snapshots/.config
    [ -e /backup/snapshots/$CODE/.config ] && . /backup/snapshots/$CODE/.config
    [ -e /backup/snapshots/$CODE/$SERVER/.config ] && . /backup/snapshots/$CODE/$SERVER/.config

    # Check partitions and disk space
    if [ -z "$NOPARTCHECK" ]; then
        case "$-" in
            *i*)
                if ! /bin/df /backup/snapshots | grep -q /backup/snapshots >/dev/null; then
                    unset yn
                    echo -n "For the safety of your system, it's recommended that the snapshots get their own partition.  Check /backup for its own partition? [Y/n] "; read yn;
                    [ "$yn" != "n" -a "$yn" != "N" ] || return;
                    if ! /bin/df /backup | grep -q /backup >/dev/null; then
                        /bin/df -h
                        unset yn
                        echo -n "For the safety of your system, it's recommended that the snapshots get their own partition.  Proceed anyway? [y/N] "; read yn;
                        [ "$yn" != "y" -a "$yn" != "Y" ] && return;
                    fi
                fi ;;
            *) echo "For the safety of your system, it's recommended that the snapshots get their own partition."; return ;;
        esac
    fi
    if [ "$MINFREE" ]; then
        FREE=$(/bin/df -P /backup/snapshots | tail -1 | awk '{print $4}')
        if [ "$FREE" -lt "$MINFREE" ]; then
            echo "Only $FREE bytes free, minimum $MINFREE bytes free requested.  Aborting."
            return
        fi
    fi

    # Detect Windows
    if [ -z "$OS" ]; then
        echo -n Detecting Windows on $SERVER...
        ssh -o PasswordAuthentication=no Administrator@$SERVER 'test -e /cygdrive' 2>&1 > /dev/null && OS=W
        if [ "$OS" == "W" ]; then echo Yes; else echo No; fi
    fi

    DATE=$(date +"%Y%m%d%H:%M:%S")
    STORE=/backup/snapshots/$CODE/$SERVER/$DATE;
    mkdir -p $STORE;

    [ -e /var/run/snapshot.pid ] && { echo Already running.; return; }
    echo $$ > /var/run/snapshot.pid

    # Remove archives greater than DAYS days old as long as there will remain at least KEEP archives less than X days old
    echo Removing archives older than ${DAYS:-14} days but keeping at least ${KEEP:-7} archives...
    RECENT=$(find $STORE/.. -mindepth 1 -maxdepth 1 -type d ! -name ".*" -mtime -$((${DAYS:-14}-1)) | wc -l)
    [ "$RECENT" -gt "${KEEP:-7}" ] && find $STORE/.. -mindepth 1 -maxdepth 1 -type d ! -name ".*" -mtime +${DAYS:-14} -exec rm -rf '{}' \; -print

    if [ "$OS" == "W" ]; then
        rsync -e "ssh -l Administrator" -vaziPF --stats --timeout 3600 --delete --delete-excluded --exclude /backup/snapshots --exclude /proc --exclude /sys --link-dest=$STORE/../latest $SERVER:/ $STORE
    else
        rsync -e ssh -vaziAPF --stats --timeout 3600 --delete --delete-excluded --exclude /backup/snapshots --exclude /proc --exclude /sys --link-dest=$STORE/../latest $SERVER:/ $STORE
    fi
    err=$?
    if [ "$err" -eq 0 ]; then
        echo Success, updating latest;
        rm -i -f $STORE/../latest;
        ln -s $STORE $STORE/../latest
    elif [ "$err" -eq 23 -o "$err" -eq 24 ]; then
        echo Success with some transfer errors, updating latest;
        rm -i -f $STORE/../latest;
        ln -s $STORE $STORE/../latest
    elif [ "$err" -eq 6 -o "$err" -eq 20 -o "$err" -eq 25 -o "$err" -eq 30]; then
        echo NOT updating latest but keeping archive -- Error: $err
        mv $STORE $STORE/../$DATE-err-$err
    else
        echo NOT updating latest and dumping archive -- Error: $err
        rm -rf $STORE
    fi
    if [ "$MONITOR" ]; then
        echo curl -s -S "http://www.cogentinnovators.com/cenitor.cgi/snapshot?code=$CODE&server=$SERVER&date=$DATE&end="$(date +"%Y%m%d%H:%M:%S")"&err=$err"
    fi

    rm -f /var/run/snapshot.pid
}

snapshot "$@"
