#!/bin/sh
#
# PMram v1.0
# Use palemoon in ramdisk with syncing
#

syncinterval=360  # sync every XX seconds
libs=true         # copy all dependencies to ramfs
sqlshrink=true    # shrink *.sqlite files before start pm
gstreamer=true    # copy all dependencies for audio/video playing
gstreamdir="/usr/lib/i386-linux-gnu/gstreamer-1.0"
pmdirs="$HOME/local/palemoon /usr/lib/palemoon"
defprof="$HOME/.moonchild productions/pale moon"
ramdir=/mnt/pmram


##########################
# Initializing functions #
##########################

error() { echo "E: $@" ; umount $ramdir 2>/dev/null; exit 1; }

filescheck() {
# rsync compiled with drop-cache is much better
rsyncbin=$(which rsync)
[ -z "$rsyncbin" ] && error "\`rsync\` not found"
rsync=$rsyncbin
$rsyncbin --drop-cache 2>&1|grep -q unknown\ option \
    && echo "W: it's better to use \`drop-cache\` patch for rsync" \
    || rsync="$rsyncbin --drop-cache"
# progress
progress=cat
which pv >/dev/null && progress="pv -l -i 0.1 -w40"  \
    || echo "W: install \`pv\` for progress bars"
#ionice
which ionice >/dev/null && ionice="ionice -c3" \
    || echo "W: install \`ionice\` for smoother background syncing"
#sqlite
if $sqlite; then
    sqlite=$(which sqlite3)
    [ -z "$sqlite" ] && echo "W: install \`sqlite3\` for compacting files"
fi
if $gstreamer; then
    gstinspect=$(which gst-inspect-1.0)
    [ -z "$gstinspect" ] && echo "W: install \`gstreamer1.0-tools\` for audio/video playing from ramfs"
fi
}

ramdirmount() {
    [ ! "`grep $ramdir\  /proc/mounts`" = "" ] && (umount $ramdir || error "$ramdir is busy")
    mount $ramdir || error "create \"/mnt/pmram\" folder add this line to /etc/fstab:
ramfs		$ramdir	ramfs	user,exec,mode=770,noauto	0 0"
}

pmcopy() {
    for dir in $pmdirs; do
	[ -f "$dir/palemoon" ] && pmdir="$dir" && break
    done
    [ -z "$pmdir" ] && error "Pale Moon not found in dirs: $pmdirs"
    echo copying palemoon from "$pmdir"
    $rsync -avHPx --delete --exclude dictionaries \
    --exclude removed-files --exclude distribution \
    --exclude hyphenation \
    "$pmdir"/* pm/ | $progress >/dev/null
}
omniunzip() {
    echo unzipping omni.ja
    unzip -o pm/omni.ja -d pm/ 2>/dev/null | $progress >/dev/null
    rm -f pm/omni.ja
}
libcopy() {
    echo copying libs
    mkdir libs
    lib=""
    deplibs=$(ldd $ramdir/pm/libxul.so |grep -v -e "not found" -e linux-gate.so \
        | while read -r line;do
	    l=${line% *}
	    echo ${l##* }
        done )
    $rsync -avHP -L $deplibs libs/ 2>/dev/null | $progress > /dev/null
    ldlibpath=$ramdir/libs
}

gstreamcopy() {
    echo copying gstreamer libs
    $rsync -avHP -L "$gstreamdir"/ gstreamer/ 2>/dev/null | $progress > /dev/null
    deplibs=$(ldd gstreamer/*|grep '=>'|grep -v $ramdir|cut -d" " -f3|sort -u)
    $rsync -avHP -L $deplibs libs/ 2>/dev/null | $progress > /dev/null
    export GST_PLUGIN_SYSTEM_PATH=$ramdir/gstreamer/
    export GST_PLUGIN_SYSTEM_PATH_1_0=$ramdir/gstreamer/
    export GST_PLUGIN_PATH=$ramdir/gstreamer/
    export GST_REGISTRY=$ramdir/gst10reg.bin
    export GST_REGISTRY_1_0=$ramdir/gst10reg.bin
    echo -n generating gstreamer registry...
    gst-inspect-1.0 >/dev/null
    echo done
    GST_REGISTRY_FORK=no
    GST_REGISTRY_UPDATE=no
}

profilecopy() {
    profile=$(ls -1 "$defprof"/|grep -m1 default$)
    [ -z "$profile" ] && error "User profile not found at "$defprof"" \
	|| profdir="$defprof"/$profile
    echo "Copying profile from $profdir"
    $rsync -avHPx --delete --exclude thirdparties --exclude webappsstore.sqlite \
	--exclude cache "$profdir"/ profile | $progress >/dev/null
    echo -n Unzipping plugins
    for plugin in profile/extensions/*xpi; do
	[ -f "$plugin" ] || continue
	echo -n .
	dirname=${plugin%.xpi}
	unzip "$plugin" -d "$dirname" >/dev/null && rm -f "$plugin"
    done
    echo done
}
sqlshrink() {
    echo -n Shrinking sqlite files
    for f in profile/*.sqlite; do
	echo -n .
	$sqlite "$f" 'VACUUM;'
	$sqlite "$f" 'reindex;'
    done
    echo done
}

pmsync() {
if  [ "$1" = "force" ] || [ $ramdir/profile/places.sqlite -nt "$profdir"/places.sqlite ] ; then
    $ionice nice -n10 $rsync -avHPx --delete --exclude webappsstore.sqlite \
	--exclude indexedDB --exclude thirdparties --exclude cache \
	$ramdir/profile/ "$profdir"/ 2>/dev/null | xargs -I {} echo -n .
fi
}

############
# Let's go #
############

# Open new tab if already running
if [ -f $ramdir/pm/palemoon ] && [ $(pgrep -f $ramdir/pm/palemoon) ] ; then
    exec $ramdir/pm/palemoon "$1"
fi
# Don't run as 2nd instance
pidof palemoon >/dev/null && error "another Pale Moon is already running!"

starttime=$(date +%s)
filescheck
ramdirmount
cd $ramdir
pmcopy
[ -f pm/omni.ja ] && omniunzip
[ "$libs" = true ] && libcopy
[ "$gstinspect" ] && gstreamcopy
profilecopy
[ "$sqlite" ] && sqlshrink
mkdir cache
export XDG_CACHE_HOME=$ramdir/cache
cd "$OLDPWD"
ramdu=$(du -sh $ramdir)
echo Using ${ramdu%%/*} as ramdisk "(generated in $(( $(date +%s) - $starttime )) seconds)"

echo Starting Pale Moon and syncing in every $syncinterval seconds
TMPDIR=/dev/shm/ TEMP=/dev/shm/ TMP=/dev/shm/ \
    LD_LIBRARY_PATH=$ldlibpath $ramdir/pm/palemoon --profile $ramdir/profile $1 &
#syncing profile in background
(while :;do
    sleep $syncinterval
    echo -n $(date "+%F %R") syncing profile
    pmsync
    echo done
done) &
jobs
trap "kill -9 $!;killall palemoon" HUP INT TERM
wait %1
kill -9 $!

echo "Pale Moon has stopped."
echo -n "Syncing and cleaning up"
pmsync force
fuser -km /mnt/pmram/libs/ >/dev/null 2>&1
umount $ramdir
wait
echo done
