#!/usr/bin/env bash

# this will be replaced from bootstrap.sh
declare -rx DEST_DISK_NAME="__DEST_DISK_NAME_"

echo "[INFO] set clock to UTC"
timedatectl set-local-rtc 0
timedatectl set-ntp true
hwclock --systohc --utc

#Set Hostname
read -p "Please enter the _HOSTNAME: " _HOSTNAME
echo "${_HOSTNAME}" >/etc/_HOSTNAME
echo "
127.0.0.1	localhost
::1		localhost
127.0.1.1	${_HOSTNAME}.localdomain	${_HOSTNAME}" >>/etc/hosts

echo "LANG=en_US.UTF-8
LC_ALL=" >/etc/locale.conf

echo "en_US.UTF-8 UTF-8
en_US ISO-8859-1
de_DE.UTF-8 UTF-8
de_DE ISO-8859-1" >/etc/locale.gen

locale-gen

echo KEYMAP=de-latin1 >>/etc/vconsole.conf
echo FONT=lat9w-16 >>/etc/vconsole.conf
echo FONT_MAP=8859-1_to_uni >>/etc/vconsole.conf

echo "[INFO] generating mkinitcpio"
sed -i '/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/c\HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)' /etc/mkinitcpio.conf
mkinitcpio -P

echo "[INFO] installing bootloader"
mkdir -p /boot/loader
mkdir -p /boot/loader/entries
bootctl --path=/boot install

echo "default  arch.conf
timeout  4
console-mode max
editor   no" >/boot/loader/loader.conf
echo "title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /amd-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=$(blkid -s UUID -o value /dev/${DEST_DISK_NAME}2)=cryptoroot rd.luks.options=discard  root=UUID=$(blkid -s UUID -o value /dev/mapper/cryptoroot) rootflags=subvol=@ rw
" >/boot/loader/entries/arch.conf

systemctl enable dhcpcd.service

echo "Please set root password"
passwd

exit
