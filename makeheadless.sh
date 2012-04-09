#!/bin/sh
TARGETROOT=/mnt
DEV=$1
mount $DEV $TARGETROOT
cp oem.tgz $TARGETROOT
chroot $TARGETROOT tar xzvf oem.tgz
chroot $TARGETROOT useradd -u 700 oem
chroot $TARGETROOT chown -R oem:oem /home/oem
chroot $TARGETROOT cp /home/oem/sudoers-nopass /etc/sudoers
chroot $TARGETROOT cp /home/oem/S99oemrc /etc/init.d/oemrc
chroot $TARGETROOT insserv /etc/init.d/oemrc
echo "oem:oem" | chroot $TARGETROOT chpasswd
root $TARGETROOT adduser oem sudo
umount $TARGETROOT
