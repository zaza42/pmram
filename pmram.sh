#!/bin/sh
#
# PMram v1.1
# Use palemoon in ramdisk with syncing
#

syncinterval=30  # sync every XX seconds
libs=true         # copy all dependencies to ramfs
sqlshrink=true    # shrink *.sqlite files before start pm
gstreamer=true    # copy all dependencies for audio/video playing
gstreamdirs="/usr/lib/x86_64-linux-gnu/gstreamer-1.0 /usr/lib/i386-linux-gnu/gstreamer-1.0"
pmdirs="$HOME/local/palemoon /usr/lib/palemoon /opt/palemoon"
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
rsync="$rsyncbin -L -a --info=name"
$rsyncbin --drop-cache 2>&1|grep -q unknown\ option \
    && echo "W: it's better to use \`drop-cache\` patch for rsync" \
    || rsync="$rsync --drop-cache"
# progress
progress=cat
which pv >/dev/null && progress="pv -l -i 0.1" \
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
    mount $ramdir || error "create \"$ramdir\" folder and add this line to /etc/fstab:
ramfs		$ramdir	ramfs	user,exec,mode=770,noauto	0 0"
}

pmcopy() {
    for pmdir in $pmdirs; do
	[ -f "$pmdir/palemoon" ] && break
    done
    [ ! -d "$pmdir" ] && error "Pale Moon not found in dirs: $pmdirs"
    echo copying palemoon from "$pmdir"
    fn=$(find "$pmdir" ! -path $pmdir/dictionaries/'*' ! -name dictionaries|wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync --delete --exclude dictionaries \
    --exclude removed-files --exclude distribution \
    --exclude hyphenation \
    "$pmdir"/* pm/ | $progress $sfn >/dev/null
}
omniunzip() {
    echo unzipping omni.ja
    fn=$(unzip -l pm/omni.ja 2>/dev/null)
    fn=${fn% files}
    fn=${fn##* }
    [ "$progress" = cat ] || sfn="-s $fn"
    unzip -o pm/omni.ja -d pm/ 2>/dev/null | $progress $sfn >/dev/null
    rm -f pm/omni.ja
}
libcopy() {
    echo -n copying libs
    mkdir libs
    lib=""
    deplibs=$(ldd $ramdir/pm/*.so|grep '=>'|grep -v "not found"|cut -d" " -f3|sort -u)
    du=$(du -Lch $deplibs|tail -n1|expand)
    echo " (${du%% *})"
    fn=$(echo "$deplibs"|wc -l)
    [ ! "$progress" = cat ] && sfn="-s $fn"
    $rsync $deplibs libs/ 2>/dev/null | $progress $sfn > /dev/null
    ldlibpath=$ramdir/libs
}

gstreamcopy() {
    for gstreamdir in $gstreamdirs; do
	[ -f "$gstreamdir/libgstcoreelements.so" ] && break
    done
    [ ! -d "$gstreamdir" ] && error "gstreamer not found in dirs: $gstreamdirs"
    echo -n copying gstreamer libs from $gstreamdir
    du=$(du -sh "$gstreamdir"|expand)
    echo " (${du%% *})"
    fn=$(find "$gstreamdir" | wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync "$gstreamdir"/ gstreamer/ 2>/dev/null | $progress $sfn > /dev/null
    echo -n resolving gstreamer dependencies...
    deplibs=$(LD_LIBRARY_PATH=$ldlibpath:$LD_LIBRARY_PATH \
	ldd gstreamer/*|grep '=>'|grep -v -e $ramdir -e "not found" \
	|cut -d" " -f3|sort -u)
    du=$(du -Lch $deplibs|tail -n1|expand)
    echo "copying (${du%% *})"
    fn=$(echo "$deplibs"|wc -l)
    [ ! "$progress" = cat ] && sfn="-s $((fn-1))"
    $rsync $deplibs libs/ 2>/dev/null | $progress $sfn > /dev/null
    export GST_PLUGIN_SYSTEM_PATH=$ramdir/gstreamer/
    export GST_PLUGIN_SYSTEM_PATH_1_0=$ramdir/gstreamer/
    export GST_PLUGIN_PATH=$ramdir/gstreamer/
    export GST_REGISTRY=$ramdir/gst10reg.bin
    export GST_REGISTRY_1_0=$ramdir/gst10reg.bin
    echo -n generating gstreamer registry...
    LD_LIBRARY_PATH=$ldlibpath:$LD_LIBRARY_PATH gst-inspect-1.0 >/dev/null
    echo done
    export GST_REGISTRY_FORK=no
    export GST_REGISTRY_UPDATE=no
}

profilecopy() {
    profile=$(ls -1 "$defprof"/|grep -m1 default$)
    [ -z "$profile" ] && error "User profile not found at "$defprof"" \
	|| profdir="$defprof"/$profile
    echo "Copying profile from $profdir"
    fn=$(find "$profdir" | wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync --delete --exclude thirdparties --exclude webappsstore.sqlite \
	--exclude cache "$profdir"/ profile | $progress $sfn >/dev/null
    if [ "$(ls profile/extensions/*xpi 2>/dev/null)" ]; then
	echo -n Unzipping plugins
	for plugin in profile/extensions/*xpi; do
	    [ -f "$plugin" ] || continue
	    echo -n .
	    dirname=${plugin%.xpi}
	    unzip "$plugin" -d "$dirname" >/dev/null && rm -f "$plugin"
	done
	echo done
    fi
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
    $ionice nice -n10 $rsync --delete --exclude webappsstore.sqlite \
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
    LD_LIBRARY_PATH=$ldlibpath:$LD_LIBRARY_PATH \
    $ramdir/pm/palemoon --profile $ramdir/profile $1 &
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
fuser -km $ramdir/ >/dev/null 2>&1
umount $ramdir
wait
echo done
