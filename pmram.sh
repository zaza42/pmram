#!/bin/sh
#
# PMram v1.3
# Use palemoon in ramdisk with syncing
#

syncinterval=360  # sync every XX seconds
libs=true         # copy all dependencies to ramfs
sqlshrink=true    # shrink *.sqlite files before start pm
#gstreamer=true    # copy all dependencies for audio/video playing
#gstreamdirs="/usr/lib/x86_64-linux-gnu/gstreamer-1.0 /usr/lib/i386-linux-gnu/gstreamer-1.0"
pmdirs="$HOME/local/palemoon /usr/lib/palemoon /opt/palemoon"
defprof="$HOME/.moonchild productions/pale moon"
ramdir=/mnt/pmram
symlinklibs="/mnt/palemoon/libs"
tarfile="$defprof/pmram.tar.lz4"

##########################
# Initializing functions #
##########################

profile=$(ls -1 "$defprof"/|grep -m1 default$)
[ -z "$profile" ] && error "User profile not found at $defprof" \
    || profdir="$defprof"/$profile

for pmdir in $pmdirs; do
	[ -f "$pmdir/palemoon" ] && break
done
[ ! -d "$pmdir" ] && error "Pale Moon not found in dirs: $pmdirs"

error() { echo "E: $*" ; umount $ramdir 2>/dev/null; exit 1; }

filescheck() {
which unzip >/dev/null || error "\`unzip\` not found"
# rsync compiled with drop-cache is much better
rsyncbin=$(which rsync)
[ -z "$rsyncbin" ] && error "\`rsync\` not found"
rsync="$rsyncbin -L -a --info=name"
$rsyncbin --drop-cache 2>&1|grep -q unknown\ option \
    && echo "W: it's better to use \`drop-cache\` patch for rsync" \
    || rsync="$rsync --drop-cache"
# progress
progress=cat
which pv >/dev/null && progress="pv -lptb -w 70 -i 0.1" && progressb="pv -ptb -w 70 -i 0.1" \
    || error "E: install \`pv\` for progress bars"
#ionice
which ionice >/dev/null && ionice="ionice -c3" \
    || echo "W: install \`ionice\` for smoother background syncing"
#sqlite
if [ "$sqlshrink" = "true" ]; then
    sqlite=$(which sqlite3)
    [ -z "$sqlite" ] && echo "W: install \`sqlite3\` for compacting files"
fi
if [ "$gstreamer" = "true" ]; then
    gstinspect=$(which gst-inspect-1.0)
    [ -z "$gstinspect" ] && echo "W: install \`gstreamer1.0-tools\` for audio/video playing from ramfs"
fi
lz4bin=$(which lz4)
[ -z "$lz4bin" ] && error "\`lz4\` not found"
}

ramdirmount() {
    [ ! "`grep $ramdir\  /proc/mounts`" = "" ] && (umount $ramdir || error "$ramdir is busy")
    mount $ramdir || error "create \"$ramdir\" folder and add this line to /etc/fstab:
ramfs		$ramdir	ramfs	user,exec,mode=770,noauto	0 0"
}

