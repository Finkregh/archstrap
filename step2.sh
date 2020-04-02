#!/usr/bin/env bash

ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc --utc

#Set Hostname
read -p "Please enter the hostname: " hostn
echo "${hostn}" >/etc/hostname
echo "127.0.0.1	   ${hostn}.local   ${hostn}" >>/etc/hosts

echo LANG=en_US.UTF-8 >>/etc/locale.conf
echo LC_ALL= >>/etc/locale.conf

echo "de_DE.UTF-8 UTF-8" >/etc/locale.gen
echo "de_DE ISO-8859-1" >>/etc/locale.gen
echo "de_DE@euro ISO-8859-15" >>/etc/locale.gen
echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
echo "en_US ISO-8859-1" >>/etc/locale.gen

locale-gen

echo KEYMAP=de-latin1 >>/etc/vconsole.conf
echo FONT=lat9w-16 >>/etc/vconsole.conf
echo FONT_MAP=8859-1_to_uni >>/etc/vconsole.conf

sed -i '/MODULES=()/c\MODULES=(ext4)' /etc/mkinitcpio.conf
sed -i '/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/c\HOOKS=(base udev autodetect modconf block keyboard keymap encrypt lvm2 filesystems resume fsck shutdown)' /etc/mkinitcpio.conf

mkinitcpio -p linux
bootctl --path=/boot install

echo "Please set root password"
passwd

echo default arch >/boot/loader/loader.conf
echo timeout 5 >>/boot/loader/loader.conf

UUID=$(blkid | grep vda2 | awk -F "\"" '{ print $2 }')
##cryptsetup
echo "title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options cryptdevice=UUID=$UUID:vg0 root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap rw intel_pstate=no_hwp" >>/boot/loader/entries/arch.conf

systemctl enable dhcpcd.service

exit
