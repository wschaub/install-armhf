#!/bin/bash
#Load in defaults
. ./defaults
#exit if we are not root or any of the commands we depend on can not 
#be found in our path.
depends() {
    if [ $EUID -ne 0 ]; then
        echo "This script must be run as root"
        exit 1
    fi
    for i in mkfs.ext2 mkfs.ext4 parted pv debootstrap
    do
        which $i >/dev/null
        if [ $? -ne 0 ]; then
            echo "I can't find $i please install it and try again"
            exit 1
        fi
    done
}

usage(){
cat <<EOF
Usage: $0 [ -a armel|armhf ] [ -q ] [ -d distribution ] [ -t type ] ssd|mmc device [--genimage]

Options:
-a select the arch to use (armel or armhf) default is armhf

-d select the debian distribution (testing, wheezy, unstable etc) default is unstable

-t select the install type (desktop or minimal) 
you can define your own set of packages by creating a file named packages.yourtypenamehere

-q  Do not prompt to configure packages

--genimage Generate an image file after setting up the media.

--tasksel Run tasksel after installing the image.

Non option arguments:
The last two arguments are the media type (ssd or mmc) and the device to install to.
EOF
exit 1
}

if [ $# -lt 2 ]; then
	usage
fi
optspec=":qd:t:a:m:-:"
while getopts "$optspec" optchar; do
   case "${optchar}" in
   -)
   	case "${OPTARG}" in
	genimage)
	     GENIMAGE=yes;
	     ;;
        tasksel)
	     TASKSEL=yes
	     ;;
        *) usage;;
        esac;;
   d)
      SUITE=$OPTARG;
      ;;
   t)
      TYPE=$OPTARG;
      ;;
   a)
      ARCH=$OPTARG;
      ;;
   m)
      MIRROR=$OPTARG;
      ;;
   q)
      INTERACTIVE=no;
      export DEBIAN_FRONTEND=noninteractive;
      ;;
   *) usage;;
esac
done
#handle non option arguments and do sanity checks
MEDIA=${!OPTIND}
OPTIND=$(( $OPTIND + 1))
DEVICE=${!OPTIND}
if [ $MEDIA != "mmc" ] && [ $MEDIA != "ssd" ]; then
	echo "Media type must be either ssd or mmc type $0 -h for more information"
	exit 1
fi
#check if we are root and have the right utilities in our path.
depends
#These have to be here to support armel and armhf kernel images
#ARCH only gets reset from defaults after getopts processing. 
KERNELDEB=linux-image-${KERNELVER}_${KERNELREV}_$ARCH.deb
PREPKERNELDEB=prep-kernel_2.0.0-20110719_$ARCH.deb

#Speical case for minimal install type.
if [ $TYPE = "minimal" ]
then
	DBSOPTS="--variant=minbase"
	APTITUDE="apt-get -y install"
fi

if [ -z $DEVICE ] || [ ! -b $DEVICE ]; then
    echo "$DEVICE is not a valid device! Exiting"
    exit 1
fi

if [ ! -f packages.$TYPE ]; then
	echo "Install type $TYPE is not defined please create a packages.$TYPE file for it"
	exit 1
fi
echo INTERACTIVE=$INTERACTIVE
echo MIRROR=$MIRROR
echo ARCH=$ARCH
echo SUITE=$SUITE
echo GENIMAGE=$GENIMAGE
echo TYPE=$TYPE
echo MEDIA=$MEDIA
echo DEVICE=$DEVICE

if [[ $DEVICE =~ \/dev\/mmcblk* ]]; then
    echo "MMC card device, partitions named mmcblk*pN..."
    BOOTPART=${DEVICE}p1
    ROOTPART=${DEVICE}p2
elif [[ $DEVICE =~ \/dev\/sd* ]]; then
    echo "Generic SCSI block device, partitions named sd*N..."
    BOOTPART=${DEVICE}1
    ROOTPART=${DEVICE}2
else
    echo "unknown type of device!"
    exit 1
fi

if [ $MEDIA == "mmc" ]; then
     BOOTNAME=bootsd
     ROOTNAME=rootsd
elif [ $MEDIA == "ssd" ]; then
     BOOTNAME=bootssd
     ROOTNAME=rootssd
fi


echo "Will create partitions $BOOTNAME, $ROOTNAME on $BOOTPART, $ROOTPART, resp."

echo -n "checking if $BOOTPART is already mounted..."
MOUNTED=`grep -c $BOOTPART /proc/mounts`
MOUNTPOINT=`grep $BOOTPART /proc/mounts | awk '{print $2}'`
if [ $MOUNTED -eq "1" ]; then
    echo -n "yes, in $MOUNTPOINT, unmounting..."
    umount $MOUNTPOINT
    echo "unmounted"
else
    echo "no"
fi