pmcopy() {
    echo copy palemoon from "$pmdir"
    fn=$(find "$pmdir"/ ! -path $pmdir/dictionaries/'*' ! -name dictionaries|wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync --delete --exclude dictionaries \
    --exclude removed-files --exclude distribution \
    --exclude hyphenation \
    "$pmdir"/* pm/ | $progress $sfn >/dev/null
}
symlinklibs() {
    echo -n symlinking 3 libs to another ramdisk
    for lib in libnss3.so libnssutil3.so libssl3.so; do
	if [ -f "$symlinklibs/$lib" ]; then
	    rm -f pm/$lib
	    ln -s $symlinklibs/$lib pm/
	    echo -n .
	fi
    done
    echo done
}
omniunzip() {
    echo unzipping omni.ja
    fn=$(unzip -l pm/omni.ja 2>/dev/null)
    fn=${fn% files}
    fn=${fn##* }
    [ "$progress" = cat ] || sfn="-s $fn"
    unzip -o pm/omni.ja -d pm/ 2>/dev/null | $progress $sfn >/dev/null
    rm -f pm/omni.ja
    rm -rf pm/hyphenation
}
libcopy() {
    echo -n copy libs
    mkdir libs
    lib=""
    deplibs=$(ldd $ramdir/pm/*.so|grep '=>'|grep -v "not found"|cut -d" " -f3 \
	    |grep -v ^/mnt |sort -u)
    du=$(du -Lch $deplibs|tail -n1|expand)
    echo " (${du%% *})"
    fn=$(echo "$deplibs"|wc -l)
    [ ! "$progress" = cat ] && sfn="-s $fn"
    $rsync $deplibs libs/ 2>/dev/null | $progress $sfn > /dev/null
}

gstreamcopy() {
    for gstreamdir in $gstreamdirs; do
	[ -f "$gstreamdir/libgstcoreelements.so" ] && break
    done
    [ ! -d "$gstreamdir" ] && error "gstreamer not found in dirs: $gstreamdirs"
    echo -n copy gstreamer libs from $gstreamdir
    du=$(du -sh "$gstreamdir"|expand)
    echo " (${du%% *})"
    fn=$(find "$gstreamdir" | wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync "$gstreamdir"/ gstreamer/ 2>/dev/null | $progress $sfn > /dev/null
    echo -n resolving gstreamer dependencies...
    deplibs=$(LD_LIBRARY_PATH=$ldlibpath:$LD_LIBRARY_PATH \
	ldd gstreamer/*.so|grep '=>'|grep -v -e $ramdir -e "not found" \
	|cut -d" " -f3|sort -u)
    du=$(du -Lch $deplibs|tail -n1|expand)
    echo "copy (${du%% *})"
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
#    profile=$(ls -1 "$defprof"/|grep -m1 default$)
#    [ -z "$profile" ] && error "User profile not found at "$defprof"" \
#	|| profdir="$defprof"/$profile
    echo "Copy profile from $profdir"
    fn=$(find "$profdir" ! -name lock | wc -l)
    [ "$progress" = cat ] || sfn="-s $((fn-1))"
    $rsync --safe-links --delete --exclude thirdparties --exclude webappsstore.sqlite \
	--exclude cache --exclude lock "$profdir"/ profile | $progress $sfn >/dev/null
}
extunzip(){
    for plugin in profile/extensions/*xpi; do
        [ -f "$plugin" ] || continue
	echo "Unzipping plugin: ${plugin##*/}"
        dirname=${plugin%.xpi}
        unzip "$plugin" -d "$dirname" >/dev/null && rm -f "$plugin"
    done
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
	--exclude lock \
	$ramdir/profile/ "$profdir"/ | xargs -I {} echo -n .
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
if [ -f "$tarfile" ] && [ $(stat -c "%Y" "$tarfile") -gt $(stat -c "%Y" "$profdir") ] \
&& [ ! "$1" = "f" ] ; then
    fn=$(stat -c %s "$tarfile")
    $progressb "$tarfile" -s $fn -c -N tar \
	| $lz4bin -d | $progressb -s $(cat "${tarfile}.size") -c -N unlz4 | tar xf - 2>/dev/null
fi
if [ ! "$(stat -c "%Y" $pmdir/palemoon-bin)" = "$(stat -c "%Y" pm/palemoon-bin)" ];then
    pmcopy
    [ -f pm/omni.ja ] && omniunzip
    [ "$symlinklibs" ] && symlinklibs
    [ "$libs" = true ] && libcopy
    [ "$gstinspect" ] && gstreamcopy
    profilecopy
fi
ldlibpath=$ramdir/libs
extunzip
[ "$sqlite" ] && sqlshrink

if [ -z "$XDG_CACHE_HOME" ]; then
    mkdir cache 2>/dev/null
    export XDG_CACHE_HOME=$ramdir/cache
fi

cd "$OLDPWD"
ramdu=$(du -sh $ramdir)
echo Using ${ramdu%%/*} as ramdisk "(generated in $(( $(date +%s) - $starttime )) seconds)"

echo Starting Pale Moon and syncing in every $syncinterval seconds
TMPDIR=/dev/shm/ TEMP=/dev/shm/ TMP=/dev/shm/ \
    LD_LIBRARY_PATH=$ldlibpath:$LD_LIBRARY_PATH \
    $ramdir/pm/palemoon --profile $ramdir/profile $1 &
pmpid=$!
#syncing profile in background
(while :;do
    sleep $syncinterval
    echo -n $(date "+%F %R") syncing profile
    pmsync
    echo done
done) &
jobs -l
#kill sleeploop and palemoon when pressing ctr-c
trap "kill -9 $!;killall palemoon" HUP INT TERM
#wait exits with signal 128 when palemoon get SIGSTOP, so ignore it
#until wait %1; do : ;done
while [ -d /proc/$pmpid ]; do wait %1;done
kill -9 $!

echo "Pale Moon has stopped."
#echo -n "Syncing and cleaning up"
#pmsync force
#echo done
if [ -n "$tarfile" ];then
    cd $ramdir
    fn=$(du -sb . | cut -f1 )
#    sfn="-s $fn -N tar"
    tar c . | $progressb -c -s $fn -N tar | $lz4bin | $progressb -c -s $fn -N tar.lz4 > "$tarfile"
    echo $fn > "${tarfile}.size"
    #|$progress $sfn >/dev/null
#    fn=$(du -sb .|cut -f1)
#    tar cf - . | pv -i 0.1 -w -s $fn | lz4 > "$tarfile"
    cd "$OLDPWD"
fi
fuser -km $ramdir/ >/dev/null 2>&1 && sleep 1
umount $ramdir
wait
echo finished
