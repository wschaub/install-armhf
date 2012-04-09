#!/bin/sh
TARGETROOT=/mnt
DEV=$1
set -e
mount $DEV $TARGETROOT
tar cvf $TARGETROOT/oem.tar home
chroot $TARGETROOT tar xvf oem.tar
chroot $TARGETROOT useradd -u 700 oem
chroot $TARGETROOT chown -R oem:oem /home/oem
chroot $TARGETROOT cp /home/oem/sudoers-nopass /etc/sudoers
chroot $TARGETROOT cp /home/oem/S99oemrc /etc/init.d/oemrc
chroot $TARGETROOT insserv /etc/init.d/oemrc
echo "oem:oem" | chroot $TARGETROOT chpasswd
root $TARGETROOT adduser oem sudo
umount $TARGETROOT
