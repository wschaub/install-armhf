#!/bin/bash
DEVICE=$1
LOOP=0
if [ -z $DEVICE ] || [ ! -b $DEVICE ]; then
    echo "$DEVICE is not a valid device! Exiting"
    exit 1
fi
if [[ $DEVICE =~ \/dev\/mmcblk* ]]; then
    echo "MMC card device, partitions named mmcblk*pN..."
    BOOTPART=${DEVICE}p1
    ROOTPART=${DEVICE}p2
elif [[ $DEVICE =~ \/dev\/sd* ]]; then
    echo "Generic SCSI block device, partitions named sd*N..."
    BOOTPART=${DEVICE}1
    ROOTPART=${DEVICE}2
elif [[ $DEVICE =~ \/dev\/loop* ]]; then
    BOOTPART=${DEVICE}p1
    ROOTPART=${DEVICE}p2
    FILE=$2
    if [ -f $FILE ]; then
        LOOP=1
        echo loop device detected
    else
        echo "you have to give an image file name when using a loop device"
        echo "you also want to be sure that you did not run losetup yourself"
        echo "we will do that for you"
        exit 1
    fi

else
    echo "unknown type of device!"
    exit 1
fi

#we diverge from install-armhf here and assume it is always
#an SD card we are writing to.
BOOTNAME=bootsd
ROOTNAME=rootsd

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
#make extra sure we bail out if anything goes wrong. 
set -e
if [ $LOOP -eq 1 ]; then
    echo "attaching $FILE to $DEVICE"
    losetup $DEVICE $FILE
fi
echo -n "creating MSDOS label on the device..."
parted $DEVICE --script -- mklabel msdos
echo "done"

echo -n "creating 128MB boot partition..."
parted $DEVICE --align optimal --script -- mkpart primary 1 128
parted $DEVICE --script -- set 1 boot on
echo "done"
partprobe $DEVICE
echo -n "creating root partition..."
parted $DEVICE --align optimal --script -- mkpart primary 128 -1
echo "done"
if [ $LOOP -eq 1 ]; then
    echo "detaching $FILE from $DEVICE"
    losetup -d $DEVICE
    sleep 3
    echo "attaching $FILE to $DEVICE"
    losetup $DEVICE $FILE
    sleep 5
fi

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
TARGETBOOT=$TARGETROOT/boot
mkdir $TARGETROOT/boot
mount $BOOTPART $TARGETBOOT
if [ -f root.tar.xz ]; then
    xzcat root.tar.xz | (cd $TARGETROOT; tar  --atime-preserve --numeric-owner -xvpf -)
else
    if [ -f root.tar ]; then
        cat root.tar | (cd $TARGETROOT; tar  --atime-preserve --numeric-owner -xvpf -)
    else
        echo "can't find an archive to extract!"
        exit 1
    fi
fi
#only bother to copy root.tar.xz if the headless installer
#is part of the image. This way we can reuse this script for
#installing other images as well.
if [ -d $TARGETROOT/home/oem ]; then
    cp root.tar.xz $TARGETROOT/home/oem/
fi
umount $TARGETBOOT
umount $TARGETROOT
if [ $LOOP -eq 1 ]; then
    echo "detaching $FILE from $DEVICE"
    losetup -d $DEVICE
fi
echo "All done, you are ready to put the SD card in your Efika and boot it."
