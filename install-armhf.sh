#!/bin/bash

# Change to suite, testing should work except from a few packages
SUITE=unstable

# Change this to your own mirror
MIRROR=http://ftp.XX.debian.org/debian

# Kernel version and revision of the kernel package that is in kernels/ dir.
KERNELVER=2.6.31.14.27-efikamx
KERNELREV=2012.02
KERNELDEB=linux-image-${KERNELVER}_${KERNELREV}_armhf.deb

# Change this to 'yes' if you want to also create an .img.xz file
GENIMAGE=no

if [ $# -lt 2 ]; then
    echo "Usage: installer-armhf.sh <ssd/mmc> <device> [-genimage]"
    exit 1
fi

if [ $1 != "mmc" ] && [ $1 != "ssd" ]; then
    echo "Usage: installer-armhf.sh <ssd/mmc> <device>"
    echo "You must select mmc/ssd type of booting (affects boot.scr and fstab). Exiting."
    exit 1
fi

if [ -z $2 ] || [ ! -b $2 ]; then
    echo "$2 is not a valid device! Exiting"
    exit 1
fi

DEVICE=$2
if [[ $2 =~ \/dev\/mmcblk* ]]; then
    echo "MMC card device, partitions named mmcblk*pN..."
    BOOTPART=${DEVICE}p1
    ROOTPART=${DEVICE}p2
elif [[ $2 =~ \/dev\/sd* ]]; then
    echo "Generic SCSI block device, partitions named sd*N..."
    BOOTPART=${DEVICE}1
    ROOTPART=${DEVICE}2
else
    echo "unknown type of device!"
    exit 1
fi

if [ $1 == "mmc" ]; then
     BOOTNAME=bootsd
     ROOTNAME=rootsd
elif [ $1 == "ssd" ]; then
     BOOTNAME=bootssd
     ROOTNAME=rootssd
fi

if [ $# == 3 ] && [ $3 == "-genimage" ]; then
    echo "Will generate compressed image from $2"
    GENIMAGE=yes
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
parted $2 --script -- mklabel msdos
echo "done"

echo -n "creating 128MB boot partition..."
parted $2 --align optimal --script -- mkpart primary 1 128
parted $2 --script -- set 1 boot on
echo "done"

echo -n "creating root partition..."
parted $2 --align optimal --script -- mkpart primary 128 -1
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
debootstrap --arch=armhf $SUITE $TARGETROOT $MIRROR
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
cp packages.extra $TARGETROOT/
mount -o bind /proc $TARGETROOT/proc
mount -o bind /dev $TARGETROOT/dev
mount -o bind /dev/pts $TARGETROOT/dev/pts
chroot $TARGETROOT dpkg-reconfigure locales
chroot $TARGETROOT aptitude -y install `cat packages.extra`
chroot $TARGETROOT apt-get clean
rm $TARGETROOT/packages.extra
rm $TARGETROOT/usr/sbin/policy-rc.d
echo "done installing"

echo -n "setting up ngetty..."
sed -r -e "s,^([2-6]*):23:,#\1:23:," $TARGETROOT/etc/inittab >$TARGETROOT/etc/inittab.copy
sed -r -e "s,1:2345:respawn:/sbin/getty 38400 tty1,1:2345:respawn:/sbin/ngetty tty1 tty2 tty3 tty4 tty5 tty6," $TARGETROOT/etc/inittab.copy >$TARGETROOT/etc/inittab
rm -f $TARGETROOT/etc/inittab.copy
rm -f $TARGETROOT/etc/rc*.d/S*ngetty
echo "done"

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
cp boot.script.$1 $TARGETROOT/boot/boot.script
chroot $TARGETROOT mkimage -A arm -O linux -T script -C none -a 0x0 -e 0x0 -n "EfikaMX Linux script" -d /boot/boot.script /boot/boot.scr
echo "done preparing uImage,uInitrd,boot.scr."

TARGETBOOT=`mktemp -d`
if [ -d $TARGETBOOT ]; then
    echo "mounting $BOOTPART to $TARGETBOOT..."
    mount $BOOTPART $TARGETBOOT
    echo "done"
fi

echo -n "copying uImage/uInitrd/boot.scr to $BOOTPART..."
cp $TARGETROOT/boot/uImage-$KERNELVER $TARGETBOOT/
(cd $TARGETBOOT && ln -s uImage-$KERNELVER uImage)
if [ -f $TARGETROOT/boot/uInitrd-$KERNELVER ]; then
    cp $TARGETROOT/boot/uInitrd-$KERNELVER $TARGETBOOT/
    (cd $TARGETBOOT && ln -s uInitrd-$KERNELVER uInitrd)
fi
cp $TARGETROOT/boot/boot.scr* $TARGETBOOT/
echo "done"

echo -n "setting up root password..."
echo "root:root" | chroot $TARGETROOT chpasswd
echo "done"

echo -n "setting up fstab..."
echo "LABEL=$ROOTNAME\t\t/\t\text4\t\tdefaults\t\t0\t0" >$TARGETROOT/etc/fstab
echo "proc\t\t/proc\t\tproc\t\tdefaults\t\t0\t0" >>$TARGETROOT/etc/fstab
echo "done"

echo -n "setting up hostname..."
echo "efikamx" >$TARGETROOT/etc/hostname
echo "done"

echo -n "copying wireless device firmware..."
cp firmware/rt*.bin $TARGETROOT/lib/firmware/
echo "done"

#image is done.
echo -n "unmounting filesystems..."
umount $TARGETROOT/proc
umount $TARGETROOT/dev/pts
umount $TARGETROOT/dev
umount $TARGETROOT
umount $TARGETBOOT
echo "done"

rm -rf $TARGETBOOT
rm -rf $TARGETROOT

if [ $GENIMAGE == "yes" ]; then
   echo "Compressing image into armhf-$SUITE.xz"
   dd if=$2 bs=32768 |pv | xz -0 - >armhf-$SUITE.xz
fi