echo -n "checking if $ROOTPART is already mounted..."
MOUNTED=`grep -c $ROOTPART /proc/mounts`
MOUNTPOINT=`grep $ROOTPART /proc/mounts | awk '{print $2}'`
if [ $MOUNTED -eq "1" ]; then
    echo -n "yes, in $MOUNTPOINT, unmounting..."
    umount $MOUNTPOINT
    echo "unmounted"
else
    echo "no"
fi

read -p "This will erase EVERYTHING in the device, Are you sure? Type 'yes' to continue: " WILL_FORMAT
if [ $WILL_FORMAT != "yes" ]; then
    echo "No, exiting..."
    exit 1
fi 

echo -n "creating MSDOS label on the device..."
parted $DEVICE --script -- mklabel msdos
echo "done"

echo -n "creating 128MB boot partition..."
parted $DEVICE --align optimal --script -- mkpart primary 1 128
parted $DEVICE --script -- set 1 boot on
echo "done"

echo -n "creating root partition..."
parted $DEVICE --align optimal --script -- mkpart primary 128 -1
echo "done"

echo -n "preparing boot partition in $BOOTPART..."
mkfs.ext2 -L $BOOTNAME -q $BOOTPART
echo "done"

echo -n "preparing root partition in $ROOTPART..."
mkfs.ext4 -L $ROOTNAME -q $ROOTPART
echo "done"

echo -n "creating temporary dir..."
TARGETROOT=`mktemp -d`
echo "done"

if [ -d $TARGETROOT ]; then
    echo "mounting $ROOTPART to $TARGETROOT..."
    mount $ROOTPART $TARGETROOT
    echo "done"
fi

echo "running debootstrap:"
debootstrap $DBSOPTS --arch=$ARCH $SUITE $TARGETROOT $MIRROR
if [ $? != 0 ]; then
    echo "error on debootstrap, exiting!"
    exit 1
fi
echo "done debootstrapping."

echo "disable starting up services in the chroot..."
echo -e "#!/bin/sh\nexit 101" > $TARGETROOT/usr/sbin/policy-rc.d
chmod +x $TARGETROOT/usr/sbin/policy-rc.d
echo "done"

echo "installing extra packages:"
cp packages.$TYPE $TARGETROOT/packages.extra
if [ "$TASKSEL" = "yes" ]; then
    echo tasksel >>$TARGETROOT/packages.extra
fi
mount -o bind /proc $TARGETROOT/proc
mount -o bind /dev $TARGETROOT/dev
mount -o bind /dev/pts $TARGETROOT/dev/pts
#temporarily disable debconf prompts so we don't prompt to configure things
#twice.
export DEBIAN_FRONTEND=noninteractive
chroot $TARGETROOT $APTITUDE `cat $TARGETROOT/packages.extra`
if [ "$INTERACTIVE" = "yes" ]; then
    chroot $TARGETROOT $APTITUDE locales console-setup tzdata user-setup
    unset DEBIAN_FRONTEND
    chroot $TARGETROOT dpkg-reconfigure locales
    chroot $TARGETROOT dpkg-reconfigure console-setup
    chroot $TARGETROOT dpkg-reconfigure tzdata
    chroot $TARGETROOT user-setup
fi
if [ "$TASKSEL" = "yes" ]; then
    chroot $TARGETROOT tasksel --new-install
fi
chroot $TARGETROOT apt-get clean
rm $TARGETROOT/packages.extra
rm $TARGETROOT/usr/sbin/policy-rc.d
echo "done installing"

#only set up ngetty if it exists in our packages file
grep ngetty packages.$TYPE >/dev/null
if [ $? -eq 0 ]; then
	echo -n "setting up ngetty..."
	sed -r -e "s,^([2-6]*):23:,#\1:23:," $TARGETROOT/etc/inittab >$TARGETROOT/etc/inittab.copy
	sed -r -e "s,1:2345:respawn:/sbin/getty 38400 tty1,1:2345:respawn:/sbin/ngetty tty1 tty2 tty3 tty4 tty5 tty6," $TARGETROOT/etc/inittab.copy >$TARGETROOT/etc/inittab
	rm -f $TARGETROOT/etc/inittab.copy
	rm -f $TARGETROOT/etc/rc*.d/S*ngetty
	echo "done"
fi

echo -n "setting up serial on mxc..."
sed -e "s,#T0:23:respawn:/sbin/getty -L ttyS0 9600 vt100,T0:23:respawn:/sbin/getty -L ttymxc0 115200 vt100," $TARGETROOT/etc/inittab >$TARGETROOT/etc/inittab.copy
mv $TARGETROOT/etc/inittab.copy $TARGETROOT/etc/inittab
echo "done"

echo -n "setting up udev to work with Genesi's kernels..."
sed -r -e "s/2.6.3\[0-1\]/2.6.30/g" $TARGETROOT/etc/init.d/udev >$TARGETROOT/etc/init.d/udev.copy
mv $TARGETROOT/etc/init.d/udev.copy $TARGETROOT/etc/init.d/udev
chmod +x $TARGETROOT/etc/init.d/udev
echo "done"

echo -n "setting up ramzswap..."
sed -e "s/^exit/modprobe ramzswap disksize_kb=262088\nmkswap -f \/dev\/ramzswap0\nswapon -p 0 \/dev\/ramzswap0\nexit/" $TARGETROOT/etc/rc.local >$TARGETROOT/etc/rc.local.copy
mv $TARGETROOT/etc/rc.local.copy $TARGETROOT/etc/rc.local
chmod +x $TARGETROOT/etc/rc.local
echo "done"

echo "setting up /etc/modules"
echo gpu >>$TARGETROOT/etc/modules
echo snd-soc-imx-3stack-sgtl5000 >>$TARGETROOT/etc/modules

TARGETBOOT=$TARGETROOT/boot
if [ -d $TARGETBOOT ]; then
    echo "mounting $BOOTPART to $TARGETBOOT..."
    mount $BOOTPART $TARGETBOOT
    echo "done"
fi

echo "installing kernel:"
cp kernels/$KERNELDEB $TARGETROOT/
chroot $TARGETROOT dpkg -i $KERNELDEB
rm $TARGETROOT/$KERNELDEB
echo "done installing kernel"

echo "preparing uImage:"
# uImage
chroot $TARGETROOT mkimage -A arm -O linux -T kernel -C none -a 0x90008000 -e 0x90008000 -n "EfikaMX Linux kernel" -d /boot/vmlinuz-$KERNELVER /boot/uImage-$KERNELVER
# uInitrd
echo "preparing uInitrd:"
if [ -f $TARGETROOT/boot/initrd.img-$KERNELVER ]; then
    chroot $TARGETROOT mkimage -A arm -O linux -T ramdisk -C none -a 0x0 -e 0x0 -n "EfikaMX Linux ramdisk" -d /boot/initrd.img-$KERNELVER /boot/uInitrd-$KERNELVER
fi
# boot.scr
echo "preparing boot.scr:"
cp boot.script.$MEDIA $TARGETROOT/boot/boot.script
chroot $TARGETROOT mkimage -A arm -O linux -T script -C none -a 0x0 -e 0x0 -n "EfikaMX Linux script" -d /boot/boot.script /boot/boot.scr
echo "done preparing uImage,uInitrd,boot.scr."

echo -n "copying uImage/uInitrd/boot.scr to $BOOTPART..."
cp $TARGETROOT/boot/uImage-$KERNELVER $TARGETBOOT/
(cd $TARGETBOOT && ln -s uImage-$KERNELVER uImage)
if [ -f $TARGETROOT/boot/uInitrd-$KERNELVER ]; then
    cp $TARGETROOT/boot/uInitrd-$KERNELVER $TARGETBOOT/
    (cd $TARGETBOOT && ln -s uInitrd-$KERNELVER uInitrd)
fi
cp $TARGETROOT/boot/boot.scr* $TARGETBOOT/
echo "done"

echo "Installing prep-kernel"
cp kernels/$PREPKERNELDEB $TARGETROOT
chroot $TARGETROOT dpkg -i $PREPKERNELDEB
rm $TARGETROOT/$PREPKERNELDEB

#we already run user-setup in interactive mode, fallback to this if we aren't
#interactive.
if [ "$INTERACTIVE" = "no" ]; then
echo -n "setting up root password..."
echo "root:root" | chroot $TARGETROOT chpasswd
echo "done"
fi

echo -n "setting up fstab..."
echo -e "LABEL=$ROOTNAME\t\t/\t\text4\t\tdefaults\t\t0\t0" >$TARGETROOT/etc/fstab
echo -e "LABEL=$BOOTNAME\t\t/boot\t\tauto\t\tdefaults\t\t0\t0" >>$TARGETROOT/etc/fstab
echo -e "proc\t\t/proc\t\tproc\t\tdefaults\t\t0\t0" >>$TARGETROOT/etc/fstab
echo "done"

echo -n "setting up hostname..."
echo "efikamx" >$TARGETROOT/etc/hostname
echo "done"

echo -n "copying wireless device firmware..."
cp firmware/rt*.bin $TARGETROOT/lib/firmware/
echo "done"

#image is done.
echo -n "unmounting filesystems..."
umount $TARGETBOOT
umount $TARGETROOT/proc
umount $TARGETROOT/dev/pts
umount $TARGETROOT/dev
umount $TARGETROOT
echo "done"

rm -rf $TARGETROOT

if [ $GENIMAGE == "yes" ]; then
   echo "Making image $ARCH-$SUITE.img"
   dd if=$DEVICE bs=32768 |pv >$ARCH-$SUITE.img
fi
